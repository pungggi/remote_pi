mod common;

use std::collections::VecDeque;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
use ed25519_dalek::SigningKey;
use futures_util::{SinkExt, StreamExt};
use relay::handlers::pi_forward::MeshAuthCache;
use relay::protocol::push::{PushRegisterRequest, PushRoomFilter};
use relay::push::config::VapidKeyMaterial;
use relay::push::events::{PushEvent, PushEventKind};
use relay::push::registration::{
    PushRegistrationStore, RegistrationError, RegistrationInput, RegistrationState,
};
use relay::push::web_push::{PushSendError, PushTransport};
use relay::push::{PushEventSink, PushMetrics, PushService, PushWorkerConfig};
use relay::{
    FirehoseMetrics, MeshStore, PeerRegistry, PresenceManager, RoomManager, RoomMeta, RoomMetaPatch,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

const P256DH: &str =
    "BLMbF9ffKBiWQLCKvTHb6LO8Nb6dcUh6TItC455vu2kElga6PQvUmaFyCdykxY2nOSSL3yKgfbmFLRTUaGv4yV8";
const AUTH: &str = "xS03Fi5ErfTNH_l9WHE9Ig";

fn peer_id() -> String {
    B64.encode(
        SigningKey::generate(&mut rand::thread_rng())
            .verifying_key()
            .to_bytes(),
    )
}

fn registration_request(id: &str, peers: Vec<String>) -> PushRegisterRequest {
    PushRegisterRequest {
        registration_id: id.to_owned(),
        device_id: "device-1".to_owned(),
        endpoint: format!("https://push.example.test/{id}"),
        p256dh: P256DH.to_owned(),
        auth: AUTH.to_owned(),
        temporary: false,
        peers,
        completion_rooms: Vec::new(),
    }
}

#[derive(Default)]
struct MockTransport {
    attempts: AtomicUsize,
    payloads: Mutex<Vec<Value>>,
    failures: Mutex<VecDeque<PushSendError>>,
}

impl MockTransport {
    fn clear(&self) {
        self.payloads.lock().unwrap().clear();
        self.attempts.store(0, Ordering::Relaxed);
    }

    fn payloads(&self) -> Vec<Value> {
        self.payloads.lock().unwrap().clone()
    }

    async fn wait_for_payloads(&self, count: usize) -> Vec<Value> {
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                if self.payloads.lock().unwrap().len() >= count {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        self.payloads()
    }
}

#[async_trait::async_trait]
impl PushTransport for MockTransport {
    async fn send(
        &self,
        registration: &relay::push::registration::StoredRegistration,
        _event: &PushEvent,
        payload: &[u8],
    ) -> Result<(), PushSendError> {
        self.attempts.fetch_add(1, Ordering::Relaxed);
        if let Some(error) = self.failures.lock().unwrap().pop_front() {
            return Err(error);
        }
        self.payloads.lock().unwrap().push(json!({
            "registration_id": registration.id,
            "payload": serde_json::from_slice::<Value>(payload).unwrap(),
        }));
        Ok(())
    }
}

struct TestPush {
    service: Arc<PushService>,
    mesh: Arc<MeshStore>,
    mesh_auth: Arc<MeshAuthCache>,
    transport: Arc<MockTransport>,
}

fn test_push(mesh: Arc<MeshStore>) -> TestPush {
    let mesh_auth = Arc::new(MeshAuthCache::new());
    let transport = Arc::new(MockTransport::default());
    let service = Arc::new(PushService::with_transport(
        mesh.clone(),
        mesh_auth.clone(),
        Arc::new(VapidKeyMaterial::generate().unwrap()),
        transport.clone(),
        16,
        PushWorkerConfig {
            max_attempts: 3,
            retry_base: Duration::ZERO,
        },
    ));
    TestPush {
        service,
        mesh,
        mesh_auth,
        transport,
    }
}

fn memory_push() -> TestPush {
    test_push(Arc::new(MeshStore::open_in_memory().unwrap()))
}

fn publish_membership(mesh: &MeshStore, owner: &str, members: &[String], version: u64) {
    let blob = json!({
        "issued_at": 1_700_000_000_000_u64,
        "version": version,
        "owner_pk": owner,
        "members": members.iter().map(|member| json!({
            "remote_epk": member,
            "relay_url": "wss://relay.example.test",
            "paired_at": "2025-01-01T00:00:00.000Z",
        })).collect::<Vec<_>>(),
    });
    let owner_bytes = B64.decode(owner).unwrap();
    let hash = Sha256::digest(&owner_bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    mesh.upsert(
        &hash,
        &owner_bytes,
        version,
        &serde_json::to_vec(&blob).unwrap(),
        &[0; 64],
        version as i64,
    )
    .unwrap();
}

async fn register_validated(
    push: &TestPush,
    owner: &str,
    registration_id: &str,
    peers: Vec<String>,
    completion_rooms: Vec<PushRoomFilter>,
) {
    let mut request = registration_request(registration_id, peers);
    request.completion_rooms = completion_rooms;
    assert_eq!(
        push.service.register(owner, request).await.unwrap(),
        RegistrationState::Pending
    );
    let validation = push.transport.wait_for_payloads(1).await;
    let token = validation[0]["payload"]["token"].as_str().unwrap();
    assert_eq!(
        push.service
            .validate(owner, registration_id, token)
            .await
            .unwrap(),
        RegistrationState::Validated
    );
    push.transport.clear();
}

fn room_meta(room_id: &str) -> RoomMeta {
    RoomMeta {
        room_id: room_id.to_owned(),
        name: None,
        cwd: None,
        model: None,
        thinking: None,
        working: false,
        waiting_for_input: false,
        provider_error: false,
        git: None,
        keeper: None,
        context_usage: None,
        gh_ref: None,
        gh_suggestion: None,
        stats: None,
        started_at: 0,
    }
}

#[tokio::test]
async fn registration_revalidates_credentials_persists_and_enforces_ownership() {
    let directory = tempfile::tempdir().unwrap();
    let db_path = directory.path().join("mesh.db");
    let push = test_push(Arc::new(MeshStore::open(&db_path).unwrap()));
    let owner = peer_id();
    let other = peer_id();
    let desired = peer_id();

    let request = registration_request("installation-1", vec![desired]);
    assert_eq!(
        push.service
            .register(&owner, request.clone())
            .await
            .unwrap(),
        RegistrationState::Pending
    );
    let validation = push.transport.wait_for_payloads(1).await;
    assert_eq!(validation[0]["payload"]["event"], "push_validate");
    let token = validation[0]["payload"]["token"].as_str().unwrap();
    assert!(
        push.service
            .validate(&other, "installation-1", token)
            .await
            .is_err()
    );
    assert_eq!(
        push.service
            .validate(&owner, "installation-1", token)
            .await
            .unwrap(),
        RegistrationState::Validated
    );
    push.transport.clear();

    assert_eq!(
        push.service
            .register(&owner, request.clone())
            .await
            .unwrap(),
        RegistrationState::Validated,
        "filter-only update must not require another validation push"
    );
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(push.transport.payloads().is_empty());

    let reopened = PushRegistrationStore::new(Arc::new(MeshStore::open(&db_path).unwrap()));
    let stored = reopened.get("installation-1").unwrap().unwrap();
    assert_eq!(stored.state, RegistrationState::Validated);
    let debug = format!("{stored:?}");
    assert!(!debug.contains(P256DH));
    assert!(!debug.contains(AUTH));
    assert!(!debug.contains("push.example.test"));

    let vapid_path = directory.path().join("vapid.pem");
    let first = VapidKeyMaterial::load_or_create(&vapid_path).unwrap();
    let second = VapidKeyMaterial::load_or_create(&vapid_path).unwrap();
    assert_eq!(first.public_key_base64(), second.public_key_base64());

    let mut changed = request.clone();
    changed.endpoint = "https://push.example.test/rotated".to_owned();
    assert_eq!(
        push.service.register(&owner, changed).await.unwrap(),
        RegistrationState::Pending
    );
    assert!(push.service.register(&other, request).await.is_err());
    push.service
        .unregister(&owner, "installation-1")
        .await
        .unwrap();
    assert!(reopened.get("installation-1").unwrap().is_none());
}

#[tokio::test]
async fn websocket_control_frames_cover_config_register_validate_and_unregister() {
    let push = memory_push();
    let (port, _state) = common::start_relay_with_push_state(push.service.clone()).await;
    let owner_key = SigningKey::generate(&mut rand::thread_rng());
    let desired = peer_id();
    let owner = B64.encode(owner_key.verifying_key().to_bytes());
    let (mut socket, _) = common::connect_and_auth_with_key(port, &owner_key).await;

    socket
        .send(Message::text(
            json!({"type":"push_config_request"}).to_string(),
        ))
        .await
        .unwrap();
    let config = next_json(&mut socket).await;
    assert_eq!(config["type"], "push_config");
    assert_eq!(config["enabled"], true);
    assert_eq!(config["vapid_public_key"], push.service.vapid_public_key());

    common::make_mesh_siblings(port, &[owner, desired.clone()]).await;
    let request = registration_request("ws-registration", vec![desired]);
    socket
        .send(Message::text(
            json!({
                "type": "push_register",
                "registration_id": request.registration_id,
                "device_id": request.device_id,
                "endpoint": request.endpoint,
                "p256dh": request.p256dh,
                "auth": request.auth,
                "temporary": request.temporary,
                "peers": request.peers,
                "completion_rooms": request.completion_rooms,
            })
            .to_string(),
        ))
        .await
        .unwrap();
    let registered = next_json(&mut socket).await;
    assert_eq!(registered["type"], "push_register_ok");
    assert_eq!(registered["state"], "pending");

    let validation = push.transport.wait_for_payloads(1).await;
    let token = validation[0]["payload"]["token"].as_str().unwrap();
    socket
        .send(Message::text(
            json!({
                "type": "push_validate",
                "registration_id": "ws-registration",
                "token": token,
            })
            .to_string(),
        ))
        .await
        .unwrap();
    let validated = next_json(&mut socket).await;
    assert_eq!(validated["type"], "push_validate_ok");
    assert_eq!(validated["state"], "validated");

    socket
        .send(Message::text(
            json!({
                "type": "push_unregister", "registration_id": "ws-registration"
            })
            .to_string(),
        ))
        .await
        .unwrap();
    let unregistered = next_json(&mut socket).await;
    assert_eq!(unregistered["type"], "push_unregister_ok");
}

#[tokio::test]
async fn room_edges_reach_sleeping_registrations_without_live_subscribers() {
    let push = memory_push();
    let owner = peer_id();
    let pi = peer_id();
    publish_membership(&push.mesh, &owner, std::slice::from_ref(&pi), 1);
    register_validated(
        &push,
        &owner,
        "sleeping-phone",
        vec![pi.clone()],
        vec![PushRoomFilter {
            peer: pi.clone(),
            room: "room-1".into(),
        }],
    )
    .await;

    let registry = PeerRegistry::new(
        Arc::new(PresenceManager::new()),
        Arc::new(RoomManager::new()),
        Arc::new(FirehoseMetrics::new()),
    );
    registry.set_push_event_sink(push.service.event_sink());
    let (tx, _rx) = mpsc::unbounded_channel();
    registry.register(pi.clone(), room_meta("room-1"), tx).await;

    assert!(
        registry
            .update_room_meta(
                &pi,
                "room-1",
                RoomMetaPatch {
                    working: Some(true),
                    ..Default::default()
                },
            )
            .await
    );
    let started = push.transport.wait_for_payloads(1).await;
    assert_eq!(started[0]["payload"]["event"], "run_started");

    registry
        .update_room_meta(
            &pi,
            "room-1",
            RoomMetaPatch {
                working: Some(true),
                ..Default::default()
            },
        )
        .await;
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert_eq!(
        push.transport.payloads().len(),
        1,
        "repeated patch must not duplicate a transition"
    );
    push.transport.clear();

    let marker = json!({"turn_id":"turn-1","ended_at":1_234});
    registry
        .update_room_meta(
            &pi,
            "room-1",
            RoomMetaPatch {
                working: Some(false),
                waiting_for_input: Some(true),
                run_done: Some(marker.clone()),
                ..Default::default()
            },
        )
        .await;
    let events = push.transport.wait_for_payloads(3).await;
    let kinds: Vec<_> = events
        .iter()
        .map(|entry| entry["payload"]["event"].as_str().unwrap())
        .collect();
    assert_eq!(kinds, vec!["run_finished", "run_done", "waiting_started"]);
    assert_eq!(events[1]["payload"]["ended_at"], 1_234);

    registry
        .update_room_meta(
            &pi,
            "room-1",
            RoomMetaPatch {
                run_done: Some(marker),
                ..Default::default()
            },
        )
        .await;
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert_eq!(
        push.transport.payloads().len(),
        3,
        "same run_done marker is deduplicated"
    );
}

#[tokio::test]
async fn completion_filter_revocation_retry_and_stale_states_are_enforced() {
    let push = memory_push();
    let owner = peer_id();
    let pi = peer_id();
    publish_membership(&push.mesh, &owner, std::slice::from_ref(&pi), 1);
    register_validated(
        &push,
        &owner,
        "filtered-phone",
        vec![pi.clone()],
        Vec::new(),
    )
    .await;
    let sink = push.service.event_sink();

    sink.try_send(PushEvent::run_done(
        &pi,
        "room-1",
        &json!({"ended_at":1}),
        1,
    ));
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(
        push.transport.payloads().is_empty(),
        "run_done requires room opt-in"
    );

    push.transport.failures.lock().unwrap().extend([
        PushSendError::transient("one"),
        PushSendError::transient("two"),
    ]);
    sink.try_send(PushEvent::transition(
        PushEventKind::RunStarted,
        &pi,
        "room-1",
        2,
    ));
    let sent = push.transport.wait_for_payloads(1).await;
    assert_eq!(sent[0]["payload"]["event"], "run_started");
    assert_eq!(push.transport.attempts.load(Ordering::Relaxed), 3);

    push.transport.clear();
    push.transport
        .failures
        .lock()
        .unwrap()
        .push_back(PushSendError::stale("endpoint_gone"));
    sink.try_send(PushEvent::transition(
        PushEventKind::RunFinished,
        &pi,
        "room-1",
        3,
    ));
    tokio::time::sleep(Duration::from_millis(100)).await;
    let store = PushRegistrationStore::new(push.mesh.clone());
    assert_eq!(
        store.get("filtered-phone").unwrap().unwrap().state,
        RegistrationState::Stale
    );

    publish_membership(&push.mesh, &owner, &[], 2);
    push.mesh_auth.clear();
    sink.try_send(PushEvent::transition(
        PushEventKind::RunStarted,
        &pi,
        "room-1",
        4,
    ));
    tokio::time::sleep(Duration::from_millis(75)).await;
    assert!(push.transport.payloads().is_empty());
    assert_eq!(push.service.prune_revoked().await.unwrap(), 1);
    assert!(store.get("filtered-phone").unwrap().is_none());
}

#[test]
fn validation_rejects_wrong_and_expired_tokens() {
    let store = PushRegistrationStore::new(Arc::new(MeshStore::open_in_memory().unwrap()));
    let input = RegistrationInput {
        id: "expiring".into(),
        owner_peer_id: "owner".into(),
        device_id: "device".into(),
        endpoint: "https://push.example.test/expiring".into(),
        p256dh: P256DH.into(),
        auth: AUTH.into(),
        temporary: false,
        desired_peers: vec!["peer".into()],
        completion_rooms: vec![],
    };
    store.upsert(&input, "token-hash", 100, 1).unwrap();
    assert!(matches!(
        store.validate("expiring", "owner", "wrong", 50),
        Err(RegistrationError::ValidationFailed)
    ));
    assert!(matches!(
        store.validate("expiring", "owner", "token-hash", 101),
        Err(RegistrationError::ValidationExpired)
    ));
}

#[test]
fn event_sink_is_bounded_and_nonblocking() {
    let (sender, _receiver) = mpsc::channel(1);
    let metrics = Arc::new(PushMetrics::default());
    let sink = PushEventSink::new(sender, metrics.clone());
    assert!(sink.try_send(PushEvent::transition(
        PushEventKind::RunStarted,
        "p",
        "r",
        1
    )));
    assert!(!sink.try_send(PushEvent::transition(
        PushEventKind::RunStarted,
        "p",
        "r",
        2
    )));
    assert_eq!(metrics.snapshot().enqueued, 1);
    assert_eq!(metrics.snapshot().queue_full, 1);
}

async fn next_json(socket: &mut common::WsStream) -> Value {
    loop {
        let message = tokio::time::timeout(Duration::from_secs(2), socket.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        if let Message::Text(text) = message {
            return serde_json::from_str(&text).unwrap();
        }
    }
}
