//! Plan 25 Wave A — Pi-to-Pi envelope forwarding via the relay.
//!
//! Pi-A sends a control frame:
//!
//! ```jsonc
//! { "type": "pi_envelope", "to_pc": "<Pi-B-pubkey-b64>", "envelope": { ... } }
//! ```
//!
//! The relay authenticates Pi-A via the existing challenge-response (so we
//! already trust `sender_peer_id` here), looks up the `mesh_versions` blob
//! that lists Pi-A and confirms Pi-B is in the same Owner's member list, then
//! forwards to Pi-B's live connections as:
//!
//! ```jsonc
//! { "type": "pi_envelope_in", "from_pc": "<Pi-A-pubkey>", "envelope": <verbatim> }
//! ```
//!
//! Issue #140 — WHICH connections of Pi-B get a unicast. One PC key can have
//! several connections, and the local broker behind each answers for its own
//! peers; with more than one broker on the PC, the first answer used to
//! settle a send. The relay reads the `peers_update` rosters it relays anyway
//! and remembers which local addresses a connection's broker owns. A unicast
//! `to = "<pc>:<address>"` then goes to the connections that advertise
//! `address`, and to all of them only when none does (no roster yet, a peer
//! that just moved). In memory only: rosters are never logged or persisted.
//!
//! Failures don't use a custom error frame — the relay synthesizes an envelope
//! with `body.type = "transport_error"` (per the plan's ACK protocol section),
//! correlated to the sender's original envelope via `re: <original_id>`.

use std::collections::{HashMap, HashSet};
#[cfg(test)]
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use axum::extract::ws::Message;
use rand::thread_rng;
use tokio::sync::Mutex as AsyncMutex;
use tracing::warn;

use crate::identity::canonical_ed25519_public_key;
use crate::mesh::{MeshStore, types::MeshHeader};
use crate::peers::registry::PeerRegistry;

/// Time-to-live for a positive membership lookup. The plan calls for 60 s.
const MAX_CACHE_TTL: Duration = Duration::from_secs(60);
const NEGATIVE_CACHE_TTL: Duration = Duration::from_secs(1);
const MAX_CACHE_ENTRIES: usize = 1024;

/// Hard cap on the serialized `envelope` embedded in a `pi_envelope` frame
/// (security fix 2026-08). Outer WS messages are already capped at 5 MiB by
/// the WS upgrade config, but that admits broker envelopes far larger than
/// any legitimate Pi↔Pi frame — this brings the control path in line with
/// the 4 MiB `ct` ceiling the outer-envelope path enforces.
pub const MAX_PI_ENVELOPE_BYTES: usize = 4 * 1024 * 1024;

/// Issue #140 — the receiver-local name of the endpoint brokers talk to each
/// other through (`<pc>:_broker_remote`). Control envelopes to it are never
/// narrowed to one connection.
const BROKER_REMOTE_ENDPOINT: &str = "_broker_remote";
/// Bounds on a roster the relay is willing to route by. They mirror the
/// extension's own wire limits (`MAX_PEERS_UPDATE_ENTRIES`, an address of at
/// most a cwd plus a name); a roster beyond them is ignored, which only
/// costs the fan-out.
const MAX_ROSTER_ENTRIES: usize = 1024;
const MAX_ROSTER_ADDRESS_BYTES: usize = 8192;

/// In-memory cache that maps `Pi-pubkey → authorization result`. Positive
/// entries retain one shared union of direct mesh siblings; negative entries
/// briefly coalesce repeated misses for senders absent from every Owner blob.
#[derive(Debug)]
pub struct MeshAuthCache {
    inner: Mutex<HashMap<String, CachedAuthorization>>,
    /// Global async gate: callers wait here instead of consuming a blocking
    /// worker while another cold-cache SQLite snapshot is in flight.
    refresh_snapshot_lock: AsyncMutex<()>,
    ttl: Duration,
    #[cfg(test)]
    refresh_jobs: AtomicUsize,
}

#[derive(Clone, Debug)]
enum AuthorizationResult {
    Positive(Arc<HashSet<String>>),
    Negative,
}

#[derive(Clone, Debug)]
struct CachedAuthorization {
    result: AuthorizationResult,
    cached_at: Instant,
}

impl MeshAuthCache {
    pub fn new() -> Self {
        Self::with_ttl(MAX_CACHE_TTL)
    }

    pub fn with_ttl(ttl: Duration) -> Self {
        Self {
            inner: Mutex::new(HashMap::new()),
            refresh_snapshot_lock: AsyncMutex::new(()),
            ttl: ttl.min(MAX_CACHE_TTL),
            #[cfg(test)]
            refresh_jobs: AtomicUsize::new(0),
        }
    }

