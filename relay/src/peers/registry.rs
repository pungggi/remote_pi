use std::collections::HashMap;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicU64, Ordering},
};
use std::time::{SystemTime, UNIX_EPOCH};

use axum::extract::ws::Message;
use tokio::sync::mpsc;

use crate::metrics::FirehoseMetrics;
use crate::presence::PresenceManager;
use crate::rooms::{RoomManager, RoomMeta, RoomMetaPatch};

type RoomKey = (String, String); // (peer_id, room_id)
type ConnEntry = (u64, RoomMeta, mpsc::UnboundedSender<Message>);

/// Maps `(peer_id, room_id)` pairs to a *list* of live connections.
///
/// Plan 23 (Wave 2C) relaxed the "one connection per (peer, room)" invariant:
/// the registry now accepts N simultaneous connections at the same key —
/// representing N devices of the same human Owner (shared Ed25519 key
/// sincronizada via iCloud Keychain / Block Store). Each device authenticates
/// independently via challenge-response, so admission is still controlled by
/// possession of the private key.
///
/// When another peer forwards a message to `(owner_pk, room_id)`, every live
/// conn in the corresponding `Vec` receives a copy. The originating connection
/// skips itself via `from_conn_id`, so a multi-device app sees outgoing
/// messages only on the device that sent them.
///
/// Lifecycle events:
/// - `room_announced` fires once, when the *first* conn opens a room.
/// - `room_ended` fires once, when the *last* conn at a room disconnects.
/// - `peer_online` fires only on a real **offline → online** transition: when
///   the peer had **zero** live conns immediately before this register. A
///   second/third conn from the same peer is silently absorbed (no extra
///   `peer_online` for subscribers). The historic "ALWAYS fires" defense
///   against zombie conns was retired here because (a) clients now dedupe
///   client-side anyway and (b) it was generating a firehose of identical
///   frames whenever multiple Owner devices reconnected.
///
///   Zombie reasoning: if a phantom conn is still in the map, `was_offline ==
///   false` and we skip the emit — subscribers already think the peer is
///   online (which is still effectively true at the public protocol level).
///   When the zombie is finally cleaned, `unregister` only fires
///   `peer_offline` if the **whole** peer is gone — never wrongly while a
///   real conn is alive.
/// - `peer_offline` fires only when the peer transitions from N → 0 total
///   connections (asymmetric still: online and offline both gated by real
///   state changes, but the offline edge is the authoritative one).
#[derive(Debug)]
pub struct PeerRegistry {
    next_conn: AtomicU64,
    senders: Mutex<HashMap<RoomKey, Vec<ConnEntry>>>,
    presence: Arc<PresenceManager>,
    rooms: Arc<RoomManager>,
    metrics: Arc<FirehoseMetrics>,
}

impl PeerRegistry {
    pub fn new(
        presence: Arc<PresenceManager>,
        rooms: Arc<RoomManager>,
        metrics: Arc<FirehoseMetrics>,
    ) -> Self {
        Self {
            next_conn: AtomicU64::new(0),
            senders: Mutex::new(HashMap::new()),
            presence,
            rooms,
            metrics,
        }
    }

    /// Registers a new connection at `(peer_id, room_meta.room_id)`.
    ///
    /// Multiple connections may coexist at the same key — each gets a unique
    /// `conn_id`. `room_announced` fires only on the **first** conn at the
    /// room (to avoid spamming metadata churn). `peer_online` fires only
    /// when `was_offline_before == true` — i.e. on a real offline→online
    /// transition, not on every register. See struct-level docs.
    pub async fn register(
        &self,
        peer_id: String,
        room_meta: RoomMeta,
        tx: mpsc::UnboundedSender<Message>,
    ) -> u64 {
        let room_id = room_meta.room_id.clone();
        let key = (peer_id.clone(), room_id.clone());

        let conn_id = self.next_conn.fetch_add(1, Ordering::Relaxed);

        // Compute both flags **before** the insert so they reflect the prior
        // state of the registry.
        let (was_offline_before, is_first_in_room) = {
            let mut lock = self.senders.lock().unwrap();
            let was_offline_before = !lock.keys().any(|(p, _)| p == &peer_id);
            let is_first_in_room = !lock.contains_key(&key);
            lock.entry(key)
                .or_default()
                .push((conn_id, room_meta.clone(), tx));
            (was_offline_before, is_first_in_room)
        };

        // room_announced fires once per (peer, room) lifecycle.
        if is_first_in_room {
            let room_subs = self.rooms.subscribers_of(&peer_id).await;
            if !room_subs.is_empty() {
                let mut announced =
                    serde_json::to_value(&room_meta).expect("RoomMeta serialization is infallible");
                announced["type"] = "room_announced".into();
                announced["peer"] = peer_id.as_str().into();
                let msg = announced.to_string();
                for sub in &room_subs {
                    self.forward_to_all_rooms_of(sub, Message::Text(msg.clone()));
                }
            }
        }

        // peer_online fires only on a real offline → online transition.
        // Re-registers from a peer that already had a live conn produce no
        // new push to subscribers — they already think it's online.
        let pres_subs = self.presence.subscribers_of(&peer_id).await;
        let sub_count = pres_subs.len() as u64;
        if sub_count > 0 {
            if was_offline_before {
                let msg = serde_json::json!({"type": "peer_online", "peer": peer_id}).to_string();
                for sub in pres_subs {
                    self.forward_to_all_rooms_of(&sub, Message::Text(msg.clone()));
                }
                self.metrics.inc_peer_online_emitted(sub_count);
            } else {
                self.metrics.inc_peer_online_suppressed(sub_count);
            }
        }

        conn_id
    }

