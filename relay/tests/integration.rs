mod common;
use common::{connect_and_auth, connect_and_auth_with_room, start_relay};

use ed25519_dalek::Signer;
use ed25519_dalek::SigningKey;
use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use tokio_tungstenite::tungstenite::Message;

fn random_key() -> SigningKey {
    SigningKey::generate(&mut rand::thread_rng())
}

/// Security fix 2026-08 — the outer envelope's optional `sig` (sender's
/// end-to-end Ed25519 signature over `ct`) must be forwarded VERBATIM. The
/// relay cannot forge it and must not strip it — recipients rely on it to
/// authenticate the sender independently of the relay.
#[tokio::test]
async fn envelope_sig_is_forwarded_verbatim() {
    let port = start_relay().await;
    let (mut ws_a, peer_a) = connect_and_auth(port).await;
    let (mut ws_b, peer_b) = connect_and_auth(port).await;

    // `sig` is any opaque-to-the-relay string here — we only assert
    // passthrough, not validity.
    let ct = "aGVsbG8=";
    let sig = "U0lHMDAwMDA=";
    ws_a.send(Message::text(
        json!({"peer": peer_b, "ct": ct, "sig": sig}).to_string(),
    ))
    .await
    .unwrap();

    let received = tokio::time::timeout(tokio::time::Duration::from_secs(1), ws_b.next())
        .await
        .expect("timed out waiting for forwarded message")
        .unwrap()
        .unwrap();
    let v: serde_json::Value = serde_json::from_str(received.to_text().unwrap()).unwrap();
    assert_eq!(v["peer"], peer_a);
    assert_eq!(v["ct"], ct);
    assert_eq!(v["sig"], sig, "sig must be forwarded verbatim");

    // ...and the legacy unsigned shape still round-trips without a `sig`
    // field (back-compat on the wire).
    ws_a.send(Message::text(
        json!({"peer": peer_b, "ct": ct}).to_string(),
    ))
    .await
    .unwrap();
    let received2 = tokio::time::timeout(tokio::time::Duration::from_secs(1), ws_b.next())
        .await
        .expect("timed out waiting for second forwarded message")
        .unwrap()
        .unwrap();
    let v2: serde_json::Value = serde_json::from_str(received2.to_text().unwrap()).unwrap();
    assert!(v2.get("sig").is_none(), "unsigned frames stay unsigned");
}

/// Security fix 2026-08 — a WS text frame larger than the message cap must
/// be rejected by the WS layer instead of parsed + forwarded (~64 MiB was
/// the previous implicit ceiling).
#[tokio::test]
async fn oversized_ws_message_is_rejected() {
    use relay::handlers::peer::MAX_WS_MESSAGE_BYTES;

    let port = start_relay().await;
    let url = format!("ws://127.0.0.1:{port}");
    let (mut ws, _) = tokio_tungstenite::connect_async(&url).await.unwrap();

    use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
    let sk = ed25519_dalek::SigningKey::generate(&mut rand::thread_rng());
    ws.send(Message::text(
        json!({"type": "hello", "pubkey": B64.encode(sk.verifying_key().to_bytes())})
            .to_string(),
    ))
    .await
    .unwrap();
    let challenge: serde_json::Value =
        serde_json::from_str(ws.next().await.unwrap().unwrap().to_text().unwrap()).unwrap();
    let nonce: [u8; 32] = B64
        .decode(challenge["nonce"].as_str().unwrap())
        .unwrap()
        .try_into()
        .unwrap();
    ws.send(Message::text(
        json!({"type": "auth", "sig": B64.encode(sk.sign(&nonce).to_bytes())}).to_string(),
    ))
    .await
    .unwrap();

    // A frame above the cap → tungstenite should error/close the stream.
    let oversized = format!("{{\"peer\":\"x\",\"ct\":\"{}\"}}", "A".repeat(MAX_WS_MESSAGE_BYTES));
    let send_result = ws.send(Message::text(oversized)).await;
    let closed = send_result.is_err()
        || tokio::time::timeout(tokio::time::Duration::from_millis(500), ws.next())
            .await
            .map(|next| matches!(next, None | Some(Err(_)) | Some(Ok(Message::Close(_)))))
            .unwrap_or(true);
    assert!(closed, "oversized frame must terminate the connection");
}

