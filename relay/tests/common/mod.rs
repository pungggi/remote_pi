#![allow(dead_code)]

use std::net::SocketAddr;
use std::sync::Arc;

use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
use ed25519_dalek::{Signer, SigningKey};
use futures_util::{SinkExt, StreamExt};
use relay::{
    AppState, FirehoseMetrics, MeshAuthCache, MeshStore, PeerRegistry, PresenceManager,
    RoomManager, build_router,
};
use serde_json::json;
use tokio::net::TcpListener;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async, tungstenite::Message};

pub type WsStream = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

/// Binds the unified relay (WS + `/health` + `/mesh`) on a random localhost
/// port and returns that port. Mesh storage is `:memory:` for these tests —
/// use the helper in `tests/mesh_test.rs` when you need a persistent DB.
pub async fn start_relay() -> u16 {
    start_relay_with_state().await.0
}

/// Same as [start_relay] but also returns the live [AppState] — for tests
/// that need to inspect/drive server-side managers directly (subscription
/// re-validation sweep).
pub async fn start_relay_with_state() -> (u16, relay::AppState) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let mesh = Arc::new(MeshStore::open_in_memory().unwrap());
    let presence = Arc::new(PresenceManager::new());
    let rooms = Arc::new(RoomManager::new());
    let metrics = Arc::new(FirehoseMetrics::new());
    let registry = Arc::new(PeerRegistry::new(
        presence.clone(),
        rooms.clone(),
        metrics.clone(),
    ));
    let mesh_auth = Arc::new(MeshAuthCache::new());
    let state = AppState {
        registry,
        presence,
        rooms,
        mesh,
        mesh_auth,
        metrics,
        port,
        heartbeat_interval: std::time::Duration::from_secs(60),
        // Short TTL (prod default is 30 s) so the after-TTL delivery tests
        // sleep ~1.2 s instead of 31 s. Immediate-burst suppression tests
        // still suppress — their follow-ups land well inside the window.
        control_reply_dedup_ttl: std::time::Duration::from_secs(1),
    };
    let app = build_router(state.clone());
    tokio::spawn(async move {
        let _ = axum::serve(
            listener,
            app.into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await;
    });
    // Give axum a moment to start accepting.
    tokio::time::sleep(tokio::time::Duration::from_millis(20)).await;
    (port, state)
}

/// Connects using a caller-supplied key and room_id, completes the full auth handshake.
/// Returns (ws_stream, peer_id_b64).
pub async fn connect_and_auth_with_room(
    port: u16,
    sk: &SigningKey,
    room_id: &str,
) -> (WsStream, String) {
    let url = format!("ws://127.0.0.1:{port}");
    let (mut ws, _) = connect_async(&url).await.unwrap();

    let vk = sk.verifying_key();
    let pubkey_b64 = B64.encode(vk.to_bytes());

    ws.send(Message::text(
        json!({"type": "hello", "pubkey": pubkey_b64, "room_id": room_id}).to_string(),
    ))
    .await
    .unwrap();

    let challenge_msg = ws.next().await.unwrap().unwrap();
    let challenge_json: serde_json::Value =
        serde_json::from_str(challenge_msg.to_text().unwrap()).unwrap();
    let nonce_b64 = challenge_json["nonce"].as_str().unwrap();
    let nonce_arr: [u8; 32] = B64.decode(nonce_b64).unwrap().try_into().unwrap();

    let sig = sk.sign(&nonce_arr);
    ws.send(Message::text(
        json!({"type": "auth", "sig": B64.encode(sig.to_bytes())}).to_string(),
    ))
    .await
    .unwrap();

    tokio::time::sleep(tokio::time::Duration::from_millis(30)).await;

    (ws, pubkey_b64)
}

/// Connects with a caller-supplied key, defaults to room "main".
pub async fn connect_and_auth_with_key(port: u16, sk: &SigningKey) -> (WsStream, String) {
    connect_and_auth_with_room(port, sk, "main").await
}

/// Connects with a fresh random key, defaults to room "main".
pub async fn connect_and_auth(port: u16) -> (WsStream, String) {
    let sk = SigningKey::generate(&mut rand::thread_rng());
    connect_and_auth_with_key(port, &sk).await
}

/// Publishes a signed mesh blob (via `POST /mesh/:hash`) that makes ALL the
/// given peer pubkeys siblings of one Owner — so the presence/rooms mesh
/// gate (security fix 2026-08) authorizes cross-peer queries between them.
///
/// Call BEFORE the first gated control frame: `MeshAuthCache` caches a
/// negative result for ~1 s, and a query racing this publish could read a
/// stale miss.
pub async fn make_mesh_siblings(port: u16, member_pubkeys: &[String]) {
    let owner = SigningKey::generate(&mut rand::thread_rng());
    let owner_pk_bytes = owner.verifying_key().to_bytes();
    let owner_pk = B64.encode(owner_pk_bytes);

    let blob = json!({
        "issued_at": 1_700_000_000_000_u64,
        "version": 1_u64,
        "owner_pk": owner_pk,
        "members": member_pubkeys.iter().map(|epk| json!({
            "remote_epk": epk,
            "relay_url": "wss://relay.example.test",
            "paired_at": "2025-01-01T00:00:00.000Z",
        })).collect::<Vec<_>>(),
    });
    let blob_bytes = serde_json::to_vec(&blob).unwrap();
    let sig = owner.sign(&blob_bytes);
    let envelope = json!({
        "blob": B64.encode(&blob_bytes),
        "sig": B64.encode(sig.to_bytes()),
    });

    use sha2::{Digest, Sha256};
    let hash = Sha256::digest(owner_pk_bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();

    let url = format!("http://127.0.0.1:{port}/mesh/{hash}");
    let client = reqwest::Client::new();
    let resp = client.post(&url).json(&envelope).send().await.unwrap();
    assert!(
        resp.status().is_success(),
        "make_mesh_siblings: POST /mesh/{hash} failed with {}",
        resp.status()
    );
}