    /// Immediately pushes a `peer_online` to `subscriber` for every peer in
    /// `peers` that is currently online. Called by the handler right after
    /// `subscribe_presence` to bridge the gap when a peer subscribed *after*
    /// its target was already connected.
    pub fn backfill_presence(&self, subscriber: &str, peers: &[String]) {
        for peer in peers {
            if self.is_online(peer) {
                let msg = serde_json::json!({"type": "peer_online", "peer": peer}).to_string();
                self.forward_to_all_rooms_of(subscriber, Message::Text(msg));
            }
        }
    }

    /// Removes the connection identified by `conn_id` from the `Vec` at
    /// `(peer_id, room_id)`. When the `Vec` empties, the entry is removed and
    /// `room_ended` is broadcast; when the peer has no remaining rooms,
    /// `peer_offline` is also broadcast.
    ///
    /// Stale `conn_id`s (already removed, or never registered there) are no-ops.
    pub async fn unregister(&self, peer_id: &str, room_id: &str, conn_id: u64) {
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;

        let (room_emptied, peer_offlined) = {
            let mut lock = self.senders.lock().unwrap();
            let key = (peer_id.to_string(), room_id.to_string());
            let mut room_emptied = false;
            if let Some(v) = lock.get_mut(&key) {
                let before = v.len();
                v.retain(|(cid, _, _)| *cid != conn_id);
                let removed_something = v.len() != before;
                if v.is_empty() {
                    lock.remove(&key);
                    room_emptied = removed_something;
                }
            }
            let peer_offlined = room_emptied && !lock.keys().any(|(p, _)| p == peer_id);
            (room_emptied, peer_offlined)
        };

        if room_emptied {
            let room_subs = self.rooms.subscribers_of(peer_id).await;
            if !room_subs.is_empty() {
                let msg = serde_json::json!({
                    "type": "room_ended",
                    "peer": peer_id,
                    "room_id": room_id,
                    "since_ts": now_ms,
                })
                .to_string();
                for sub in &room_subs {
                    self.forward_to_all_rooms_of(sub, Message::Text(msg.clone()));
                }
            }
        }

        if peer_offlined {
            let pres_subs = self.presence.subscribers_of(peer_id).await;
            if !pres_subs.is_empty() {
                let msg = serde_json::json!({
                    "type": "peer_offline",
                    "peer": peer_id,
                    "since_ts": now_ms,
                })
                .to_string();
                for sub in pres_subs {
                    self.forward_to_all_rooms_of(&sub, Message::Text(msg.clone()));
                }
            }
            self.presence.record_offline(peer_id, now_ms).await;
            self.presence.unsubscribe_all(peer_id).await;
        }
    }

    /// Returns `true` if `peer_id` has at least one live connection.
    pub fn is_online(&self, peer_id: &str) -> bool {
        let lock = self.senders.lock().unwrap();
        lock.keys().any(|(p, _)| p == peer_id)
    }

    /// Returns one `RoomMeta` per distinct room of `peer_id`.
    /// Multiple conns at the same room collapse to a single entry (using
    /// the most recently registered meta for stability).
    pub fn rooms_of(&self, peer_id: &str) -> Vec<RoomMeta> {
        let lock = self.senders.lock().unwrap();
        let mut by_room: HashMap<String, RoomMeta> = HashMap::new();
        for ((p, _), v) in lock.iter() {
            if p == peer_id
                && let Some((_, meta, _)) = v.last()
            {
                by_room.insert(meta.room_id.clone(), meta.clone());
            }
        }
        by_room.into_values().collect()
    }

    /// Broadcasts `msg` to every live connection at `(dest_peer, dest_room)`
    /// **except** the one whose conn_id equals `from_conn_id` (skip-sender).
    ///
    /// Returns `true` if at least one recipient received the message.
    /// Pass any `from_conn_id` that is not part of the destination `Vec`
    /// (e.g. the sender's own conn_id from another room) to deliver to all.
    /// Never inspects message content.
    pub fn forward(
        &self,
        dest_peer: &str,
        dest_room: &str,
        msg: Message,
        from_conn_id: u64,
    ) -> bool {
        let lock = self.senders.lock().unwrap();
        let key = (dest_peer.to_string(), dest_room.to_string());
        let Some(v) = lock.get(&key) else {
            return false;
        };
        let mut delivered = false;
        for (cid, _, tx) in v.iter() {
            if *cid == from_conn_id {
                continue;
            }
            if tx.send(msg.clone()).is_ok() {
                delivered = true;
            }
        }
        delivered
    }