/// Peer A sends an OuterEnvelope addressed to peer B.
/// B receives a rewritten envelope where outer.peer = A (the sender),
/// not B (the original dest) — per protocol.md semantics.
#[tokio::test]
async fn two_peers_route_message() {
    let port = start_relay().await;
    let (mut ws_a, peer_a) = connect_and_auth(port).await;
    let (mut ws_b, peer_b) = connect_and_auth(port).await;

    let ct = "aGVsbG8="; // "hello" in base64, never decoded by relay
    // A sends: peer = dest (peer_b)
    ws_a.send(Message::text(json!({"peer": peer_b, "ct": ct}).to_string()))
        .await
        .unwrap();

    let received = tokio::time::timeout(tokio::time::Duration::from_secs(1), ws_b.next())
        .await
        .expect("timed out waiting for forwarded message")
        .unwrap()
        .unwrap();

    // B receives: peer = sender (peer_a), ct unchanged
    let received_json: serde_json::Value =
        serde_json::from_str(received.to_text().unwrap()).unwrap();
    assert_eq!(
        received_json["peer"], peer_a,
        "relay must rewrite peer to sender id"
    );
    assert_eq!(received_json["ct"], ct, "ct must be forwarded unchanged");
}

/// Plan/137 — sending to an unknown destination NACKs the sender with a
/// rate-limited `route_error` control frame (identifies the destination,
/// since the envelope body is opaque); duplicates within the TTL window are
/// suppressed. The connection stays alive.
#[tokio::test]
async fn dest_offline_nacks_with_route_error_then_rate_limits() {
    let port = start_relay().await;
    let (mut ws_a, _) = connect_and_auth(port).await;

    let dest = "bm9uZXhpc3RlbnRwZWVy";
    ws_a
        .send(Message::text(
            json!({"peer": dest, "room": "deadroom", "ct": "aGVsbG8="}).to_string(),
        ))
        .await
        .unwrap();

    let nack = tokio::time::timeout(tokio::time::Duration::from_secs(1), ws_a.next())
        .await
        .expect("timed out waiting for route_error")
        .unwrap()
        .unwrap();
    let v: serde_json::Value = serde_json::from_str(nack.to_text().unwrap()).unwrap();
    assert_eq!(v["type"], "route_error", "got: {v}");
    assert_eq!(v["peer"], dest);
    assert_eq!(v["room"], "deadroom");

    // Same destination again inside the 5 s window → suppressed (silence,
    // not a duplicate NACK).
    ws_a
        .send(Message::text(
            json!({"peer": dest, "room": "deadroom", "ct": "aGVsbG8="}).to_string(),
        ))
        .await
        .unwrap();
    let result =
        tokio::time::timeout(tokio::time::Duration::from_millis(200), ws_a.next()).await;
    assert!(
        result.is_err(),
        "expected no duplicate route_error within the TTL, got {:?}",
        result
    );

    // A DIFFERENT dead destination is not suppressed by the first NACK.
    ws_a
        .send(Message::text(
            json!({"peer": dest, "room": "otherroom", "ct": "aGVsbG8="}).to_string(),
        ))
        .await
        .unwrap();
    let nack2 = tokio::time::timeout(tokio::time::Duration::from_secs(1), ws_a.next())
        .await
        .expect("timed out waiting for second route_error (different room)")
        .unwrap()
        .unwrap();
    let v2: serde_json::Value = serde_json::from_str(nack2.to_text().unwrap()).unwrap();
    assert_eq!(v2["type"], "route_error");
    assert_eq!(v2["room"], "otherroom");
}

