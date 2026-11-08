//! Lightweight in-process counters for "firehose dedup" observability
//! (no Prometheus dependency — just structured `tracing::info!` lines that
//! grep cleanly).
//!
//! Each counter pairs `emitted` (frames actually sent on the wire) with
//! `suppressed` (frames the relay decided not to send because the snapshot
//! was identical to the previous one, or because the peer transition wasn't
//! real). A periodic reporter task drains them every 10 s.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

use tracing::info;

#[derive(Debug, Default)]
pub struct FirehoseMetrics {
    /// `peer_online` frames actually forwarded to presence subscribers.
    peer_online_emitted: AtomicU64,
    /// `peer_online` frames the relay decided NOT to forward because the
    /// peer was already online (no real offline→online transition).
    peer_online_suppressed: AtomicU64,
    /// `presence` snapshot frames actually returned to a `presence_check`.
    presence_emitted: AtomicU64,
    /// `presence` snapshot frames suppressed because identical to the
    /// previous reply on the same WS conn.
    presence_suppressed: AtomicU64,
    /// `rooms` snapshot frames actually returned to a `rooms_check`.
    rooms_emitted: AtomicU64,
    /// `rooms` snapshot frames suppressed because identical to the
    /// previous reply on the same (WS conn, target_peer) pair.
    rooms_suppressed: AtomicU64,
    /// Plan/164 measurement — per-conn `rooms_check` poll counts, drained
    /// every window. Attributes rooms traffic to the asking connection
    /// (phone app, cockpit, keeper, …) so a firehose flood has a name.
    rooms_poll_by_conn: Mutex<HashMap<String, u64>>,
    /// Plan/164 measurement — `rooms` replies sent, keyed by RECEIVING conn.
    /// Counted per (conn, target): a multi-target `rooms_check` frame makes
    /// `rooms_sent` exceed `rooms_poll` (which counts frames) — keep that in
    /// mind when reading the ratio in the window line.
    rooms_sent_by_conn: Mutex<HashMap<String, u64>>,
    /// Plan/164 measurement — `rooms` replies sent, keyed by TARGET peer.
    rooms_sent_by_target: Mutex<HashMap<String, u64>>,
}

/// Plan/164 measurement — drains a per-key counter map and renders the top
/// 3 entries as `id8=count, …` (peer ids truncated to 8 chars for greppable,
/// compact log lines). Empty maps render as `-`.
fn drain_top3(map: &Mutex<HashMap<String, u64>>) -> String {
    let Ok(mut m) = map.lock() else { return "-".to_string() };
    if m.is_empty() {
        return "-".to_string();
    }
    let mut entries: Vec<(String, u64)> = m.drain().collect();
    entries.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    entries
        .into_iter()
        .take(3)
        .map(|(k, v)| format!("{}={}", k.chars().take(8).collect::<String>(), v))
        .collect::<Vec<_>>()
        .join(",")
}

impl FirehoseMetrics {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn inc_peer_online_emitted(&self, n: u64) {
        self.peer_online_emitted.fetch_add(n, Ordering::Relaxed);
    }

    pub fn inc_peer_online_suppressed(&self, n: u64) {
        self.peer_online_suppressed.fetch_add(n, Ordering::Relaxed);
    }

    pub fn inc_presence_emitted(&self, n: u64) {
        self.presence_emitted.fetch_add(n, Ordering::Relaxed);
    }

    pub fn inc_presence_suppressed(&self, n: u64) {
        self.presence_suppressed.fetch_add(n, Ordering::Relaxed);
    }

    pub fn inc_rooms_emitted(&self, n: u64) {
        self.rooms_emitted.fetch_add(n, Ordering::Relaxed);
    }

    pub fn inc_rooms_suppressed(&self, n: u64) {
        self.rooms_suppressed.fetch_add(n, Ordering::Relaxed);
    }

    /// Plan/164 measurement — one `rooms_check` control frame arrived on
    /// the WS conn authenticated as `conn_peer` (counted once per frame,
    /// NOT per target peer inside it).
    pub fn note_rooms_poll(&self, conn_peer: &str) {
        if let Ok(mut m) = self.rooms_poll_by_conn.lock() {
            *m.entry(conn_peer.to_string()).or_insert(0) += 1;
        }
    }

    /// Plan/164 measurement — one `rooms` reply frame actually sent to
    /// `conn_peer` describing `target_peer`'s rooms.
    pub fn note_rooms_sent(&self, conn_peer: &str, target_peer: &str) {
        if let Ok(mut m) = self.rooms_sent_by_conn.lock() {
            *m.entry(conn_peer.to_string()).or_insert(0) += 1;
        }
        if let Ok(mut m) = self.rooms_sent_by_target.lock() {
            *m.entry(target_peer.to_string()).or_insert(0) += 1;
        }
    }

    /// Atomically drains every counter and, if anything happened in the
    /// window, emits a single structured `info!` line with the totals.
    /// Quiet windows are silent (no log spam when nothing's going on).
    pub fn report_and_reset(&self) {
        let peer_online_emit = self.peer_online_emitted.swap(0, Ordering::Relaxed);
        let peer_online_supp = self.peer_online_suppressed.swap(0, Ordering::Relaxed);
        let presence_emit = self.presence_emitted.swap(0, Ordering::Relaxed);
        let presence_supp = self.presence_suppressed.swap(0, Ordering::Relaxed);
        let rooms_emit = self.rooms_emitted.swap(0, Ordering::Relaxed);
        let rooms_supp = self.rooms_suppressed.swap(0, Ordering::Relaxed);
        let total = peer_online_emit
            + peer_online_supp
            + presence_emit
            + presence_supp
            + rooms_emit
            + rooms_supp;
        if total == 0 {
            return;
        }
        let poll_top = drain_top3(&self.rooms_poll_by_conn);
        let sent_conn_top = drain_top3(&self.rooms_sent_by_conn);
        let sent_target_top = drain_top3(&self.rooms_sent_by_target);
        info!(
            target: "firehose",
            peer_online_emitted = peer_online_emit,
            peer_online_suppressed = peer_online_supp,
            presence_emitted = presence_emit,
            presence_suppressed = presence_supp,
            rooms_emitted = rooms_emit,
            rooms_suppressed = rooms_supp,
            rooms_poll_top = %poll_top,
            rooms_sent_conn_top = %sent_conn_top,
            rooms_sent_target_top = %sent_target_top,
            "firehose 10s window"
        );
    }

    #[cfg(test)]
    pub fn snapshot(&self) -> [u64; 6] {
        [
            self.peer_online_emitted.load(Ordering::Relaxed),
            self.peer_online_suppressed.load(Ordering::Relaxed),
            self.presence_emitted.load(Ordering::Relaxed),
            self.presence_suppressed.load(Ordering::Relaxed),
            self.rooms_emitted.load(Ordering::Relaxed),
            self.rooms_suppressed.load(Ordering::Relaxed),
        ]
    }
}