    fn cache_guard(&self) -> MutexGuard<'_, HashMap<String, CachedAuthorization>> {
        match self.inner.lock() {
            Ok(guard) => guard,
            Err(poisoned) => {
                warn!("mesh authorization cache mutex poisoned; clearing cache");
                let mut guard = poisoned.into_inner();
                guard.clear();
                self.inner.clear_poison();
                guard
            }
        }
    }

    fn prune_expired(entries: &mut HashMap<String, CachedAuthorization>, ttl: Duration) {
        entries.retain(|_, entry| {
            let entry_ttl = match entry.result {
                AuthorizationResult::Positive(_) => ttl,
                AuthorizationResult::Negative => NEGATIVE_CACHE_TTL,
            };
            entry.cached_at.elapsed() < entry_ttl
        });
    }

    /// Drops every cached entry. Operational/test hook: the subscription
    /// re-validation sweep and `pi_envelope` forwarding observe mesh
    /// revocations only after the positive TTL expires; clearing forces the
    /// next lookup to hit the store.
    pub fn clear(&self) {
        let mut entries = self.cache_guard();
        entries.clear();
    }

    fn cached_result(&self, pi_pk: &str) -> Option<AuthorizationResult> {
        let mut entries = self.cache_guard();
        Self::prune_expired(&mut entries, self.ttl);
        entries.get(pi_pk).map(|entry| entry.result.clone())
    }

    fn insert_result(&self, pi_pk: String, result: AuthorizationResult) {
        let mut entries = self.cache_guard();
        Self::prune_expired(&mut entries, self.ttl);
        if !entries.contains_key(&pi_pk) && entries.len() >= MAX_CACHE_ENTRIES {
            let oldest_key = entries
                .iter()
                .min_by(|(left_key, left), (right_key, right)| {
                    left.cached_at
                        .cmp(&right.cached_at)
                        .then_with(|| left_key.cmp(right_key))
                })
                .map(|(key, _)| key.clone());
            if let Some(oldest_key) = oldest_key {
                entries.remove(&oldest_key);
            }
        }
        entries.insert(
            pi_pk,
            CachedAuthorization {
                result,
                cached_at: Instant::now(),
            },
        );
    }

    fn cached_authorization(result: AuthorizationResult, target: &str) -> bool {
        match result {
            AuthorizationResult::Positive(members) => members.contains(target),
            AuthorizationResult::Negative => false,
        }
    }

    fn refresh_authorization(&self, pi_pk: &str, target: &str, store: &MeshStore) -> bool {
        let blobs = match store.all_blobs() {
            Ok(blobs) => blobs,
            Err(error) => {
                warn!(error = %error, "mesh store read failed during authorization refresh");
                return false;
            }
        };
        match direct_members_from_blobs(pi_pk, &blobs) {
            Some(members) => {
                let members = Arc::new(members);
                let authorized = members.contains(target);
                self.insert_result(pi_pk.to_owned(), AuthorizationResult::Positive(members));
                authorized
            }
            None => {
                self.insert_result(pi_pk.to_owned(), AuthorizationResult::Negative);
                false
            }
        }
    }

    /// `true` iff both Pis belong to the same direct Owner membership.
    pub async fn is_authorized(
        self: &Arc<Self>,
        pi_a: &str,
        pi_b: &str,
        store: Arc<MeshStore>,
    ) -> bool {
        let (Ok(a), Ok(b)) = (
            canonical_ed25519_public_key(pi_a),
            canonical_ed25519_public_key(pi_b),
        ) else {
            return false;
        };
        self.is_authorized_canonical(&a, &b, store).await
    }

    async fn is_authorized_canonical(
        self: &Arc<Self>,
        pi_a: &str,
        pi_b: &str,
        store: Arc<MeshStore>,
    ) -> bool {
        if let Some(result) = self.cached_result(pi_a) {
            return Self::cached_authorization(result, pi_b);
        }

        // Serialize cold refreshes before creating a blocking task. A caller
        // that queued behind the gate sees the entry created by its predecessor
        // and returns without occupying Tokio's blocking pool.
        let _refresh_guard = self.refresh_snapshot_lock.lock().await;
        if let Some(result) = self.cached_result(pi_a) {
            return Self::cached_authorization(result, pi_b);
        }

        let cache = Arc::clone(self);
        let sender = pi_a.to_owned();
        let target = pi_b.to_owned();
        #[cfg(test)]
        self.refresh_jobs
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        match tokio::task::spawn_blocking(move || {
            cache.refresh_authorization(&sender, &target, store.as_ref())
        })
        .await
        {
            Ok(authorized) => authorized,
            Err(error) => {
                warn!(error = %error, "mesh authorization refresh task failed");
                false
            }
        }
    }
}

impl Default for MeshAuthCache {
    fn default() -> Self {
        Self::new()
    }
}

