use std::net::SocketAddr;
use std::sync::Arc;

use anyhow::Context;
use tokio::net::TcpListener;
use tracing::info;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt::init();

    let port: u16 = std::env::var("REMOTEPI_RELAY_PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(3000);

    // Plan 125 — WS keepalive heartbeat interval (default 60 s, env-configurable,
    // NAT-safe floor 30 s). The resolve/clamp logic is a pure, unit-tested fn in
    // the library; see `relay::resolve_heartbeat_secs`.
    let heartbeat_secs =
        relay::resolve_heartbeat_secs(std::env::var("REMOTEPI_HEARTBEAT_SECS").ok().as_deref());
    info!(heartbeat_secs, "WS keepalive heartbeat interval");
    // PR #48 review #1 — TTL for identical presence/rooms reply suppression
    // (default 30 s, floor 1 s). See `relay::resolve_dedup_ttl_secs`.
    let dedup_ttl_secs =
        relay::resolve_dedup_ttl_secs(std::env::var("REMOTEPI_DEDUP_TTL_SECS").ok().as_deref());
    info!(dedup_ttl_secs, "control-reply dedup TTL");

    // Read (and memoize) the outer-envelope size ceiling once at startup, then
    // log the effective value so ops can confirm RELAY_MAX_CT_MIB took effect.
    let max_ct_bytes = relay::protocol::outer::max_ct_bytes();
    info!(max_ct_bytes, "outer envelope size limit");

    // Default puts the SQLite file (and any transient -journal) under data/,
    // so bare-metal `cargo run` doesn't litter the project root.
    let db_path =
        std::env::var("REMOTEPI_MESH_DB_PATH").unwrap_or_else(|_| "data/mesh.db".to_string());

    let mesh = Arc::new(
        relay::MeshStore::open(&db_path)
            .with_context(|| format!("failed to open mesh DB at {db_path}"))?,
    );
    info!("mesh storage opened at {db_path}");

    let presence = Arc::new(relay::PresenceManager::new());
    let rooms = Arc::new(relay::RoomManager::new());
    let metrics = Arc::new(relay::FirehoseMetrics::new());
    let registry = Arc::new(relay::PeerRegistry::new(
        presence.clone(),
        rooms.clone(),
        metrics.clone(),
    ));
    let mesh_auth = Arc::new(relay::MeshAuthCache::new());

    // Background reporter: drain firehose counters every 10 s and emit a
    // single structured log line. Quiet windows are silent.
    let metrics_for_reporter = metrics.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(10));
        interval.tick().await; // first tick is immediate; skip it
        loop {
            interval.tick().await;
            metrics_for_reporter.report_and_reset();
        }
    });

    // PR #24 follow-up (#6) — periodic subscription re-validation. Presence/
    // rooms subscriptions are authorized at subscribe time only; this sweep
    // prunes them once mesh membership is revoked (mirrors the `pi_envelope`
    // 60 s cache TTL; same cadence bounds the worst-case revocation delay).
    let sweeper_state = relay::AppState {
        registry: registry.clone(),
        presence: presence.clone(),
        rooms: rooms.clone(),
        mesh: mesh.clone(),
        mesh_auth: mesh_auth.clone(),
        metrics: metrics.clone(),
        port,
        heartbeat_interval: std::time::Duration::from_secs(heartbeat_secs),
        control_reply_dedup_ttl: std::time::Duration::from_secs(dedup_ttl_secs),
    };
    tokio::spawn(async move {
        let mut interval =
            tokio::time::interval(std::time::Duration::from_secs(relay::DEFAULT_HEARTBEAT_SECS));
        interval.tick().await; // first tick is immediate; skip it
        loop {
            interval.tick().await;
            let pruned = relay::prune_unauthorized_subscriptions(&sweeper_state).await;
            if pruned > 0 {
                info!(pruned, "subscription re-validation sweep pruned pairs");
            }
        }
    });

    let state = relay::AppState {
        registry,
        presence,
        rooms,
        mesh,
        mesh_auth,
        metrics,
        port,
        heartbeat_interval: std::time::Duration::from_secs(heartbeat_secs),
        control_reply_dedup_ttl: std::time::Duration::from_secs(dedup_ttl_secs),
    };
    let app = relay::build_router(state);

    let addr = format!("0.0.0.0:{port}");
    let listener = TcpListener::bind(&addr)
        .await
        .with_context(|| format!("failed to bind {addr}"))?;

    info!("relay listening on {addr} (WebSocket + /health + /mesh)");

    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(async {
        tokio::signal::ctrl_c()
            .await
            .expect("failed to install ctrl_c handler");
        info!("ctrl_c received, shutting down");
    })
    .await
    .context("axum::serve failed")?;

    Ok(())
}