    /// Applies `patch` to every live conn at `(peer_id, room_id)` and
    /// broadcasts `room_meta_updated` to room subscribers — but ONLY when the
    /// patch actually changes the broadcast-relevant state of ANY live conn
    /// at the pair (suppression fix 2026-08-22: identical re-pushes are
    /// silently absorbed, counted in the firehose `rooms_suppressed` metric).
    /// Returns `false` when no entries exist for the pair (so the handler can
    /// log and drop).
    ///
    /// Patch semantics: only fields explicitly present in `patch` are written
    /// (see [`RoomMetaPatch`]). The broadcast carries the **post-patch**
    /// full state of the mutable fields — subscribers replace their cached
    /// `meta` wholesale instead of merging field-by-field. Nullable fields
    /// that are still `None` after the patch are omitted from `meta` (matching
    /// the `skip_serializing_if` convention used for `RoomMeta` itself); the
    /// non-nullable `working` bool is always present in the broadcast.
    ///
    /// Plan/132 exception — `patch.run_done` is **broadcast-only**: it is
    /// never written to the stored metas, it rides the broadcast verbatim
    /// from the patch, and its presence forces the broadcast even when the
    /// stored state is otherwise unchanged (each marker is unique by
    /// `ended_at`, so it can never be absorbed by the identical-frame
    /// suppression below).
    ///
    /// An empty patch (no fields present) still returns `true` if the
    /// `(peer, room)` pair exists, but skips the broadcast — nothing changed.
    pub async fn update_room_meta(
        &self,
        peer_id: &str,
        room_id: &str,
        patch: RoomMetaPatch,
    ) -> bool {
        let (
            current_model,
            current_thinking,
            current_working,
            current_waiting_for_input,
            current_git,
            current_context_usage,
            changed,
        ) = {
            let mut lock = self.senders.lock().unwrap();
            let key = (peer_id.to_string(), room_id.to_string());
            match lock.get_mut(&key) {
                Some(v) if !v.is_empty() => {
                    // Suppression fix (2026-08-22; PR #51 review, medium):
                    // detect the change PER ENTRY, not against a single
                    // "canonical" conn. Conns at one (peer, room) may carry
                    // divergent metas (each `register` pushes the new conn's
                    // own meta) and `rooms_of` serves `v.last()` — a patch
                    // that leaves the first entry untouched while changing a
                    // later one still changes the registry's advertised
                    // state and MUST broadcast, or snapshot-based subscribers
                    // (including `working`) go stale.
                    let mut changed = false;
                    for (_, meta, _) in v.iter_mut() {
                        let before = (
                            meta.model.clone(),
                            meta.thinking.clone(),
                            meta.working,
                            meta.waiting_for_input,
                            meta.git.clone(),
                            meta.context_usage.clone(),
                        );
                        if let Some(ref m) = patch.model {
                            meta.model = m.clone();
                        }
                        if let Some(ref t) = patch.thinking {
                            meta.thinking = t.clone();
                        }
                        if let Some(w) = patch.working {
                            meta.working = w;
                        }
                        // Plan/134 — blocking-prompt flag toggle.
                        if let Some(w) = patch.waiting_for_input {
                            meta.waiting_for_input = w;
                        }
                        // Plan/107b — opaque git snapshot passthrough.
                        if let Some(ref g) = patch.git {
                            meta.git = g.clone();
                        }
                        // Opaque context-usage passthrough.
                        if let Some(ref cu) = patch.context_usage {
                            meta.context_usage = cu.clone();
                        }
                        let after = (
                            meta.model.clone(),
                            meta.thinking.clone(),
                            meta.working,
                            meta.waiting_for_input,
                            meta.git.clone(),
                            meta.context_usage.clone(),
                        );
                        if after != before {
                            changed = true;
                        }
                    }
                    // Canonical snapshot for the broadcast payload (the
                    // post-patch first conn — same source the broadcast has
                    // always used; the per-entry detection above is what
                    // guards `rooms_of`'s last-entry view against staleness).
                    let head = v.first().expect("v is non-empty");
                    (
                        head.1.model.clone(),
                        head.1.thinking.clone(),
                        head.1.working,
                        head.1.waiting_for_input,
                        head.1.git.clone(),
                        head.1.context_usage.clone(),
                        changed,
                    )
                }
                _ => return false,
            }
        };

        // Empty patch, or a patch that wrote the values every conn already
        // had → state didn't change, suppress broadcast. Suppressed meta
        // updates land in the same firehose counter as suppressed
        // `rooms_check` replies (observability: the 10s log line shows the
        // dam working).
        // Plan/132 — a `run_done` marker overrides the suppression: it is
        // not stored state, it is an event, and its payload is unique per
        // run, so "identical re-push" cannot apply to it.
        let marker = patch.run_done.clone();
        if (patch.is_empty() || !changed) && marker.is_none() {
            if !patch.is_empty() {
                self.metrics.inc_rooms_suppressed(1);
            }
            return true;
        }

        let room_subs = self.rooms.subscribers_of(peer_id).await;
        // Metric semantics (PR #51 review, low): `rooms_emitted` counts
        // subscribers actually fanned out to. A changed update with zero
        // subscribers sends nothing — no phantom emission — and counting
        // per subscriber matches the `peer_online` convention (each
        // subscriber may hold several live conns; `forward_to_all_rooms_of`
        // does the per-conn fan-out).
        if room_subs.is_empty() {
            return true;
        }
        self.metrics.inc_rooms_emitted(room_subs.len() as u64);
        if !room_subs.is_empty() {
            let mut meta_obj = serde_json::Map::new();
            if let Some(m) = &current_model {
                meta_obj.insert("model".to_string(), serde_json::Value::String(m.clone()));
            }
            if let Some(t) = &current_thinking {
                meta_obj.insert("thinking".to_string(), serde_json::Value::String(t.clone()));
            }
            // `working` is always present (non-nullable bool), so it always
            // rides along in the broadcast — subscribers can rely on it.
            meta_obj.insert(
                "working".to_string(),
                serde_json::Value::Bool(current_working),
            );
            // Plan/134 — same always-present convention for the
            // blocking-prompt flag.
            meta_obj.insert(
                "waiting_for_input".to_string(),
                serde_json::Value::Bool(current_waiting_for_input),
            );
            // Plan/107b — opaque git snapshot (only when the Pi reported one).
            if let Some(g) = &current_git {
                meta_obj.insert("git".to_string(), g.clone());
            }
            // Opaque context-usage snapshot (only when the Pi reported one).
            if let Some(cu) = &current_context_usage {
                meta_obj.insert("context_usage".to_string(), cu.clone());
            }
            // Plan/132 — run-completion marker: forwarded verbatim from the
            // patch, never from stored state (it is not stored).
            if let Some(rd) = &marker {
                meta_obj.insert("run_done".to_string(), rd.clone());
            }
            let msg = serde_json::json!({
                "type": "room_meta_updated",
                "peer": peer_id,
                "room_id": room_id,
                "meta": serde_json::Value::Object(meta_obj),
            })
            .to_string();
            for sub in &room_subs {
                self.forward_to_all_rooms_of(sub, Message::Text(msg.clone()));
            }
        }

        true
    }