fn direct_members_from_blobs(pi_pk: &str, blobs: &[Vec<u8>]) -> Option<HashSet<String>> {
    let mut union = HashSet::new();
    for blob in blobs {
        let header: MeshHeader = match serde_json::from_slice(blob) {
            Ok(header) => header,
            Err(_) => continue,
        };
        let mut owner_members: Result<HashSet<String>, _> = header
            .members
            .iter()
            .map(|member| canonical_ed25519_public_key(&member.remote_epk))
            .collect();
        // Regression fix (2026-08-16): the mesh blob lists only the PIS as
        // `members`; the phone app is the `owner_pk`, NOT a member. Without
        // treating the owner as part of the set, the app's presence/rooms
        // queries about its own Pis were gated OUT (empty Home/Projects on
        // the phone) — the exact traffic this authorization must allow.
        if let Ok(mut set) = owner_members {
            if let Ok(owner_pk) = canonical_ed25519_public_key(&header.owner_pk) {
                set.insert(owner_pk);
            }
            owner_members = Ok(set);
        }
        let Ok(owner_members) = owner_members else {
            continue;
        };
        if owner_members.contains(pi_pk) {
            union.extend(owner_members);
        }
    }
    (!union.is_empty()).then_some(union)
}

/// What the routing loop should do after calling `handle_pi_envelope`.
pub enum PiForwardResult {
    /// Envelope delivered (or accepted by the channel of) Pi-B.
    Forwarded,
    /// Send this message back to the original sender via their own WS sink.
    /// Always a `pi_envelope_in` whose envelope carries
    /// `body.type = "transport_error"`.
    TransportError(Message),
}

#[derive(Clone, Copy)]
enum TransportErrorReason {
    Offline,
    NotAuthorized,
    BadEnvelope,
    TooLarge,
}

impl TransportErrorReason {
    fn as_str(self) -> &'static str {
        match self {
            Self::Offline => "offline",
            Self::NotAuthorized => "not_authorized",
            Self::BadEnvelope => "bad_envelope",
            Self::TooLarge => "too_large",
        }
    }
}

/// Handles one `pi_envelope` frame. `sender_peer_id` is the authenticated
/// Pi-A pubkey (already verified by the WS handshake) and `sender_conn_id`
/// the connection it arrived on, which is where a `peers_update` roster is
/// attributed to (issue #140).
pub async fn handle_pi_envelope(
    sender_peer_id: &str,
    sender_conn_id: u64,
    frame: &serde_json::Value,
    registry: &PeerRegistry,
    mesh: Arc<MeshStore>,
    cache: Arc<MeshAuthCache>,
) -> PiForwardResult {
    let to_pc = frame.get("to_pc").and_then(|v| v.as_str());
    let envelope = frame.get("envelope");

    let (to_pc, envelope) = match (to_pc, envelope) {
        (Some(t), Some(e)) if e.is_object() && !t.is_empty() => (t, e),
        _ => {
            return PiForwardResult::TransportError(make_transport_error(
                frame.get("envelope"),
                TransportErrorReason::BadEnvelope,
            ));
        }
    };

    // Size cap (security fix 2026-08): the embedded envelope used to bypass
    // the 4 MiB `ct` ceiling that outer envelopes enforce. Serialize once to
    // measure; the input is already bounded by the WS message cap.
    match serde_json::to_string(envelope) {
        Ok(serialized) if serialized.len() > MAX_PI_ENVELOPE_BYTES => {
            return PiForwardResult::TransportError(make_transport_error(
                Some(envelope),
                TransportErrorReason::TooLarge,
            ));
        }
        Err(_) => {
            return PiForwardResult::TransportError(make_transport_error(
                Some(envelope),
                TransportErrorReason::BadEnvelope,
            ));
        }
        Ok(_) => {}
    }

    let sender = match canonical_ed25519_public_key(sender_peer_id) {
        Ok(value) => value,
        Err(_) => {
            return PiForwardResult::TransportError(make_transport_error(
                frame.get("envelope"),
                TransportErrorReason::BadEnvelope,
            ));
        }
    };
    let target = match canonical_ed25519_public_key(to_pc) {
        Ok(value) => value,
        Err(_) => {
            return PiForwardResult::TransportError(make_transport_error(
                Some(envelope),
                TransportErrorReason::BadEnvelope,
            ));
        }
    };

    if !cache.is_authorized_canonical(&sender, &target, mesh).await {
        return PiForwardResult::TransportError(make_transport_error(
            Some(envelope),
            TransportErrorReason::NotAuthorized,
        ));
    }

    let outbound = serde_json::json!({
        "type": "pi_envelope_in",
        "from_pc": sender,
        "envelope": envelope, // verbatim
    });
    let msg = Message::Text(outbound.to_string());

    // Past authorization, so only a peer the Owner paired can shape routing.
    if let Some(roster) = parse_peers_update(envelope) {
        registry.set_pi_roster(sender_conn_id, roster);
    }
    match registry.forward_pi_envelope(&target, msg, unicast_local_address(envelope).as_deref()) {
        Some(route) => {
            // Counts only: an address is envelope content and is not logged.
            tracing::debug!(?route, "pi_envelope forwarded");
            PiForwardResult::Forwarded
        }
        None => PiForwardResult::TransportError(make_transport_error(
            Some(envelope),
            TransportErrorReason::Offline,
        )),
    }
}