/// A successful forward must NOT produce a route_error for that destination
/// (the NACK is purely a failure signal, never a delivery receipt).
#[tokio::test]
async fn successful_forward_never_nacks() {
    let port = start_relay().await;
    let (mut ws_a, _) = connect_and_auth(port).await;
    let (mut ws_b, peer_b) = connect_and_auth_with_room(port, &random_key(), "alive").await;

    ws_a
        .send(Message::text(
            json!({"peer": peer_b, "room": "alive", "ct": "aGVsbG8="}).to_string(),
        ))
        .await
        .unwrap();

    let received = tokio::time::timeout(tokio::time::Duration::from_secs(1), ws_b.next())
        .await
        .expect("timed out waiting for forwarded message")
        .unwrap()
        .unwrap();
    let v: serde_json::Value = serde_json::from_str(received.to_text().unwrap()).unwrap();
    assert_eq!(v["ct"], "aGVsbG8=");

    let result =
        tokio::time::timeout(tokio::time::Duration::from_millis(200), ws_a.next()).await;
    assert!(
        result.is_err(),
        "sender must not receive anything on success, got {:?}",
        result
    );
}

/// Plan/141 — an envelope sent while the destination peer is offline is
/// parked in the room's mailbox instead of dropped, and replayed — in
/// original order, before any live traffic — to the next real connection
/// at that (peer, room).
#[tokio::test]
async fn mailbox_replays_to_reconnecting_peer() {
    let port = start_relay().await;
    let phone = random_key();

    // Phone connects, then goes dark.
    let (ws_phone, phone_peer) = connect_and_auth_with_room(port, &phone, "chat").await;
    drop(ws_phone);
    tokio::time::sleep(std::time::Duration::from_millis(400)).await;

    // Ext tries to deliver two envelopes to the offline phone.
    let (mut ws_ext, _) = connect_and_auth(port).await;
    for marker in ["parked-1", "parked-2"] {
        ws_ext
            .send(Message::text(
                json!({"peer": phone_peer, "room": "chat", "ct": marker}).to_string(),
            ))
            .await
            .unwrap();
    }
    // The route_error NACK (plan/137) arrives for the sender — drain it.
    let _ = tokio::time::timeout(std::time::Duration::from_millis(500), ws_ext.next()).await;
    let _ = tokio::time::timeout(std::time::Duration::from_millis(200), ws_ext.next()).await;

    // Phone reconnects: mailbox backlog first, then live traffic.
    let (mut ws_phone2, _) = connect_and_auth_with_room(port, &phone, "chat").await;
    for marker in ["parked-1", "parked-2"] {
        let frame = tokio::time::timeout(std::time::Duration::from_secs(1), ws_phone2.next())
            .await
            .expect("timed out waiting for mailbox replay")
            .unwrap()
            .unwrap();
        let v: serde_json::Value = serde_json::from_str(frame.to_text().unwrap()).unwrap();
        assert_eq!(v["ct"], marker, "mailbox must replay in order");
    }
    ws_ext
        .send(Message::text(
            json!({"peer": phone_peer, "room": "chat", "ct": "live-3"}).to_string(),
        ))
        .await
        .unwrap();
    let live = tokio::time::timeout(std::time::Duration::from_secs(1), ws_phone2.next())
        .await
        .expect("timed out waiting for live frame after replay")
        .unwrap()
        .unwrap();
    let v: serde_json::Value = serde_json::from_str(live.to_text().unwrap()).unwrap();
    assert_eq!(v["ct"], "live-3");
}

