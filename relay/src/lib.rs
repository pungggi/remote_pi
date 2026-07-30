pub mod auth;
pub mod handlers;
mod identity;
pub mod lan;
pub mod mesh;
pub mod metrics;
pub mod peers;
pub mod presence;
pub mod protocol;
pub mod rooms;

use std::sync::Arc;
use std::time::Duration;

use axum::{
    Router,
    extract::{DefaultBodyLimit, FromRef},
    routing::get,
};

pub use handlers::pi_forward::MeshAuthCache;
pub use mesh::MeshStore;
pub use metrics::FirehoseMetrics;
pub use peers::registry::PeerRegistry;
pub use presence::PresenceManager;
pub use rooms::{RoomManager, RoomMeta, RoomMetaPatch};

/// Shared state injected into every axum handler.
///
/// The relay serves WebSocket upgrades (`GET /`), health checks (`GET /health`),
/// and mesh membership endpoints (`GET/POST /mesh/:hash`) on a single port —
/// they all read from this struct.
#[derive(Clone)]
pub struct AppState {
    pub registry: Arc<PeerRegistry>,
    pub presence: Arc<PresenceManager>,
    pub rooms: Arc<RoomManager>,
    pub mesh: Arc<MeshStore>,
    /// Plan 25 — caches `Pi-pubkey → mesh siblings` to avoid hitting SQLite
    /// for every `pi_envelope` forward (60 s TTL).
    pub mesh_auth: Arc<MeshAuthCache>,
    /// In-process counters for emit/suppress accounting (firehose dedup).
    /// A background task drains and logs them every 10 s.
    pub metrics: Arc<FirehoseMetrics>,
    /// Plan 115 — the TCP port the relay is bound to, used to build the
    /// `http://ip:port` LAN candidates advertised in the `challenge` frame.
    /// (The bind address itself is `0.0.0.0`; the port is what the phone
    /// needs to dial.)
    pub port: u16,
    /// Plan 125 — interval between WS keepalive Pings sent to each peer
    /// (default 60 s, configurable at startup via `REMOTEPI_HEARTBEAT_SECS`,
    /// min 30). The relay is the heartbeat authority: this inbound cadence is
    /// what keeps NAT mappings alive on mobile clients, so it is the floor on
    /// how often a phone's radio must wake. 60 s beats every common NAT idle
    /// timeout with margin and halves inbound wakeups vs. the old 25 s.
    pub heartbeat_interval: Duration,
}

/// Plan 125 — default WS keepalive cadence (seconds). The relay pings each
/// peer at this interval; it is the floor on how often a mobile client's radio
/// must wake, so it directly drives phone battery. 60 s beats every common NAT
/// idle timeout (consumer routers ≥ 60 s, Cloudflare WSS ~100 s, corporate LBs
/// 2–5 min) with margin and halves inbound wakeups vs. the old 25 s.
pub const DEFAULT_HEARTBEAT_SECS: u64 = 60;

/// Plan 125 — NAT-safe floor for the heartbeat. Anything tighter forfeits the
/// battery win and risks NAT drops on aggressive networks.
pub const MIN_HEARTBEAT_SECS: u64 = 30;

/// Plan 125 — resolve the heartbeat interval from an optional env-string value
/// (`REMOTEPI_HEARTBEAT_SECS`). `None`/unparseable → [DEFAULT_HEARTBEAT_SECS];
/// values below [MIN_HEARTBEAT_SECS] are clamped up with a `warn` log. Pure so
/// the clamp contract is pinned by a unit test (no flaky long-running WS test).
pub fn resolve_heartbeat_secs(raw: Option<&str>) -> u64 {
    match raw.and_then(|s| s.trim().parse::<u64>().ok()) {
        Some(v) if v < MIN_HEARTBEAT_SECS => {
            tracing::warn!(
                requested = v,
                min = MIN_HEARTBEAT_SECS,
                "REMOTEPI_HEARTBEAT_SECS below NAT-safe floor; clamping"
            );
            MIN_HEARTBEAT_SECS
        }
        Some(v) => v,
        None => DEFAULT_HEARTBEAT_SECS,
    }
}

// Allows mesh handlers to keep using `State<Arc<MeshStore>>` instead of
// reaching into the full `AppState`.
impl FromRef<AppState> for Arc<MeshStore> {
    fn from_ref(state: &AppState) -> Self {
        state.mesh.clone()
    }
}

/// Builds the unified axum router: WebSocket upgrade + HTTP API.
///
/// Mount it with `axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>())`
/// — the WS handler extracts `ConnectInfo<SocketAddr>` for log spans.
pub fn build_router(state: AppState) -> Router {
    Router::new()
        .route("/", get(handlers::peer::ws_handler))
        .route("/health", get(|| async { "OK" }))
        .route(
            "/mesh/:owner_pk_hash",
            get(mesh::handler::get_mesh).post(mesh::handler::post_mesh),
        )
        .layer(DefaultBodyLimit::max(mesh::handler::MAX_BODY_BYTES))
        .with_state(state)
}

#[cfg(test)]
mod heartbeat_tests {
    use super::*;

    #[test]
    fn unset_uses_default() {
        assert_eq!(resolve_heartbeat_secs(None), DEFAULT_HEARTBEAT_SECS);
    }

    #[test]
    fn unparseable_uses_default() {
        assert_eq!(resolve_heartbeat_secs(Some("nope")), DEFAULT_HEARTBEAT_SECS);
        assert_eq!(resolve_heartbeat_secs(Some("")), DEFAULT_HEARTBEAT_SECS);
        assert_eq!(resolve_heartbeat_secs(Some("   ")), DEFAULT_HEARTBEAT_SECS);
        assert_eq!(resolve_heartbeat_secs(Some("-5")), DEFAULT_HEARTBEAT_SECS);
    }

    #[test]
    fn explicit_value_passes_through() {
        assert_eq!(resolve_heartbeat_secs(Some("90")), 90);
        assert_eq!(resolve_heartbeat_secs(Some("  45 ")), 45);
        assert_eq!(resolve_heartbeat_secs(Some("120")), 120);
    }

    #[test]
    fn below_floor_is_clamped() {
        assert_eq!(resolve_heartbeat_secs(Some("1")), MIN_HEARTBEAT_SECS);
        assert_eq!(resolve_heartbeat_secs(Some("29")), MIN_HEARTBEAT_SECS);
    }

    #[test]
    fn at_floor_is_allowed() {
        assert_eq!(resolve_heartbeat_secs(Some("30")), MIN_HEARTBEAT_SECS);
    }
}