/// The local peer addresses a `peers_update` control envelope advertises
/// (issue #140), or None when the envelope is no such frame, is malformed, or
/// exceeds the bounds. The relay then keeps what it knew about the connection.
fn parse_peers_update(envelope: &serde_json::Value) -> Option<HashSet<String>> {
    let endpoint = format!(":{BROKER_REMOTE_ENDPOINT}");
    for field in ["from", "to"] {
        if !envelope.get(field)?.as_str()?.ends_with(&endpoint) {
            return None;
        }
    }
    let body = envelope.get("body")?;
    if body.get("type")?.as_str()? != "peers_update" {
        return None;
    }
    let peers = body.get("peers")?.as_array()?;
    let addresses: Vec<&str> = match body.get("peers_detailed") {
        Some(serde_json::Value::Array(detailed)) => detailed
            .iter()
            .map(|entry| entry.get("address")?.as_str())
            .collect::<Option<Vec<_>>>()?,
        _ => peers
            .iter()
            .map(serde_json::Value::as_str)
            .collect::<Option<Vec<_>>>()?,
    };
    if addresses.len() > MAX_ROSTER_ENTRIES
        || addresses
            .iter()
            .any(|address| address.is_empty() || address.len() > MAX_ROSTER_ADDRESS_BYTES)
    {
        return None;
    }
    Some(
        addresses
            .iter()
            .map(|address| (*address).to_owned())
            .collect(),
    )
}

/// The local address a unicast envelope is addressed to (`to = "<pc>:<address>"`),
/// or None for a frame that is no such unicast: a control envelope to
/// `_broker_remote`, `broadcast`, or an address without a PC prefix. The
/// split is on the first colon, as in the extension's `parseAddress`.
fn unicast_local_address(envelope: &serde_json::Value) -> Option<String> {
    let (pc, address) = envelope.get("to")?.as_str()?.split_once(':')?;
    if pc.is_empty()
        || address.is_empty()
        || address == "broadcast"
        || address == BROKER_REMOTE_ENDPOINT
    {
        return None;
    }
    Some(address.to_owned())
}

fn is_uuid(value: &str) -> bool {
    value.len() == 36
        && value.as_bytes().iter().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                *byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

fn new_uuid_v4() -> String {
    use rand::RngCore;

    let mut bytes = [0_u8; 16];
    thread_rng().fill_bytes(&mut bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15],
    )
}