/// Plan/141 — a keeper connection (fallback presence) must NOT drain the
/// mailbox: the backlog belongs to the real device that reconnects later.
#[tokio::test]
async fn mailbox_keeper_does_not_consume_backlog() {
    let port = start_relay().await;
    let phone = random_key();

    let (ws_phone, phone_peer) = connect_and_auth_with_room(port, &phone, "chat").await;
    drop(ws_phone);
    tokio::time::sleep(std::time::Duration::from_millis(400)).await;

    let (mut ws_ext, _) = connect_and_auth(port).await;
    ws_ext
        .send(Message::text(
            json!({"peer": phone_peer, "room": "chat", "ct": "parked-1"}).to_string(),
        ))
        .await
        .unwrap();
    let _ = tokio::time::timeout(std::time::Duration::from_millis(500), ws_ext.next()).await;

    // Keeper takes the dark room (hello with room_meta.keeper).
    let url = format!("ws://127.0.0.1:{port}");
    use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
    let (mut ws_keeper, _) = tokio_tungstenite::connect_async(&url).await.unwrap();
    ws_keeper
        .send(Message::text(
            json!({
                "type": "hello",
                "pubkey": B64.encode(phone.verifying_key().to_bytes()),
                "room_id": "chat",
                "room_meta": {"name": "k", "cwd": "k", "keeper": true}
            })
            .to_string(),
        ))
        .await
        .unwrap();
    let challenge: serde_json::Value =
        serde_json::from_str(ws_keeper.next().await.unwrap().unwrap().to_text().unwrap()).unwrap();
    assert_eq!(challenge["type"], "challenge");
    let nonce: [u8; 32] = B64
        .decode(challenge["nonce"].as_str().unwrap())
        .unwrap()
        .try_into()
        .unwrap();
    ws_keeper
        .send(Message::text(
            json!({"type": "auth", "sig": B64.encode(phone.sign(&nonce).to_bytes())})
                .to_string(),
        ))
        .await
        .unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    let leaked =
        tokio::time::timeout(std::time::Duration::from_millis(300), ws_keeper.next()).await;
    assert!(leaked.is_err(), "keeper must not receive the backlog");

    // The real device still gets it afterwards.
    let (mut ws_phone2, _) = connect_and_auth_with_room(port, &phone, "chat").await;
    let frame = tokio::time::timeout(std::time::Duration::from_secs(1), ws_phone2.next())
        .await
        .expect("timed out waiting for backlog after keeper")
        .unwrap()
        .unwrap();
    let v: serde_json::Value = serde_json::from_str(frame.to_text().unwrap()).unwrap();
    assert_eq!(v["ct"], "parked-1");
}

/// Plan/141 — the mailbox is bounded: beyond the per-room cap the OLDEST
/// frames are dropped, so a long offline window cannot grow memory
/// without bound.
#[tokio::test]
async fn mailbox_is_capped_at_max_frames() {
    let port = start_relay().await;
    let phone = random_key();

    let (ws_phone, phone_peer) = connect_and_auth_with_room(port, &phone, "chat").await;
    drop(ws_phone);
    tokio::time::sleep(std::time::Duration::from_millis(400)).await;

    let (mut ws_ext, _) = connect_and_auth(port).await;
    for i in 0..105 {
        ws_ext
            .send(Message::text(
                json!({"peer": phone_peer, "room": "chat", "ct": format!("m-{i:03}")})
                    .to_string(),
            ))
            .await
            .unwrap();
    }
    // Give the relay a moment to process the burst, then go quiet.
    tokio::time::sleep(std::time::Duration::from_millis(700)).await;

    let (mut ws_phone2, _) = connect_and_auth_with_room(port, &phone, "chat").await;
    let mut first: Option<String> = None;
    let mut count = 0usize;
    while count <= 105 {
        match tokio::time::timeout(std::time::Duration::from_millis(250), ws_phone2.next()).await
        {
            Ok(Some(Ok(frame))) => {
                let v: serde_json::Value =
                    serde_json::from_str(frame.to_text().unwrap()).unwrap();
                if v.get("ct").is_some() {
                    if first.is_none() {
                        first = v["ct"].as_str().map(String::from);
                    }
                    count += 1;
                }
            }
            _ => break,
        }
    }
    assert_eq!(count, 100, "mailbox must deliver exactly the capped 100 frames");
    assert_eq!(first.as_deref(), Some("m-005"), "oldest frames are evicted");
}

