use std::collections::HashMap;
use std::net::SocketAddr;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{ConnectInfo, State};
use axum::response::Response;
use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tokio::time::{self, Duration};
use tracing::{info, warn};

use crate::AppState;
use crate::auth::challenge::{
    AUTH_TIMEOUT_MS, HELLO_TIMEOUT_MS, challenge_line, gen_nonce, parse_hello, verify_auth,
};
use crate::lan::lan_candidate_urls;
use crate::protocol::outer::{OuterEnvelope, parse_line};
use crate::rooms::{RoomMeta, RoomMetaPatch};

/// Hard ceiling on a single inbound WS message (text or binary). The outer
/// envelope path already caps `ct` at ~4 MiB (`parse_line`), but control
/// frames — notably `pi_envelope`, which embeds a full broker envelope —
/// historically bypassed that check and only the tungstenite default
/// (~64 MiB) applied. 5 MiB covers a max-size `ct` + wrapper with margin
/// (security fix 2026-08).
pub const MAX_WS_MESSAGE_BYTES: usize = 5 * 1024 * 1024;

/// Plan/137 — minimum spacing between `route_error` NACKs for the same
/// `(dest peer, room)` on one connection. Mirrors the control-reply dedup
/// TTL pattern: churn-y drops (an app mid-reconnect) collapse to one NACK
/// per window, while a genuinely dead destination still surfaces promptly.
const ROUTE_ERROR_TTL: Duration = Duration::from_secs(5);

/// Axum route handler: validates the WebSocket upgrade and hands the upgraded
/// socket to `handle_peer`, which owns the connection for its lifetime.
pub async fn ws_handler(
    ws: WebSocketUpgrade,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    State(state): State<AppState>,
) -> Response {
    ws.max_message_size(MAX_WS_MESSAGE_BYTES)
        .max_frame_size(MAX_WS_MESSAGE_BYTES)
        .on_upgrade(move |socket| handle_peer(socket, addr, state))
}