/// Builds a `pi_envelope_in` frame whose inner envelope carries
/// `body.type = "transport_error"`, correlated to the original via `re`.
fn make_transport_error(
    envelope: Option<&serde_json::Value>,
    reason: TransportErrorReason,
) -> Message {
    let re = envelope
        .and_then(|value| value.get("id"))
        .and_then(serde_json::Value::as_str)
        .filter(|value| is_uuid(value))
        .map(str::to_owned);
    let to_addr = envelope
        .and_then(|value| value.get("from"))
        .and_then(serde_json::Value::as_str)
        .filter(|address| !address.is_empty())
        .unwrap_or("_unknown");

    let err_envelope = serde_json::json!({
        "from": "_relay",
        "to": to_addr,
        "id": new_uuid_v4(),
        "re": re,
        "body": { "type": "transport_error", "reason": reason.as_str() },
    });

    let frame = serde_json::json!({
        "type": "pi_envelope_in",
        "from_pc": "_relay",
        "envelope": err_envelope,
    });
    Message::Text(frame.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{PresenceManager, RoomManager};
    use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
    use std::sync::Arc;

    fn fresh_cache_and_store() -> (Arc<MeshAuthCache>, Arc<MeshStore>) {
        (
            Arc::new(MeshAuthCache::new()),
            Arc::new(MeshStore::open_in_memory().unwrap()),
        )
    }

    fn pi_key(byte: u8) -> String {
        use base64::{Engine as _, engine::general_purpose::STANDARD};
        STANDARD.encode([byte; 32])
    }

    fn pi_key_url_safe(byte: u8) -> String {
        URL_SAFE_NO_PAD.encode([byte; 32])
    }

    fn owner_blob(owner_pk: &[u8], members: &[&str], version: u64) -> Vec<u8> {
        let pk_b64 = {
            use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
            B64.encode(owner_pk)
        };
        let members_json: Vec<serde_json::Value> = members
            .iter()
            .map(|member| {
                serde_json::json!({
                    "remote_epk": member,
                    "relay_url": "wss://relay.example.test",
                    "paired_at": "2025-01-01T00:00:00.000Z",
                })
            })
            .collect();
        serde_json::to_vec(&serde_json::json!({
            "owner_pk": pk_b64,
            "version": version,
            "issued_at": 1_700_000_000_000_u64,
            "members": members_json,
        }))
        .unwrap()
    }

    fn write_owner_blob(store: &MeshStore, owner_pk: &[u8], members: &[&str], version: u64) {
        use sha2::{Digest, Sha256};
        let blob_bytes = owner_blob(owner_pk, members, version);
        let hash = Sha256::digest(owner_pk)
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        store
            .upsert(&hash, owner_pk, version, &blob_bytes, &[0u8; 64], 0)
            .unwrap();
    }

    #[test]
    fn multi_owner_union_ignores_sender_only_owner_inserted_first() {
        let pi_a = pi_key(0x0a);
        let pi_b = pi_key(0x0b);
        let owner1 = pi_key(0x01);
        let owner2 = pi_key(0x02);
        let blobs = vec![
            owner_blob(&[1; 32], &[&pi_a], 1),
            owner_blob(&[2; 32], &[&pi_a, &pi_b], 1),
        ];

        // Regression fix (2026-08-16): each blob's owner_pk is part of its
        // mesh set — a phone (owner) shares the mesh with its Pis, so both
        // owners appear in the union alongside the Pi members.
        assert_eq!(
            direct_members_from_blobs(&pi_a, &blobs),
            Some(HashSet::from([pi_a, pi_b, owner1, owner2])),
        );
    }

    #[test]
    fn multi_owner_union_is_order_independent_and_direct() {
        let pi_a = pi_key(0x0a);
        let pi_b = pi_key(0x0b);
        let pi_c = pi_key(0x0c);
        let owner_ab = owner_blob(&[1; 32], &[&pi_a, &pi_b], 1);
        let owner_ac = owner_blob(&[2; 32], &[&pi_a, &pi_c], 1);
        for blobs in [
            &vec![owner_ab.clone(), owner_ac.clone()],
            &vec![owner_ac, owner_ab],
        ] {
            let members_a = direct_members_from_blobs(&pi_a, blobs).unwrap();
            let members_b = direct_members_from_blobs(&pi_b, blobs).unwrap();
            let members_c = direct_members_from_blobs(&pi_c, blobs).unwrap();
            assert!(members_a.contains(&pi_b) && members_a.contains(&pi_c));
            assert!(!members_b.contains(&pi_c) && !members_c.contains(&pi_b));
        }
    }

    #[tokio::test]
    async fn authorization_is_direct_not_transitive() {
        let (cache, store) = fresh_cache_and_store();
        let a = pi_key(0x0a);
        let b = pi_key(0x0b);
        let c = pi_key(0x0c);
        write_owner_blob(&store, &[1; 32], &[&a, &b], 1);
        write_owner_blob(&store, &[2; 32], &[&b, &c], 1);

        assert!(cache.is_authorized(&a, &b, store.clone()).await);
        assert!(cache.is_authorized(&b, &a, store.clone()).await);
        assert!(cache.is_authorized(&b, &c, store.clone()).await);
        assert!(cache.is_authorized(&c, &b, store.clone()).await);
        assert!(!cache.is_authorized(&a, &c, store.clone()).await);
        assert!(!cache.is_authorized(&c, &a, store).await);
    }

    #[tokio::test]
    async fn canonical_variants_share_positive_cache_state() {
        let (cache, store) = fresh_cache_and_store();
        let a = pi_key(0xfb);
        let b = pi_key(0xef);
        let a_url_safe = pi_key_url_safe(0xfb);
        let b_url_safe = pi_key_url_safe(0xef);
        let owner = [3_u8; 32];
        write_owner_blob(&store, &owner, &[&a_url_safe, &b_url_safe], 1);

        assert!(
            cache
                .is_authorized(&a_url_safe, &b_url_safe, store.clone())
                .await
        );
        write_owner_blob(&store, &owner, &[&a_url_safe], 2);
        assert!(cache.is_authorized(&a, &b, store).await);
    }

    #[tokio::test]
    async fn zero_ttl_observes_membership_revocation_on_next_lookup() {
        let cache = Arc::new(MeshAuthCache::with_ttl(Duration::ZERO));
        let store = Arc::new(MeshStore::open_in_memory().unwrap());
        let a = pi_key(0x0a);
        let b = pi_key(0x0b);
        let owner = [4_u8; 32];
        write_owner_blob(&store, &owner, &[&a, &b], 1);
        assert!(cache.is_authorized(&a, &b, store.clone()).await);

        write_owner_blob(&store, &owner, &[&a], 2);
        assert!(!cache.is_authorized(&a, &b, store).await);
    }

    #[tokio::test]
    async fn positive_cache_survives_immediate_revoke_before_expiry() {
        let (cache, store) = fresh_cache_and_store();
        let sender = pi_key(0x0a);
        let target = pi_key(0x0b);
        let owner = [5; 32];
        write_owner_blob(&store, &owner, &[&sender, &target], 1);
        assert!(cache.is_authorized(&sender, &target, store.clone()).await);
        write_owner_blob(&store, &owner, &[&sender], 2);
        assert!(cache.is_authorized(&sender, &target, store).await);
    }

    #[tokio::test]
    async fn fresh_positive_entry_reuses_union_for_random_target_misses() {
        let (cache, store) = fresh_cache_and_store();
        let sender = pi_key(0x0a);
        let member = pi_key(0x0b);
        write_owner_blob(&store, &[5; 32], &[&sender, &member], 1);

        assert!(cache.is_authorized(&sender, &member, store.clone()).await);
        assert!(
            !cache
                .is_authorized(&sender, &pi_key(0x0c), store.clone())
                .await
        );
        assert!(
            !cache
                .is_authorized(&sender, &pi_key(0x0d), store.clone())
                .await
        );
        assert_eq!(store.all_blobs_calls(), 1);
    }

    #[tokio::test]
    async fn negative_entry_coalesces_repeated_unknown_sender_misses() {
        let (cache, store) = fresh_cache_and_store();
        let sender = pi_key(0x0a);
        assert!(
            !cache
                .is_authorized(&sender, &pi_key(0x0b), store.clone())
                .await
        );
        assert!(
            !cache
                .is_authorized(&sender, &pi_key(0x0c), store.clone())
                .await
        );
        assert_eq!(store.all_blobs_calls(), 1);
    }

    #[tokio::test]
    async fn positive_expiry_refreshes_authorization() {
        let cache = Arc::new(MeshAuthCache::with_ttl(Duration::from_millis(5)));
        let store = Arc::new(MeshStore::open_in_memory().unwrap());
        let sender = pi_key(0x0a);
        let target = pi_key(0x0b);
        write_owner_blob(&store, &[6; 32], &[&sender, &target], 1);
        assert!(cache.is_authorized(&sender, &target, store.clone()).await);
        tokio::time::sleep(Duration::from_millis(10)).await;
        assert!(cache.is_authorized(&sender, &target, store.clone()).await);
        assert_eq!(store.all_blobs_calls(), 2);
    }

    #[tokio::test]
    async fn negative_expiry_refreshes_authorization() {
        let (cache, store) = fresh_cache_and_store();
        let sender = pi_key(0x0a);
        assert!(
            !cache
                .is_authorized(&sender, &pi_key(0x0b), store.clone())
                .await
        );
        {
            let mut entries = cache.cache_guard();
            entries.get_mut(&sender).unwrap().cached_at = Instant::now()
                .checked_sub(NEGATIVE_CACHE_TTL + Duration::from_millis(1))
                .unwrap();
        }
        assert!(
            !cache
                .is_authorized(&sender, &pi_key(0x0c), store.clone())
                .await
        );
        assert_eq!(store.all_blobs_calls(), 2);
    }

    #[test]
    fn cache_is_bounded_and_evicts_oldest_sender() {
        let cache = MeshAuthCache::new();
        cache.insert_result("sender-0000".to_owned(), AuthorizationResult::Negative);
        std::thread::sleep(Duration::from_millis(1));
        for index in 1..=MAX_CACHE_ENTRIES {
            cache.insert_result(format!("sender-{index:04}"), AuthorizationResult::Negative);
        }
        let entries = cache.cache_guard();
        assert_eq!(entries.len(), MAX_CACHE_ENTRIES);
        assert!(!entries.contains_key("sender-0000"));
        assert!(entries.contains_key("sender-1024"));
    }

    #[tokio::test]
    async fn concurrent_cold_requests_coalesce_to_one_store_scan() {
        let (cache, store) = fresh_cache_and_store();
        let sender = pi_key(0x0a);
        let target = pi_key(0x0b);
        write_owner_blob(&store, &[8; 32], &[&sender, &target], 1);
        let (a, b, c, d) = tokio::join!(
            cache.is_authorized(&sender, &target, store.clone()),
            cache.is_authorized(&sender, &target, store.clone()),
            cache.is_authorized(&sender, &target, store.clone()),
            cache.is_authorized(&sender, &target, store.clone()),
        );
        assert!(a && b && c && d);
        assert_eq!(store.all_blobs_calls(), 1);
        assert_eq!(cache.refresh_jobs.load(Ordering::Relaxed), 1);
    }

    #[tokio::test]
    async fn poisoned_cache_clears_and_recovers_without_panicking() {
        let (cache, store) = fresh_cache_and_store();
        let sender = pi_key(0x0a);
        let target = pi_key(0x0b);
        write_owner_blob(&store, &[9; 32], &[&sender, &target], 1);
        assert!(cache.is_authorized(&sender, &target, store.clone()).await);
        let poisoned_cache = cache.clone();
        assert!(
            std::thread::spawn(move || {
                let _guard = poisoned_cache.inner.lock().unwrap();
                panic!("poison cache");
            })
            .join()
            .is_err()
        );
        assert!(cache.is_authorized(&sender, &target, store.clone()).await);
        assert!(!cache.inner.is_poisoned());
        // The repaired cache reuses the refreshed entry instead of scanning
        // SQLite again after the recovered lock is released.
        assert!(cache.is_authorized(&sender, &target, store.clone()).await);
        assert_eq!(store.all_blobs_calls(), 2);
        assert_eq!(cache.refresh_jobs.load(Ordering::Relaxed), 2);
    }

    #[test]
    fn configured_positive_ttl_is_capped_at_sixty_seconds() {
        let cache = MeshAuthCache::with_ttl(Duration::from_secs(600));
        assert_eq!(cache.ttl, MAX_CACHE_TTL);
    }

    #[tokio::test]
    async fn bad_envelope_when_missing_to_pc() {
        let registry = Arc::new(PeerRegistry::new(
            Arc::new(PresenceManager::new()),
            Arc::new(RoomManager::new()),
            Arc::new(crate::metrics::FirehoseMetrics::new()),
        ));
        let store = Arc::new(MeshStore::open_in_memory().unwrap());
        let cache = Arc::new(MeshAuthCache::new());
        let frame = serde_json::json!({
            "type": "pi_envelope",
            "envelope": {
                "from": "x",
                "to": "y",
                "id": "30000000-0000-4000-8000-000000000003",
                "re": null,
                "body": {},
            },
        });
        match handle_pi_envelope(&pi_key(0x0a), u64::MAX, &frame, &registry, store, cache).await {
            PiForwardResult::TransportError(_) => {}
            PiForwardResult::Forwarded => panic!("must be transport_error"),
        }
    }

    #[tokio::test]
    async fn oversized_envelope_is_rejected_before_forwarding() {
        let registry = Arc::new(PeerRegistry::new(
            Arc::new(PresenceManager::new()),
            Arc::new(RoomManager::new()),
            Arc::new(crate::metrics::FirehoseMetrics::new()),
        ));
        let store = Arc::new(MeshStore::open_in_memory().unwrap());
        let cache = Arc::new(MeshAuthCache::new());
        let big_body = "x".repeat(MAX_PI_ENVELOPE_BYTES + 1024);
        let frame = serde_json::json!({
            "type": "pi_envelope",
            "to_pc": pi_key(0x0b),
            "envelope": {
                "from": "x",
                "to": "y",
                "id": "30000000-0000-4000-8000-000000000004",
                "re": null,
                "body": { "blob": big_body },
            },
        });
        match handle_pi_envelope(&pi_key(0x0a), u64::MAX, &frame, &registry, store, cache).await {
            PiForwardResult::TransportError(_) => {}
            PiForwardResult::Forwarded => panic!("must be transport_error"),
        }
    }

    // ── issue #140: routing by roster ──────────────────────────────────────

    fn roster_frame(
        peers: serde_json::Value,
        detailed: Option<serde_json::Value>,
    ) -> serde_json::Value {
        let mut body = serde_json::json!({ "type": "peers_update", "peers": peers });
        if let Some(detailed) = detailed {
            body["peers_detailed"] = detailed;
        }
        serde_json::json!({
            "from": "pc-b:_broker_remote",
            "to": "pc-a:_broker_remote",
            "id": "30000000-0000-4000-8000-000000000010",
            "re": null,
            "body": body,
        })
    }

    fn address_set(values: &[&str]) -> HashSet<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    fn test_room_meta() -> crate::rooms::RoomMeta {
        crate::rooms::RoomMeta {
            room_id: "main".to_owned(),
            name: None,
            cwd: None,
            model: None,
            provider: None,
            thinking: None,
            working: false,
            waiting_for_input: false,
            provider_error: false,
            git: None,
            keeper: None,
            context_usage: None,
            plan_usage: None,
            gh_ref: None,
            gh_suggestion: None,
            stats: None,
            started_at: 0,
        }
    }

    #[test]
    fn peers_update_roster_is_read_from_detailed_addresses_or_the_flat_list() {
        let detailed = serde_json::json!([
            { "cwd": "/demo", "name": "demo", "address": "/demo@demo" },
            { "cwd": "C:\\work", "name": "api", "address": "C:\\work@api" },
        ]);
        assert_eq!(
            parse_peers_update(&roster_frame(
                serde_json::json!(["/demo@demo", "C:\\work@api"]),
                Some(detailed),
            )),
            Some(address_set(&["/demo@demo", "C:\\work@api"])),
        );
        assert_eq!(
            parse_peers_update(&roster_frame(serde_json::json!(["/demo@demo"]), None)),
            Some(address_set(&["/demo@demo"])),
        );
        // An empty roster is a statement too: this broker owns nobody.
        assert_eq!(
            parse_peers_update(&roster_frame(serde_json::json!([]), None)),
            Some(HashSet::new()),
        );
    }

    #[test]
    fn peers_update_outside_bounds_or_shape_is_ignored() {
        let too_many = serde_json::json!(vec!["/p@p"; MAX_ROSTER_ENTRIES + 1]);
        assert_eq!(parse_peers_update(&roster_frame(too_many, None)), None);

        let long = format!("/{}@p", "x".repeat(MAX_ROSTER_ADDRESS_BYTES));
        assert_eq!(
            parse_peers_update(&roster_frame(serde_json::json!([long]), None)),
            None,
        );

        for body in [
            serde_json::json!({ "type": "peers_request" }),
            serde_json::json!({ "type": "peers_update" }),
            serde_json::json!({ "type": "peers_update", "peers": "nope" }),
            serde_json::json!({ "type": "peers_update", "peers": [42] }),
            serde_json::json!({ "type": "peers_update", "peers": ["/p@p"], "peers_detailed": [{ "address": 7 }] }),
            serde_json::json!({ "type": "peers_update", "peers": [""] }),
        ] {
            let mut frame = roster_frame(serde_json::json!([]), None);
            frame["body"] = body.clone();
            assert_eq!(parse_peers_update(&frame), None, "{body}");
        }

        // Not the broker-to-broker endpoint on either side.
        let mut frame = roster_frame(serde_json::json!(["/p@p"]), None);
        frame["to"] = serde_json::json!("pc-a:/demo@demo");
        assert_eq!(parse_peers_update(&frame), None);
        let mut frame = roster_frame(serde_json::json!(["/p@p"]), None);
        frame["from"] = serde_json::json!("pc-b:/demo@demo");
        assert_eq!(parse_peers_update(&frame), None);
    }

    #[test]
    fn unicast_local_address_splits_on_the_first_colon_and_skips_control_targets() {
        let to = |value: &str| serde_json::json!({ "to": value });
        assert_eq!(
            unicast_local_address(&to("pc-b:/demo@demo")),
            Some("/demo@demo".to_owned()),
        );
        // A Windows cwd keeps its drive-letter colon.
        assert_eq!(
            unicast_local_address(&to("pc-b:C:\\work@api")),
            Some("C:\\work@api".to_owned()),
        );
        for value in [
            "broadcast",
            "pc-b:broadcast",
            "pc-b:_broker_remote",
            "_broker_remote",
            "/local@agent",
            ":/local@agent",
            "pc-b:",
            "",
        ] {
            assert_eq!(unicast_local_address(&to(value)), None, "{value}");
        }
        assert_eq!(unicast_local_address(&serde_json::json!({ "to": 7 })), None);
    }

    #[tokio::test]
    async fn peers_update_is_attributed_to_the_connection_it_came_from() {
        let registry = PeerRegistry::new(
            Arc::new(PresenceManager::new()),
            Arc::new(RoomManager::new()),
            Arc::new(crate::metrics::FirehoseMetrics::new()),
        );
        let store = Arc::new(MeshStore::open_in_memory().unwrap());
        let cache = Arc::new(MeshAuthCache::new());
        write_owner_blob(&store, &[7; 32], &[&pi_key(0x0b), &pi_key(0x0a)], 1);
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let conn = registry.register(pi_key(0x0b), test_room_meta(), tx).await;

        let frame = serde_json::json!({
            "type": "pi_envelope",
            "to_pc": pi_key(0x0a),
            "envelope": roster_frame(serde_json::json!(["/demo@demo"]), None),
        });
        let result = handle_pi_envelope(&pi_key(0x0b), conn, &frame, &registry, store, cache).await;
        // Pi-A is offline here; the roster is recorded all the same.
        assert!(matches!(result, PiForwardResult::TransportError(_)));
        assert_eq!(
            registry.pi_roster(conn),
            Some(Arc::new(address_set(&["/demo@demo"])))
        );
        assert_eq!(registry.pi_roster(conn + 1), None);
    }
}