/// A client that sends an invalid signature must have its WS closed within 100 ms.
#[tokio::test]
async fn invalid_sig_closes_ws() {
    let port = start_relay().await;
    let url = format!("ws://127.0.0.1:{port}");
    let (mut ws, _) = tokio_tungstenite::connect_async(&url).await.unwrap();

    use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
    use ed25519_dalek::SigningKey;
    let sk = SigningKey::generate(&mut rand::thread_rng());
    let vk = sk.verifying_key();

    // send hello
    ws.send(Message::text(
        json!({"type": "hello", "pubkey": B64.encode(vk.to_bytes())}).to_string(),
    ))
    .await
    .unwrap();

    // receive and ignore challenge (we won't sign correctly)
    let challenge_msg = ws.next().await.unwrap().unwrap();
    let v: serde_json::Value = serde_json::from_str(challenge_msg.to_text().unwrap()).unwrap();
    assert_eq!(v["type"], "challenge");

    // send all-zero signature (invalid)
    ws.send(Message::text(
        json!({"type": "auth", "sig": B64.encode([0u8; 64])}).to_string(),
    ))
    .await
    .unwrap();

    // relay must close within 100 ms
    let close_result =
        tokio::time::timeout(tokio::time::Duration::from_millis(100), ws.next()).await;

    assert!(
        close_result.is_ok(),
        "relay did not close the connection within 100 ms"
    );
    match close_result.unwrap() {
        None | Some(Ok(Message::Close(_))) | Some(Err(_)) => {} // all acceptable
        Some(Ok(other)) => panic!("unexpected message after bad auth: {other:?}"),
    }
}

/// Security fix 2026-08 — a client that completes `hello` but never sends
/// `auth` must be closed after the auth timeout instead of lingering
/// indefinitely.
#[tokio::test]
async fn auth_timeout_closes_half_handshake() {
    let port = start_relay().await;
    let url = format!("ws://127.0.0.1:{port}");
    let (mut ws, _) = tokio_tungstenite::connect_async(&url).await.unwrap();

    use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
    let sk = ed25519_dalek::SigningKey::generate(&mut rand::thread_rng());
    ws.send(Message::text(
        json!({"type": "hello", "pubkey": B64.encode(sk.verifying_key().to_bytes())})
            .to_string(),
    ))
    .await
    .unwrap();
    let challenge_msg = ws.next().await.unwrap().unwrap();
    let v: serde_json::Value = serde_json::from_str(challenge_msg.to_text().unwrap()).unwrap();
    assert_eq!(v["type"], "challenge");

    // ...and then silence. AUTH_TIMEOUT_MS is 5 s; close must arrive well
    // within 8 s.
    let closed = tokio::time::timeout(std::time::Duration::from_secs(8), ws.next()).await;
    assert!(
        closed.is_ok(),
        "relay must close the connection after the auth timeout"
    );
}