    /// Sends `msg` to every live connection of `peer_id` across all rooms.
    /// Used for control-frame pushes (`peer_online`/`peer_offline`,
    /// `room_announced`/`room_ended`, `room_meta_updated`) where the
    /// subscriber's room isn't known in advance.
    fn forward_to_all_rooms_of(&self, peer_id: &str, msg: Message) {
        let lock = self.senders.lock().unwrap();
        for ((p, _), v) in lock.iter() {
            if p == peer_id {
                for (_, _, tx) in v.iter() {
                    let _ = tx.send(msg.clone());
                }
            }
        }
    }

    /// Sends `msg` to every live connection of `peer_id`, regardless of room.
    /// Returns `true` iff at least one recipient successfully accepted it.
    /// Used by `pi_envelope` cross-PC forwarding (plan 25) where the relay
    /// has Pi-B's pubkey but not its room_id.
    pub fn forward_to_peer(&self, peer_id: &str, msg: Message) -> bool {
        let lock = self.senders.lock().unwrap();
        let mut delivered = false;
        for ((p, _), v) in lock.iter() {
            if p == peer_id {
                for (_, _, tx) in v.iter() {
                    if tx.send(msg.clone()).is_ok() {
                        delivered = true;
                    }
                }
            }
        }
        delivered
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::presence::PresenceManager;
    use crate::rooms::{RoomManager, RoomMeta};

    fn make_meta(room_id: &str) -> RoomMeta {
        RoomMeta {
            room_id: room_id.into(),
            name: None,
            cwd: None,
            model: None,
            thinking: None,
            working: false,
            waiting_for_input: false,
            git: None,
            context_usage: None,
            started_at: 0,
        }
    }

    fn make_registry() -> PeerRegistry {
        let presence = Arc::new(PresenceManager::new());
        let rooms = Arc::new(RoomManager::new());
        let metrics = Arc::new(FirehoseMetrics::new());
        PeerRegistry::new(presence, rooms, metrics)
    }

    /// Sentinel `from_conn_id` for "no real sender to skip" — guaranteed not
    /// to collide with any conn_id allocated by the registry in tests.
    const EXTERNAL: u64 = u64::MAX;

    #[tokio::test]
    async fn two_rooms_same_peer_both_accepted() {
        let reg = make_registry();
        let peer = "peer_a".to_string();

        let (tx_main, mut rx_main) = mpsc::unbounded_channel::<Message>();
        let (tx_work, mut rx_work) = mpsc::unbounded_channel::<Message>();

        let conn_main = reg.register(peer.clone(), make_meta("main"), tx_main).await;
        let conn_work = reg.register(peer.clone(), make_meta("work"), tx_work).await;

        assert_ne!(conn_main, conn_work);

        assert!(reg.forward(&peer, "main", Message::Text("to_main".into()), EXTERNAL));
        assert_eq!(rx_main.try_recv().unwrap().to_text().unwrap(), "to_main");

        assert!(reg.forward(&peer, "work", Message::Text("to_work".into()), EXTERNAL));
        assert_eq!(rx_work.try_recv().unwrap().to_text().unwrap(), "to_work");

        reg.unregister(&peer, "work", conn_work).await;
        assert!(!reg.forward(&peer, "work", Message::Text("gone".into()), EXTERNAL));
        assert!(reg.forward(&peer, "main", Message::Text("still_there".into()), EXTERNAL));
        let _ = rx_main.try_recv();
    }

    /// Two conns at the same (peer, room) now coexist. `forward` with the first
    /// conn's id as `from_conn_id` delivers only to the second (skip-sender).
    #[tokio::test]
    async fn duplicate_room_accepted_and_broadcast() {
        let reg = make_registry();
        let peer = "peer_a".to_string();

        let (tx1, mut rx1) = mpsc::unbounded_channel::<Message>();
        let (tx2, mut rx2) = mpsc::unbounded_channel::<Message>();

        let conn1 = reg.register(peer.clone(), make_meta("main"), tx1).await;
        let conn2 = reg.register(peer.clone(), make_meta("main"), tx2).await;
        assert_ne!(conn1, conn2);

        // Send "from" conn1 → only conn2 receives.
        assert!(reg.forward(&peer, "main", Message::Text("hi".into()), conn1));
        assert!(rx1.try_recv().is_err(), "sender must not echo");
        assert_eq!(rx2.try_recv().unwrap().to_text().unwrap(), "hi");

        // Send "from" conn2 → only conn1 receives.
        assert!(reg.forward(&peer, "main", Message::Text("hi2".into()), conn2));
        assert_eq!(rx1.try_recv().unwrap().to_text().unwrap(), "hi2");
        assert!(rx2.try_recv().is_err());
    }

    /// Three conns at same (peer, room); one disconnects; remaining two keep
    /// receiving broadcasts from external senders.
    #[tokio::test]
    async fn three_conns_one_disconnects_broadcast_continues() {
        let reg = make_registry();
        let peer = "peer_a".to_string();

        let (tx1, mut rx1) = mpsc::unbounded_channel::<Message>();
        let (tx2, mut rx2) = mpsc::unbounded_channel::<Message>();
        let (tx3, mut rx3) = mpsc::unbounded_channel::<Message>();

        let _conn1 = reg.register(peer.clone(), make_meta("main"), tx1).await;
        let conn2 = reg.register(peer.clone(), make_meta("main"), tx2).await;
        let _conn3 = reg.register(peer.clone(), make_meta("main"), tx3).await;

        reg.unregister(&peer, "main", conn2).await;

        assert!(reg.forward(&peer, "main", Message::Text("ping".into()), EXTERNAL));
        assert_eq!(rx1.try_recv().unwrap().to_text().unwrap(), "ping");
        assert!(
            rx2.try_recv().is_err(),
            "disconnected conn must not receive"
        );
        assert_eq!(rx3.try_recv().unwrap().to_text().unwrap(), "ping");
    }

    /// `from_conn_id` outside the destination Vec → all conns at that pair
    /// receive. Models the common "another peer sends to (owner_pk, main)" case.
    #[tokio::test]
    async fn forward_with_unknown_from_conn_id_reaches_all() {
        let reg = make_registry();
        let peer = "peer_a".to_string();

        let (tx1, mut rx1) = mpsc::unbounded_channel::<Message>();
        let (tx2, mut rx2) = mpsc::unbounded_channel::<Message>();

        let _ = reg.register(peer.clone(), make_meta("main"), tx1).await;
        let _ = reg.register(peer.clone(), make_meta("main"), tx2).await;

        assert!(reg.forward(&peer, "main", Message::Text("from_pi".into()), EXTERNAL));
        assert_eq!(rx1.try_recv().unwrap().to_text().unwrap(), "from_pi");
        assert_eq!(rx2.try_recv().unwrap().to_text().unwrap(), "from_pi");
    }

    /// Single-conn case: skip-sender with own id → nobody receives.
    /// External sender → that single conn receives.
    #[tokio::test]
    async fn single_conn_skip_sender() {
        let reg = make_registry();
        let peer = "peer_a".to_string();

        let (tx, mut rx) = mpsc::unbounded_channel::<Message>();
        let conn = reg.register(peer.clone(), make_meta("main"), tx).await;

        assert!(!reg.forward(&peer, "main", Message::Text("echo".into()), conn));
        assert!(rx.try_recv().is_err());

        assert!(reg.forward(&peer, "main", Message::Text("hi".into()), EXTERNAL));
        assert_eq!(rx.try_recv().unwrap().to_text().unwrap(), "hi");
    }

    /// Re-calling `unregister` with a stale `conn_id` does not affect any
    /// other live conn at the same key.
    #[tokio::test]
    async fn stale_unregister_is_noop() {
        let reg = make_registry();
        let peer = "peer_a".to_string();

        let (tx_a, _) = mpsc::unbounded_channel::<Message>();
        let (tx_b, mut rx_b) = mpsc::unbounded_channel::<Message>();

        let conn_a = reg.register(peer.clone(), make_meta("main"), tx_a).await;
        reg.unregister(&peer, "main", conn_a).await;
        let conn_b = reg.register(peer.clone(), make_meta("main"), tx_b).await;

        // Stale unregister of conn_a is a no-op.
        reg.unregister(&peer, "main", conn_a).await;
        assert!(reg.forward(&peer, "main", Message::Text("alive".into()), EXTERNAL));
        assert_eq!(rx_b.try_recv().unwrap().to_text().unwrap(), "alive");

        // Correct unregister removes the last conn → entry gone.
        reg.unregister(&peer, "main", conn_b).await;
        assert!(!reg.forward(&peer, "main", Message::Text("gone".into()), EXTERNAL));
    }

    /// First register from an offline peer with a presence subscriber must
    /// emit one `peer_online`; a second register from the **same** peer (no
    /// real transition) must NOT emit again and must bump the suppressed
    /// counter instead.
    #[tokio::test]
    async fn peer_online_fires_only_on_real_transition() {
        let presence = Arc::new(PresenceManager::new());
        let rooms = Arc::new(RoomManager::new());
        let metrics = Arc::new(FirehoseMetrics::new());
        let reg = PeerRegistry::new(presence.clone(), rooms, metrics.clone());

        let pi = "pi".to_string();
        let app = "app".to_string();

        // App is online and subscribes to Pi's presence.
        let (tx_app, mut rx_app) = mpsc::unbounded_channel::<Message>();
        let _ = reg.register(app.clone(), make_meta("main"), tx_app).await;
        presence.subscribe(app.clone(), vec![pi.clone()]).await;

        // First Pi conn → real offline→online → app receives peer_online.
        let (tx_pi_1, _) = mpsc::unbounded_channel::<Message>();
        let _ = reg.register(pi.clone(), make_meta("main"), tx_pi_1).await;
        let m1 = rx_app.try_recv().unwrap();
        let v1: serde_json::Value = serde_json::from_str(m1.to_text().unwrap()).unwrap();
        assert_eq!(v1["type"], "peer_online");
        assert_eq!(v1["peer"], pi.clone());

        // Second conn from the same Pi (no transition) → no extra peer_online.
        let (tx_pi_2, _) = mpsc::unbounded_channel::<Message>();
        let _ = reg.register(pi.clone(), make_meta("work"), tx_pi_2).await;
        assert!(
            rx_app.try_recv().is_err(),
            "second register at already-online peer must NOT emit peer_online"
        );

        // Metrics: 1 emitted, 1 suppressed (each over 1 subscriber).
        let [emitted, suppressed, ..] = metrics.snapshot();
        assert_eq!(emitted, 1, "snapshot: {:?}", metrics.snapshot());
        assert_eq!(suppressed, 1, "snapshot: {:?}", metrics.snapshot());
    }

    /// Helper: a Pi with one `main` room plus an `app` subscribed to that
    /// peer's room events. Returns the registry, its firehose metrics handle,
    /// the peer id, and the app's receiver (drained of any backfill).
    async fn meta_fixture() -> (
        PeerRegistry,
        Arc<FirehoseMetrics>,
        String,
        mpsc::UnboundedReceiver<Message>,
    ) {
        let presence = Arc::new(PresenceManager::new());
        let rooms = Arc::new(RoomManager::new());
        let metrics = Arc::new(FirehoseMetrics::new());
        let reg = PeerRegistry::new(presence, rooms.clone(), metrics.clone());

        let pi = "pi".to_string();
        let app = "app".to_string();

        // Pi registers first, *before* the app subscribes — so the app gets no
        // `room_announced` backfill and its channel only carries the
        // `room_meta_updated` pushes the tests assert on.
        let (tx_pi, _rx_pi) = mpsc::unbounded_channel::<Message>();
        let _ = reg.register(pi.clone(), make_meta("main"), tx_pi).await;

        let (tx_app, rx_app) = mpsc::unbounded_channel::<Message>();
        let _ = reg.register(app.clone(), make_meta("main"), tx_app).await;
        rooms.subscribe(app.clone(), vec![pi.clone()]).await;

        (reg, metrics, pi, rx_app)
    }

    fn recv_meta(rx: &mut mpsc::UnboundedReceiver<Message>) -> serde_json::Value {
        let msg = rx
            .try_recv()
            .expect("subscriber must receive room_meta_updated");
        let v: serde_json::Value = serde_json::from_str(msg.to_text().unwrap()).unwrap();
        assert_eq!(v["type"], "room_meta_updated");
        v
    }

    /// `working: true` patch broadcasts the post-patch state to subscribers.
    #[tokio::test]
    async fn working_true_patch_broadcasts_true() {
        let (reg, _metrics, pi, mut rx_app) = meta_fixture().await;

        let patch = RoomMetaPatch {
            working: Some(true),
            ..Default::default()
        };
        assert!(reg.update_room_meta(&pi, "main", patch).await);

        let v = recv_meta(&mut rx_app);
        assert_eq!(v["peer"], pi);
        assert_eq!(v["room_id"], "main");
        assert_eq!(v["meta"]["working"], true);
    }

    /// `working: false` patch is a real (non-empty) patch and broadcasts
    /// `working: false` — flipping a previously-true room back off.
    #[tokio::test]
    async fn working_false_patch_broadcasts_false() {
        let (reg, _metrics, pi, mut rx_app) = meta_fixture().await;

        // Turn it on, then off.
        let _ = reg
            .update_room_meta(
                &pi,
                "main",
                RoomMetaPatch {
                    working: Some(true),
                    ..Default::default()
                },
            )
            .await;
        let _ = recv_meta(&mut rx_app); // drain the `true` broadcast

        assert!(
            reg.update_room_meta(
                &pi,
                "main",
                RoomMetaPatch {
                    working: Some(false),
                    ..Default::default()
                },
            )
            .await
        );

        let v = recv_meta(&mut rx_app);
        assert_eq!(v["meta"]["working"], false);
    }

    /// A patch that omits `working` (e.g. a model-only update) must NOT zero a
    /// previously-set `working: true` — merge-patch absence leaves it intact,
    /// and the broadcast re-carries the preserved value.
    #[tokio::test]
    async fn working_absent_patch_does_not_zero() {
        let (reg, _metrics, pi, mut rx_app) = meta_fixture().await;

        let _ = reg
            .update_room_meta(
                &pi,
                "main",
                RoomMetaPatch {
                    working: Some(true),
                    ..Default::default()
                },
            )
            .await;
        let _ = recv_meta(&mut rx_app); // drain the `true` broadcast

        // Model-only patch: `working` is absent → must be left untouched.
        assert!(
            reg.update_room_meta(
                &pi,
                "main",
                RoomMetaPatch {
                    model: Some(Some("opus".into())),
                    ..Default::default()
                },
            )
            .await
        );

        let v = recv_meta(&mut rx_app);
        assert_eq!(v["meta"]["model"], "opus");
        assert_eq!(
            v["meta"]["working"], true,
            "absent `working` in a patch must not clear it"
        );
    }

    /// Plan/134 — `waiting_for_input: true` patch broadcasts the post-patch
    /// state (same shape as `working_true_patch_broadcasts_true`).
    #[tokio::test]
    async fn waiting_for_input_true_patch_broadcasts_true() {
        let (reg, _metrics, pi, mut rx_app) = meta_fixture().await;

        let patch = RoomMetaPatch {
            waiting_for_input: Some(true),
            ..Default::default()
        };
        assert!(reg.update_room_meta(&pi, "main", patch).await);

        let v = recv_meta(&mut rx_app);
        assert_eq!(v["peer"], pi);
        assert_eq!(v["room_id"], "main");
        assert_eq!(v["meta"]["waiting_for_input"], true);
        // Always-serialized: the flag rides along even when `working` is the
        // unchanged default.
        assert_eq!(v["meta"]["working"], false);
    }

    /// Plan/134 — `waiting_for_input: false` flips a previously-true room
    /// back off and broadcasts the cleared state.
    #[tokio::test]
    async fn waiting_for_input_false_patch_broadcasts_false() {
        let (reg, _metrics, pi, mut rx_app) = meta_fixture().await;

        let _ = reg
            .update_room_meta(
                &pi,
                "main",
                RoomMetaPatch {
                    waiting_for_input: Some(true),
                    ..Default::default()
                },
            )
            .await;
        let _ = recv_meta(&mut rx_app); // drain the `true` broadcast

        assert!(
            reg.update_room_meta(
                &pi,
                "main",
                RoomMetaPatch {
                    waiting_for_input: Some(false),
                    ..Default::default()
                },
            )
            .await
        );

        let v = recv_meta(&mut rx_app);
        assert_eq!(v["meta"]["waiting_for_input"], false);
    }

    /// Plan/134 — a patch that omits `waiting_for_input` must NOT zero a
    /// previously-set `true` (merge-patch absence leaves it intact).
    #[tokio::test]
    async fn waiting_for_input_absent_patch_does_not_zero() {
        let (reg, _metrics, pi, mut rx_app) = meta_fixture().await;

        let _ = reg
            .update_room_meta(
                &pi,
                "main",
                RoomMetaPatch {
                    waiting_for_input: Some(true),
                    ..Default::default()
                },
            )
            .await;
        let _ = recv_meta(&mut rx_app); // drain the `true` broadcast

        // working-only patch: `waiting_for_input` is absent → untouched.
        assert!(
            reg.update_room_meta(
                &pi,
                "main",
                RoomMetaPatch {
                    working: Some(true),
                    ..Default::default()
                },
            )
            .await
        );

        let v = recv_meta(&mut rx_app);
        assert_eq!(v["meta"]["working"], true);
        assert_eq!(
            v["meta"]["waiting_for_input"], true,
            "absent `waiting_for_input` in a patch must not clear it"
        );
    }

    /// Suppression fix (2026-08-22): a patch that re-writes the values the
    /// room already carries must NOT broadcast again — identical
    /// `room_meta_updated` frames were amplifying the phone's reconnect
    /// churn into every subscriber. The patch still succeeds (returns true)
    /// and the stored state stays correct.
    #[tokio::test]
    async fn identical_patch_is_absorbed_without_broadcast() {
        let (reg, _metrics, pi, mut rx_app) = meta_fixture().await;

        // Establish state: working=true, model=opus.
        let _ = reg
            .update_room_meta(
                &pi,
                "main",
                RoomMetaPatch {
                    working: Some(true),
                    model: Some(Some("opus".into())),
                    ..Default::default()
                },
            )
            .await;
        let v = recv_meta(&mut rx_app); // drain the establishing broadcast
        assert_eq!(v["meta"]["working"], true);
        assert_eq!(v["meta"]["model"], "opus");

        // Same values again (explicitly present in the patch) → absorbed.
        for _ in 0..3 {
            assert!(
                reg.update_room_meta(
                    &pi,
                    "main",
                    RoomMetaPatch {
                        working: Some(true),
                        model: Some(Some("opus".into())),
                        ..Default::default()
                    },
                )
                .await,
                "identical patch must still succeed"
            );
        }
        assert!(
            rx_app.try_recv().is_err(),
            "identical room_meta_updated must NOT be re-broadcast"
        );

        // A REAL change still broadcasts.
        assert!(
            reg.update_room_meta(
                &pi,
                "main",
                RoomMetaPatch {
                    working: Some(false),
                    ..Default::default()
                },
            )
            .await
        );
        let v = recv_meta(&mut rx_app);
        assert_eq!(v["meta"]["working"], false);
        assert_eq!(v["meta"]["model"], "opus", "unchanged field re-carried");
    }

    /// Plan/132 — a `run_done` marker rides the broadcast even when stored
    /// state is unchanged, and is never persisted: a later patch's broadcast
    /// must not re-carry a stale marker.
    #[tokio::test]
    async fn run_done_marker_broadcasts_even_when_state_unchanged() {
        let (reg, _metrics, pi, mut rx_app) = meta_fixture().await;

        // Marker-only patch: nothing stored changes, but the marker is an
        // event, not state — it must reach subscribers.
        let marker = serde_json::json!({ "turn_id": "t-1", "ended_at": 1735689600000i64 });
        assert!(
            reg.update_room_meta(
                &pi,
                "main",
                RoomMetaPatch {
                    run_done: Some(marker.clone()),
                    ..Default::default()
                },
            )
            .await
        );

        let v = recv_meta(&mut rx_app);
        assert_eq!(v["meta"]["run_done"], marker);

        // Not persisted: a follow-up stored-field patch must NOT re-carry
        // the marker (a replayed marker would re-fire the phone's
        // completion notification).
        assert!(
            reg.update_room_meta(
                &pi,
                "main",
                RoomMetaPatch {
                    working: Some(true),
                    ..Default::default()
                },
            )
            .await
        );
        let v = recv_meta(&mut rx_app);
        assert_eq!(v["meta"]["working"], true);
        assert!(
            v["meta"].get("run_done").is_none(),
            "stored RoomMeta never carries run_done"
        );
    }

    /// Plan/132 — consecutive markers (unique `ended_at`) each broadcast;
    /// the identical-frame suppression cannot absorb them.
    #[tokio::test]
    async fn run_done_markers_are_not_deduped() {
        let (reg, _metrics, pi, mut rx_app) = meta_fixture().await;

        for (i, ts) in [1735689600000i64, 1735689660000].into_iter().enumerate() {
            let marker = serde_json::json!({ "turn_id": format!("t-{i}"), "ended_at": ts });
            assert!(
                reg.update_room_meta(
                    &pi,
                    "main",
                    RoomMetaPatch {
                        run_done: Some(marker),
                        ..Default::default()
                    },
                )
                .await
            );
            let v = recv_meta(&mut rx_app);
            assert_eq!(v["meta"]["run_done"]["ended_at"], ts);
        }
    }

    /// Suppression is exact-match: same token count but different opaque
    /// context_usage payload is a REAL change and must broadcast.
    #[tokio::test]
    async fn changed_opaque_context_usage_still_broadcasts() {
        let (reg, _metrics, pi, mut rx_app) = meta_fixture().await;

        let cu = |tokens: u64| {
            Some(Some(serde_json::json!({
                "tokens": tokens,
                "contextWindow": 200000,
            })))
        };

        let _ = reg
            .update_room_meta(
                &pi,
                "main",
                RoomMetaPatch {
                    context_usage: cu(1000),
                    ..Default::default()
                },
            )
            .await;
        let _ = recv_meta(&mut rx_app); // drain

        // Identical push → absorbed.
        assert!(
            reg.update_room_meta(
                &pi,
                "main",
                RoomMetaPatch {
                    context_usage: cu(1000),
                    ..Default::default()
                },
            )
            .await
        );
        assert!(rx_app.try_recv().is_err());

        // Token count moved → broadcast.
        assert!(
            reg.update_room_meta(
                &pi,
                "main",
                RoomMetaPatch {
                    context_usage: cu(1500),
                    ..Default::default()
                },
            )
            .await
        );
        let v = recv_meta(&mut rx_app);
        assert_eq!(v["meta"]["context_usage"]["tokens"], 1500);
    }

    /// PR #51 review (medium): conns at one (peer, room) may carry
    /// divergent metas — each `register` pushes the new conn's own meta, and
    /// `rooms_of` serves the LAST entry. A patch that leaves the first conn
    /// unchanged while changing a later one still changes the advertised
    /// state and must broadcast (old code compared only `v.first()` and
    /// wrongly suppressed, leaving snapshot subscribers stale).
    #[tokio::test]
    async fn patch_changing_only_a_later_conn_still_broadcasts() {
        let (reg, _metrics, pi, mut rx_app) = meta_fixture().await;

        // Second conn at the same (peer, room) with divergent meta:
        // working=true while the first conn carries the default false.
        // (No room_announced — not the first conn at the key; no peer_online
        // — the peer was already online. rx_app stays clean.)
        let mut diverged = make_meta("main");
        diverged.working = true;
        let (tx_pi2, _rx_pi2) = mpsc::unbounded_channel::<Message>();
        let _ = reg.register(pi.clone(), diverged, tx_pi2).await;

        // Patch working=false: first conn (false→false) unchanged, second
        // (true→false) changed → the registry's advertised state changed.
        assert!(
            reg.update_room_meta(
                &pi,
                "main",
                RoomMetaPatch {
                    working: Some(false),
                    ..Default::default()
                },
            )
            .await
        );

        // Must NOT be suppressed — and the post-patch state is consistent
        // with what rooms_of now advertises for the last conn.
        let v = recv_meta(&mut rx_app);
        assert_eq!(v["meta"]["working"], false);
        let rooms = reg.rooms_of(&pi);
        let main = rooms
            .iter()
            .find(|r| r.room_id == "main")
            .expect("main room");
        assert!(!main.working, "rooms_of (last conn) matches broadcast");
    }

    /// PR #51 review (low): `rooms_emitted` counts subscribers actually
    /// fanned out to — a changed patch with zero subscribers records
    /// nothing (no phantom emission), and with subscribers it counts them.
    #[tokio::test]
    async fn emission_metrics_follow_actual_subscribers() {
        let presence = Arc::new(PresenceManager::new());
        let rooms = Arc::new(RoomManager::new());
        let metrics = Arc::new(FirehoseMetrics::new());
        let reg = PeerRegistry::new(presence, rooms.clone(), metrics.clone());

        // Pi conn, NO subscriber yet.
        let (tx_pi, _rx_pi) = mpsc::unbounded_channel::<Message>();
        let _ = reg.register("pi".into(), make_meta("main"), tx_pi).await;
        let [.., rooms_emit, rooms_supp] = metrics.snapshot();

        // Real change, but nobody subscribed → no phantom emission and no
        // suppression (the state genuinely changed; it just had nowhere to
        // go).
        assert!(
            reg.update_room_meta(
                "pi",
                "main",
                RoomMetaPatch {
                    working: Some(true),
                    ..Default::default()
                },
            )
            .await
        );
        let [.., rooms_emit2, rooms_supp2] = metrics.snapshot();
        assert_eq!(rooms_emit2, rooms_emit, "no subscriber → no emitted frame");
        assert_eq!(
            rooms_supp2, rooms_supp,
            "changed state is not a suppression"
        );

        // Subscribe an app, then change again → emitted += 1 (per
        // subscriber, matching the peer_online convention).
        let (tx_app, _rx_app) = mpsc::unbounded_channel::<Message>();
        let _ = reg.register("app".into(), make_meta("main"), tx_app).await;
        rooms.subscribe("app".into(), vec!["pi".to_string()]).await;
        assert!(
            reg.update_room_meta(
                "pi",
                "main",
                RoomMetaPatch {
                    working: Some(false),
                    ..Default::default()
                },
            )
            .await
        );
        let [.., rooms_emit3, _] = metrics.snapshot();
        assert_eq!(rooms_emit3, rooms_emit + 1, "one subscriber → one emission");
    }
}