/// Owns one peer's WebSocket connection: hello/challenge/auth → register →
/// routing loop (forwarding outer envelopes + handling presence/rooms control
/// frames + sending keepalive pings) → unregister on disconnect.
async fn handle_peer(socket: WebSocket, peer_addr: SocketAddr, state: AppState) {
    let peer_addr = peer_addr.to_string();
    let (mut sink, mut stream) = socket.split();

    // ── 1. Wait for hello (with timeout) ──────────────────────────────────
    let hello_result =
        tokio::time::timeout(Duration::from_millis(HELLO_TIMEOUT_MS), stream.next()).await;

    let hello_text = match hello_result {
        Ok(Some(Ok(Message::Text(t)))) => t,
        _ => {
            warn!(addr = %peer_addr, "no hello received, closing");
            return;
        }
    };

    let vk = match parse_hello(&hello_text) {
        Ok(vk) => vk,
        Err(e) => {
            warn!(addr = %peer_addr, err = %e, "bad hello, closing");
            return;
        }
    };

    // ── 2. Send challenge ─────────────────────────────────────────────────
    // Plan 115 — advertise the relay's local RFC1918 IPv4 candidates so the
    // phone can dial LAN first at home (bypassing Tailscale). Collected
    // fresh per connection (DHCP may have changed the address since boot);
    // failures yield an empty list, which `challenge_line` omits entirely
    // (backwards compatible).
    let (nonce, nonce_b64) = gen_nonce();
    let lan = lan_candidate_urls(state.port);
    if sink
        .send(Message::Text(challenge_line(&nonce_b64, &lan)))
        .await
        .is_err()
    {
        return;
    }

    // ── 3. Receive and verify auth ────────────────────────────────────────
    let auth_result =
        tokio::time::timeout(Duration::from_millis(AUTH_TIMEOUT_MS), stream.next()).await;
    // Same timeout as hello — a socket that never completes the handshake is
    // a liveness leak; close it instead of awaiting the auth frame forever
    // (security fix 2026-08).
    let auth_text = match auth_result {
        Ok(Some(Ok(Message::Text(t)))) => t,
        _ => {
            warn!(addr = %peer_addr, "no auth received, closing");
            return;
        }
    };

    if let Err(e) = verify_auth(&nonce, &vk, &auth_text) {
        warn!(addr = %peer_addr, err = %e, "auth failed, closing");
        let _ = sink.send(Message::Close(None)).await;
        return;
    }

    let peer_id = B64.encode(vk.to_bytes());
    let peer_short = peer_id[peer_id.len().saturating_sub(8)..].to_string();

    // Extract room_id and room_meta from hello (auth handled separately above).
    let room_meta = {
        let hello: serde_json::Value =
            serde_json::from_str(&hello_text).unwrap_or(serde_json::Value::Null);
        let room_id = hello
            .get("room_id")
            .and_then(|v| v.as_str())
            .unwrap_or("main")
            .to_string();
        let room_meta_val = hello.get("room_meta");
        let name = room_meta_val
            .and_then(|m| m.get("name"))
            .and_then(|v| v.as_str())
            .map(String::from);
        let cwd = room_meta_val
            .and_then(|m| m.get("cwd"))
            .and_then(|v| v.as_str())
            .map(String::from);
        let model = room_meta_val
            .and_then(|m| m.get("model"))
            .and_then(|v| v.as_str())
            .map(String::from);
        let thinking = room_meta_val
            .and_then(|m| m.get("thinking"))
            .and_then(|v| v.as_str())
            .map(String::from);
        let working = room_meta_val
            .and_then(|m| m.get("working"))
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        // Plan/134 — blocking-prompt flag (same default-false semantics as
        // `working`).
        let waiting_for_input = room_meta_val
            .and_then(|m| m.get("waiting_for_input"))
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        // Plan/107b — opaque git snapshot (the relay forwards it verbatim;
        // the app parses the shape).
        let git = room_meta_val.and_then(|m| m.get("git")).cloned();
        // Opaque context-usage blob (the relay forwards it verbatim).
        let context_usage = room_meta_val.and_then(|m| m.get("context_usage")).cloned();
        let started_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        RoomMeta {
            room_id,
            name,
            cwd,
            model,
            thinking,
            working,
            waiting_for_input,
            git,
            context_usage,
            started_at,
        }
    };
    let room_id = room_meta.room_id.clone();

    info!(peer = %peer_short, room = %room_id, addr = %peer_addr, "authenticated");

    let registry = state.registry.clone();
    let presence = state.presence.clone();
    let rooms = state.rooms.clone();
    let mesh = state.mesh.clone();
    let mesh_auth = state.mesh_auth.clone();
    let metrics = state.metrics.clone();

    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();
    let conn_id = registry.register(peer_id.clone(), room_meta, tx).await;

    // Per-conn dedup state for control-frame replies. Suppress identical
    // re-emits of `presence` (single cache slot — there's only one
    // subscription set per conn) and `rooms` (one slot per target peer).
    let mut last_presence_resp: Option<String> = None;
    let mut last_presence_sent_at: Option<std::time::Instant> = None;
    // (last sent reply, sent-at) per target peer — see the TTL note at the
    // rooms_check handler; same firehose-vs-poll contract as presence.
    let mut last_rooms_resp: HashMap<String, (String, std::time::Instant)> = HashMap::new();
    // Plan/137 — route_error NACK rate-limit: last send per (dest peer, room).
    // Without it, pi→app broadcast churn while an app reconnects would spam
    // the pi with NACKs for every dropped frame (the historical "~94% of the
    // log" churn). One per window per destination keeps the signal ("that
    // room is gone right now") without the noise.
    let mut last_route_error_sent_at: HashMap<(String, String), Instant> = HashMap::new();

    // ── Authorization helper (security fix 2026-08) ─────────────────────────
    // Presence/rooms queries about OTHER peers are metadata disclosure: they
    // leak online/offline times, cwd, model and git state to any authenticated
    // relay client, paired or not. Gate them behind the same mesh-membership
    // check `pi_envelope` forwarding uses: the sender must share an Owner blob
    // with the target. A peer may always query itself.
    let authorize_targets = |targets: Vec<String>| {
        let sender = peer_id.clone();
        let mesh_auth = mesh_auth.clone();
        let mesh = mesh.clone();
        async move {
            let mut allowed = Vec::with_capacity(targets.len());
            for target in targets {
                if target == sender
                    || mesh_auth
                        .is_authorized(&sender, &target, mesh.clone())
                        .await
                {
                    allowed.push(target);
                }
            }
            allowed
        }
    };

    // ── 4. Routing loop ───────────────────────────────────────────────────
    // Send a WS Ping at the configured interval (default 60 s — plan 125, was
    // 25 s) so NAT/LB idle timers don't close the connection. 60 s beats every
    // common NAT idle timeout with margin and halves inbound radio wakeups for
    // mobile clients. Configurable via REMOTEPI_HEARTBEAT_SECS (min 30).
    // First tick fires after the interval (not immediately).
    let heartbeat_interval = state.heartbeat_interval;
    let mut heartbeat = time::interval_at(
        time::Instant::now() + heartbeat_interval,
        heartbeat_interval,
    );

    'routing: loop {
        tokio::select! {
            item = stream.next() => {
                match item {
                    None | Some(Err(_)) => break,
                    Some(Ok(msg)) => {
                        let text = match msg {
                            Message::Text(t) => t,
                            Message::Close(_) => break,
                            // Pong frames are keepalive responses; Ping frames are
                            // answered automatically by axum's WS. Drop both.
                            Message::Ping(_) | Message::Pong(_) => continue,
                            Message::Binary(_) => continue, // ignore binary
                        };

                        // Parse as JSON to check for relay control frames.
                        let frame: serde_json::Value = match serde_json::from_str(&text) {
                            Ok(v) => v,
                            Err(e) => {
                                warn!(peer = %peer_short, err = %e, "invalid json, dropping");
                                continue;
                            }
                        };

                        // Frames with a top-level "type" are handled by the relay itself.
                        if let Some(t) = frame.get("type").and_then(|v| v.as_str()) {
                            let peers: Vec<String> = frame
                                .get("peers")
                                .and_then(|v| v.as_array())
                                .map(|arr| {
                                    arr.iter()
                                        .filter_map(|v| v.as_str().map(String::from))
                                        .collect()
                                })
                                .unwrap_or_default();

                            match t {
                                // ── presence control frames (plano 12) ──
                                "subscribe_presence" => {
                                    let peers = authorize_targets(peers).await;
                                    presence.subscribe(peer_id.clone(), peers.clone()).await;
                                    // Backfill: push peer_online for any already-online
                                    // peers in the list, so subscribers don't have to
                                    // call presence_check to discover current state.
                                    registry.backfill_presence(&peer_id, &peers);
                                }
                                "unsubscribe_presence" => {
                                    presence.unsubscribe(&peer_id, peers).await;
                                }
                                "presence_check" => {
                                    let peers = authorize_targets(peers).await;
                                    let states = presence
                                        .snapshot(&peers, |p| registry.is_online(p))
                                        .await;
                                    let resp = serde_json::json!({
                                        "type": "presence",
                                        "states": states,
                                    })
                                    .to_string();
                                    // Dedup with TTL (PR #48 review #1): identical
                                    // replies are suppressed only within
                                    // `control_reply_dedup_ttl` of the last SEND.
                                    // Unbounded suppression starved the app's
                                    // 60 s self-heal poll — a purely-local
                                    // offline mark never changes relay state,
                                    // so the reply stayed identical forever
                                    // and the poll never got an answer.
                                    // Bursts (reconnect firehose) land well
                                    // inside the TTL and still collapse.
                                    let dedup_ttl = state.control_reply_dedup_ttl;
                                    let now = std::time::Instant::now();
                                    let presence_suppressed =
                                        last_presence_resp.as_deref() == Some(resp.as_str())
                                            && last_presence_sent_at
                                                .is_some_and(|t| now.duration_since(t) < dedup_ttl);
                                    if presence_suppressed {
                                        metrics.inc_presence_suppressed(1);
                                    } else {
                                        last_presence_resp = Some(resp.clone());
                                        last_presence_sent_at = Some(now);
                                        if sink.send(Message::Text(resp)).await.is_err() {
                                            break;
                                        }
                                        metrics.inc_presence_emitted(1);
                                    }
                                }

                                // ── rooms control frames (plano 17) ──
                                "subscribe_rooms" => {
                                    let peers = authorize_targets(peers).await;
                                    rooms.subscribe(peer_id.clone(), peers).await;
                                }
                                "unsubscribe_rooms" => {
                                    rooms.unsubscribe(&peer_id, peers).await;
                                }
                                "rooms_check" => {
                                    let peers = authorize_targets(peers).await;
                                    for target_peer in &peers {
                                        let active_rooms = registry.rooms_of(target_peer);
                                        let resp = serde_json::json!({
                                            "type": "rooms",
                                            "peer": target_peer,
                                            "rooms": active_rooms,
                                        })
                                        .to_string();
                                        // Dedup per (conn, target_peer) with
                                        // TTL: first reply always sent;
                                        // identical snapshots dropped only
                                        // within `control_reply_dedup_ttl` of
                                        // the last send (PR #48 review #1 —
                                        // unbounded suppression starved the
                                        // client's periodic self-heal poll;
                                        // see the presence_check arm above).
                                        let now = std::time::Instant::now();
                                        let rooms_suppressed = match
                                            last_rooms_resp.get(target_peer)
                                        {
                                            Some((prev, sent_at)) => {
                                                *prev == resp
                                                    && now.duration_since(*sent_at)
                                                        < state.control_reply_dedup_ttl
                                            }
                                            None => false,
                                        };
                                        if rooms_suppressed {
                                            metrics.inc_rooms_suppressed(1);
                                            continue;
                                        }
                                        last_rooms_resp.insert(
                                            target_peer.clone(),
                                            (resp.clone(), now),
                                        );
                                        if sink.send(Message::Text(resp)).await.is_err() {
                                            break 'routing;
                                        }
                                        metrics.inc_rooms_emitted(1);
                                    }
                                }

                                // ── room meta update (plano 18 + 28 + 32 + 134) ──
                                // `meta.model`, `meta.thinking`,
                                // `meta.working` and
                                // `meta.waiting_for_input` are patched
                                // independently: a
                                // field absent from `meta` is *left alone* on
                                // the room (not cleared). For the nullable
                                // string fields, an explicit `null` clears
                                // them. The bool flags only
                                // ever toggle — a non-bool/absent value leaves
                                // them untouched. Mirrors the JSON Merge Patch
                                // shape clients already produce.
                                "room_meta_update" => {
                                    let target_room = frame
                                        .get("room_id")
                                        .and_then(|v| v.as_str())
                                        .unwrap_or(&room_id)
                                        .to_string();
                                    let meta_obj = frame
                                        .get("meta")
                                        .and_then(|v| v.as_object());
                                    let model_patch = meta_obj
                                        .and_then(|m| m.get("model"))
                                        .map(|v| v.as_str().map(String::from));
                                    // TEMP diagnostic (plan/109 per-message override) — confirm whether
                                    // model patches reach the relay. Remove once the fix is verified.
                                    if let Some(Some(m)) = &model_patch {
                                        info!(peer = %peer_short, room = %target_room, model = %m, "room_meta_update (model patch)");
                                    }
                                    let thinking_patch = meta_obj
                                        .and_then(|m| m.get("thinking"))
                                        .map(|v| v.as_str().map(String::from));
                                    let working_patch = meta_obj
                                        .and_then(|m| m.get("working"))
                                        .and_then(|v| v.as_bool());
                                    // Plan/134 — blocking-prompt flag, same
                                    // toggle-only semantics as `working`.
                                    let waiting_for_input_patch = meta_obj
                                        .and_then(|m| m.get("waiting_for_input"))
                                        .and_then(|v| v.as_bool());
                                    // Plan/107b — opaque git passthrough.
                                    let git_patch = meta_obj
                                        .and_then(|m| m.get("git"))
                                        .map(|v| Some(v.clone()));
                                    // Opaque context-usage passthrough.
                                    let context_usage_patch = meta_obj
                                        .and_then(|m| m.get("context_usage"))
                                        .map(|v| Some(v.clone()));
                                    // Plan/132 — run-completion marker: opaque,
                                    // broadcast-only passthrough (never stored on
                                    // RoomMeta — see `RoomMetaPatch::run_done`).
                                    let run_done_patch =
                                        meta_obj.and_then(|m| m.get("run_done")).cloned();
                                    let patch = RoomMetaPatch {
                                        model: model_patch,
                                        thinking: thinking_patch,
                                        working: working_patch,
                                        waiting_for_input: waiting_for_input_patch,
                                        git: git_patch,
                                        context_usage: context_usage_patch,
                                        run_done: run_done_patch,
                                    };
                                    if !registry
                                        .update_room_meta(&peer_id, &target_room, patch)
                                        .await
                                    {
                                        warn!(
                                            peer = %peer_short,
                                            room = %target_room,
                                            "room_meta_update for unknown (peer, room), dropping"
                                        );
                                    }
                                }

                                // ── Pi-to-Pi envelope forward (plano 25 W-A) ──
                                "pi_envelope" => {
                                    use crate::handlers::pi_forward::{
                                        PiForwardResult, handle_pi_envelope,
                                    };
                                    match handle_pi_envelope(
                                        &peer_id,
                                        &frame,
                                        &registry,
                                        mesh.clone(),
                                        mesh_auth.clone(),
                                    )
                                    .await
                                    {
                                        PiForwardResult::Forwarded => {}
                                        PiForwardResult::TransportError(err_msg) => {
                                            if sink.send(err_msg).await.is_err() {
                                                break;
                                            }
                                        }
                                    }
                                }

                                _ => {
                                    warn!(
                                        peer = %peer_short,
                                        frame_type = %t,
                                        "unknown control frame type, dropping"
                                    );
                                }
                            }
                            continue; // do not fall through to envelope path
                        }

                        // No "type" field → outer envelope (opaque routing).
                        match parse_line(&text) {
                            Err(e) => {
                                warn!(peer = %peer_short, err = %e, "invalid envelope, dropping");
                            }
                            Ok(env) => {
                                let ct_len = env.ct.len();
                                let dest_peer = env.peer;
                                let dest_room = env.room;
                                let dest_tail =
                                    dest_peer[dest_peer.len().saturating_sub(8)..].to_string();
                                // Rewrite: recipient sees sender's peer_id + sender's room_id.
                                // `sig`/`sig2` (inner sender signatures, security fix 2026-08)
                                // and `ts` (v2 freshness) are forwarded verbatim — the relay
                                // cannot forge them and must not strip them.
                                let rewritten = OuterEnvelope {
                                    peer: peer_id.clone(),
                                    room: room_id.clone(),
                                    ct: env.ct,
                                    sig: env.sig,
                                    sig2: env.sig2,
                                    ts: env.ts,
                                };
                                let fwd_line = serde_json::to_string(&rewritten)
                                    .expect("OuterEnvelope serialisation is infallible");
                                // Skip-sender: pass our own conn_id so multi-device
                                // Owners don't echo their own outbound messages.
                                if !registry.forward(
                                    &dest_peer,
                                    &dest_room,
                                    Message::Text(fwd_line),
                                    conn_id,
                                ) {
                                    // Was debug! ("normal during churn, ~94% of
                                    // the log"), but the relay's subscriber runs
                                    // at a fixed INFO level — RUST_LOG has no
                                    // effect — so routing failures were INVISIBLE
                                    // (Projects "Device unreachable" diagnosis,
                                    // 2026-08-20). Dropped-frame visibility beats
                                    // log noise here; churn drops are still cheap
                                    // to filter downstream.
                                    info!(
                                        from = %peer_short,
                                        dest = %dest_tail,
                                        room = %dest_room,
                                        bytes = ct_len,
                                        "dest (peer, room) not found, dropping",
                                    );
                                    // Plan/137 — NACK the sender (rate-limited):
                                    // an app steering into a dead/phantom room
                                    // otherwise black-holes with an unbounded
                                    // "steering…" spinner. The frame is opaque
                                    // (encrypted ct), so the NACK identifies the
                                    // DESTINATION, not the message id — the app
                                    // correlates by (peer, room) recency.
                                    let key = (dest_peer.clone(), dest_room.clone());
                                    let now = Instant::now();
                                    let due = last_route_error_sent_at
                                        .get(&key)
                                        .is_none_or(|sent_at| {
                                            now.duration_since(*sent_at) >= ROUTE_ERROR_TTL
                                        });
                                    if due {
                                        last_route_error_sent_at.insert(key, now);
                                        let nack = serde_json::json!({
                                            "type": "route_error",
                                            "peer": dest_peer,
                                            "room": dest_room,
                                        });
                                        if let Ok(line) = serde_json::to_string(&nack)
                                            && sink.send(Message::Text(line)).await.is_err()
                                        {
                                            break 'routing;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            result = rx.recv() => {
                match result {
                    Some(msg) => {
                        if sink.send(msg).await.is_err() {
                            break;
                        }
                    }
                    None => break,
                }
            }
            _ = heartbeat.tick() => {
                if sink.send(Message::Ping(Vec::new())).await.is_err() {
                    break;
                }
            }
        }
    }

    registry.unregister(&peer_id, &room_id, conn_id).await;
    rooms.unsubscribe_all(&peer_id).await;
    info!(peer = %peer_short, room = %room_id, addr = %peer_addr, "disconnected");
}