/// Plan/140 C — a keeper hello (room_meta.keeper=true) for a room that
/// already has a live connection must be rejected with `room_already_open`
/// BEFORE the challenge, so the keeper client throws RoomAlreadyOpenError
/// and backs off. Without this the duplicate-connection policy lets the
/// keeper coexist with the live session and its announce flips the app's
/// tile to "archive" while the agent runs.
#[tokio::test]
async fn keeper_hello_yields_to_live_room() {
    use base64::{Engine as _, engine::general_purpose::STANDARD as B64};

    let port = start_relay().await;
    let sk = random_key();

    // Real session holds the room.
    let (_ws_live, _peer) = connect_and_auth_with_room(port, &sk, "livetest").await;

    // Keeper hello for the same room: expect error(room_already_open)
    // instead of a challenge, then the socket closes.
    let url = format!("ws://127.0.0.1:{port}");
    let (mut ws, _) = tokio_tungstenite::connect_async(&url).await.unwrap();
    ws.send(Message::text(
        json!({
            "type": "hello",
            "pubkey": B64.encode(sk.verifying_key().to_bytes()),
            "room_id": "livetest",
            "room_meta": {"name": "x", "cwd": "x", "keeper": true}
        })
        .to_string(),
    ))
    .await
    .unwrap();
    let reply: serde_json::Value =
        serde_json::from_str(ws.next().await.unwrap().unwrap().to_text().unwrap()).unwrap();
    assert_eq!(reply["type"], "error");
    assert_eq!(reply["code"], "room_already_open");
    let closed = tokio::time::timeout(std::time::Duration::from_secs(3), ws.next()).await;
    assert!(closed.is_ok(), "keeper hello must close the connection");

    // A keeper hello for a FREE room still completes the handshake normally
    // (challenge arrives, auth proceeds).
    let (mut ws2, _) = tokio_tungstenite::connect_async(&url).await.unwrap();
    ws2.send(Message::text(
        json!({
            "type": "hello",
            "pubkey": B64.encode(sk.verifying_key().to_bytes()),
            "room_id": "freetest",
            "room_meta": {"name": "x", "cwd": "x", "keeper": true}
        })
        .to_string(),
    ))
    .await
    .unwrap();
    let challenge: serde_json::Value =
        serde_json::from_str(ws2.next().await.unwrap().unwrap().to_text().unwrap()).unwrap();
    assert_eq!(challenge["type"], "challenge");
}

/// Plan/140 D — a half-open connection that stops answering the relay's
/// heartbeat Pings (no inbound frame at all) is REAPED after
/// `reap_silence`: the room/presence goes offline for real instead of
/// ghosting "online" with a dead receiver until TCP teardown notices
/// (which on a quiet NAT path can take many minutes).
///
/// Mechanics: the silent client simply never READS its socket after the
/// auth handshake — tungstenite answers Pings in its read path, so a
/// stream that is never polled never pongs. Timings are tightened via a
/// directly-built AppState (heartbeat 1 s, reap 2 s — prod env floors do
/// not apply to tests).
#[tokio::test]
async fn silent_half_open_connection_is_reaped() {
    let port = common::start_relay_with_timings(1, 2).await;
    let sk = random_key();

    // Client A: full auth into a room, then eternal silence. The stream is
    // deliberately NOT polled during the reap window — tungstenite answers
    // Pings in its read path, so polling would pong and keep it alive.
    let (mut ws_a, _peer_a) = connect_and_auth_with_room(port, &sk, "ghostroom").await;

    // Reap window is 2 s + up to one 1 s tick; 6 s covers it with margin.
    tokio::time::sleep(std::time::Duration::from_secs(6)).await;

    // Now drain: the relay has already reaped, so after the buffered
    // heartbeat Pings the stream must END (Close/None/Err). Without the
    // reaper, fresh Pings keep arriving every second and the stream never
    // ends within the budget.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    let mut ended = false;
    while std::time::Instant::now() < deadline {
        match tokio::time::timeout(std::time::Duration::from_millis(1200), ws_a.next()).await {
            Ok(None) | Ok(Some(Err(_))) | Ok(Some(Ok(Message::Close(_)))) => {
                ended = true;
                break;
            }
            Ok(Some(Ok(_))) => continue, // buffered Ping/Close-precursor — keep draining
            Err(_) => {
                // No frame for 1.2 s — with a 1 s heartbeat cadence that only
                // happens when the server stopped sending: the reap worked,
                // the close frame just didn't survive the wire.
                ended = true;
                break;
            }
        }
    }
    assert!(ended, "silent half-open connection must be reaped by the relay");
}
