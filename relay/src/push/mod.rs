pub mod config;
pub mod events;
pub mod registration;
pub mod web_push;

use std::collections::HashSet;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use sha2::{Digest, Sha256};
use tokio::sync::mpsc;

use crate::handlers::pi_forward::MeshAuthCache;
use crate::mesh::MeshStore;
use crate::protocol::push::{PushRegisterRequest, PushRoomFilter};
use config::{EndpointPolicy, VapidKeyMaterial};
use events::{PushEvent, PushEventKind, random_validation_token};
use registration::{
    PushRegistrationStore, RegistrationError, RegistrationInput, RegistrationState,
    StoredRegistration,
};
use web_push::{PushSendFailureKind, PushTransport, ReqwestWebPush};

pub const DEFAULT_PUSH_QUEUE_CAPACITY: usize = 256;
pub const VALIDATION_TTL_MS: i64 = 10 * 60 * 1000;
const MAX_DEDUP_ENTRIES: usize = 4096;

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct PushMetricsSnapshot {
    pub enqueued: u64,
    pub queue_full: u64,
    pub sent: u64,
    pub validation_sent: u64,
    pub failed: u64,
    pub stale: u64,
    pub deduplicated: u64,
    pub revoked: u64,
}

#[derive(Debug, Default)]
pub struct PushMetrics {
    enqueued: AtomicU64,
    queue_full: AtomicU64,
    sent: AtomicU64,
    validation_sent: AtomicU64,
    failed: AtomicU64,
    stale: AtomicU64,
    deduplicated: AtomicU64,
    revoked: AtomicU64,
}

impl PushMetrics {
    pub fn snapshot(&self) -> PushMetricsSnapshot {
        PushMetricsSnapshot {
            enqueued: self.enqueued.load(Ordering::Relaxed),
            queue_full: self.queue_full.load(Ordering::Relaxed),
            sent: self.sent.load(Ordering::Relaxed),
            validation_sent: self.validation_sent.load(Ordering::Relaxed),
            failed: self.failed.load(Ordering::Relaxed),
            stale: self.stale.load(Ordering::Relaxed),
            deduplicated: self.deduplicated.load(Ordering::Relaxed),
            revoked: self.revoked.load(Ordering::Relaxed),
        }
    }

    pub fn report_and_reset(&self) {
        let snapshot = PushMetricsSnapshot {
            enqueued: self.enqueued.swap(0, Ordering::Relaxed),
            queue_full: self.queue_full.swap(0, Ordering::Relaxed),
            sent: self.sent.swap(0, Ordering::Relaxed),
            validation_sent: self.validation_sent.swap(0, Ordering::Relaxed),
            failed: self.failed.swap(0, Ordering::Relaxed),
            stale: self.stale.swap(0, Ordering::Relaxed),
            deduplicated: self.deduplicated.swap(0, Ordering::Relaxed),
            revoked: self.revoked.swap(0, Ordering::Relaxed),
        };
        if snapshot == PushMetricsSnapshot::default() {
            return;
        }
        tracing::info!(
            target: "push",
            enqueued = snapshot.enqueued,
            queue_full = snapshot.queue_full,
            sent = snapshot.sent,
            validation_sent = snapshot.validation_sent,
            failed = snapshot.failed,
            stale = snapshot.stale,
            deduplicated = snapshot.deduplicated,
            revoked = snapshot.revoked,
            "push 10s window"
        );
    }
}

#[derive(Debug, Clone)]
pub struct PushEventSink {
    sender: mpsc::Sender<PushEvent>,
    metrics: Arc<PushMetrics>,
}

impl PushEventSink {
    pub fn new(sender: mpsc::Sender<PushEvent>, metrics: Arc<PushMetrics>) -> Self {
        Self { sender, metrics }
    }

    /// Non-blocking by design: room routing never waits for SQLite, DNS, HTTP,
    /// or queue capacity. A full queue drops only the best-effort wake event.
    pub fn try_send(&self, event: PushEvent) -> bool {
        match self.sender.try_send(event) {
            Ok(()) => {
                self.metrics.enqueued.fetch_add(1, Ordering::Relaxed);
                true
            }
            Err(_) => {
                self.metrics.queue_full.fetch_add(1, Ordering::Relaxed);
                false
            }
        }
    }
}

#[derive(Debug, Clone)]
pub struct PushWorkerConfig {
    pub max_attempts: u8,
    pub retry_base: Duration,
}

impl Default for PushWorkerConfig {
    fn default() -> Self {
        Self {
            max_attempts: 3,
            retry_base: Duration::from_millis(150),
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum PushServiceError {
    #[error("invalid request: {0}")]
    InvalidRequest(&'static str),
    #[error("registration error: {0}")]
    Registration(#[from] RegistrationError),
    #[error("push queue is full")]
    QueueFull,
}

impl PushServiceError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::InvalidRequest(code) => code,
            Self::QueueFull => "queue_full",
            Self::Registration(error) => match error {
                RegistrationError::NotFound => "unknown_registration",
                RegistrationError::OwnershipConflict | RegistrationError::EndpointConflict => {
                    "registration_conflict"
                }
                RegistrationError::ValidationFailed => "validation_failed",
                RegistrationError::ValidationExpired => "validation_expired",
                RegistrationError::Sql(_)
                | RegistrationError::Json(_)
                | RegistrationError::InvalidState(_)
                | RegistrationError::Task(_) => "store_error",
            },
        }
    }

    pub fn public_message(&self) -> &'static str {
        match self.code() {
            "unknown_registration" => "Push registration was not found.",
            "registration_conflict" => "Push registration conflicts with existing ownership.",
            "validation_failed" => "Push validation token is invalid.",
            "validation_expired" => "Push validation token expired.",
            "queue_full" => "Push queue is full; retry registration.",
            "store_error" => "Push registration storage failed.",
            _ => "Push registration request is invalid.",
        }
    }
}

#[derive(Clone)]
pub struct PushService {
    store: PushRegistrationStore,
    sink: PushEventSink,
    vapid: Arc<VapidKeyMaterial>,
    metrics: Arc<PushMetrics>,
    mesh: Arc<MeshStore>,
    mesh_auth: Arc<MeshAuthCache>,
}

impl PushService {
    pub fn new(
        mesh: Arc<MeshStore>,
        mesh_auth: Arc<MeshAuthCache>,
        vapid: Arc<VapidKeyMaterial>,
        policy: EndpointPolicy,
    ) -> Self {
        let transport = Arc::new(ReqwestWebPush::new(vapid.clone(), policy));
        Self::with_transport(
            mesh,
            mesh_auth,
            vapid,
            transport,
            DEFAULT_PUSH_QUEUE_CAPACITY,
            PushWorkerConfig::default(),
        )
    }

    pub fn with_transport(
        mesh: Arc<MeshStore>,
        mesh_auth: Arc<MeshAuthCache>,
        vapid: Arc<VapidKeyMaterial>,
        transport: Arc<dyn PushTransport>,
        queue_capacity: usize,
        worker_config: PushWorkerConfig,
    ) -> Self {
        let store = PushRegistrationStore::new(mesh.clone());
        let metrics = Arc::new(PushMetrics::default());
        let (sender, receiver) = mpsc::channel(queue_capacity.max(1));
        let sink = PushEventSink {
            sender,
            metrics: metrics.clone(),
        };
        let worker_store = store.clone();
        let worker_metrics = metrics.clone();
        let worker_mesh = mesh.clone();
        let worker_mesh_auth = mesh_auth.clone();
        tokio::spawn(async move {
            run_worker(
                receiver,
                worker_store,
                worker_mesh,
                worker_mesh_auth,
                transport,
                worker_config,
                worker_metrics,
            )
            .await;
        });
        Self {
            store,
            sink,
            vapid,
            metrics,
            mesh,
            mesh_auth,
        }
    }

    pub fn event_sink(&self) -> PushEventSink {
        self.sink.clone()
    }

    pub fn metrics(&self) -> Arc<PushMetrics> {
        self.metrics.clone()
    }

    pub fn vapid_public_key(&self) -> &str {
        self.vapid.public_key_base64()
    }

    pub async fn register(
        &self,
        owner_peer_id: &str,
        request: PushRegisterRequest,
    ) -> Result<RegistrationState, PushServiceError> {
        validate_register_request(&request)?;
        let now = now_ms();
        let token = random_validation_token();
        let token_hash = validation_token_hash(&token);
        let input = RegistrationInput {
            id: request.registration_id.clone(),
            owner_peer_id: owner_peer_id.to_owned(),
            device_id: request.device_id,
            endpoint: request.endpoint,
            p256dh: request.p256dh,
            auth: request.auth,
            temporary: request.temporary,
            desired_peers: request.peers,
            completion_rooms: request.completion_rooms,
        };
        let registration_id = input.id.clone();
        let store = self.store.clone();
        let state =
            database(move || store.upsert(&input, &token_hash, now + VALIDATION_TTL_MS, now))
                .await?;
        if state == RegistrationState::Pending
            && !self
                .sink
                .try_send(PushEvent::validation(&registration_id, &token, now))
        {
            return Err(PushServiceError::QueueFull);
        }
        Ok(state)
    }

    pub async fn validate(
        &self,
        owner_peer_id: &str,
        registration_id: &str,
        token: &str,
    ) -> Result<RegistrationState, PushServiceError> {
        validate_id(registration_id, "invalid_registration_id")?;
        if token.is_empty() || token.len() > 256 || token.chars().any(char::is_control) {
            return Err(PushServiceError::InvalidRequest("invalid_validation_token"));
        }
        let store = self.store.clone();
        let id = registration_id.to_owned();
        let owner = owner_peer_id.to_owned();
        let token_hash = validation_token_hash(token);
        Ok(database(move || store.validate(&id, &owner, &token_hash, now_ms())).await?)
    }

    pub async fn unregister(
        &self,
        owner_peer_id: &str,
        registration_id: &str,
    ) -> Result<(), PushServiceError> {
        validate_id(registration_id, "invalid_registration_id")?;
        let store = self.store.clone();
        let id = registration_id.to_owned();
        let owner = owner_peer_id.to_owned();
        let removed = database(move || store.remove(&id, &owner)).await?;
        if removed {
            Ok(())
        } else {
            Err(RegistrationError::NotFound.into())
        }
    }

    /// Removes revoked desired peers from persisted registrations. Empty
    /// registrations are deleted, so a revoked pairing cannot remain a
    /// dormant future delivery grant.
    pub async fn prune_revoked(&self) -> Result<usize, PushServiceError> {
        let store = self.store.clone();
        let registrations = database(move || store.list_all()).await?;
        let mut pruned = 0usize;
        for registration in registrations {
            let mut allowed = Vec::with_capacity(registration.desired_peers.len());
            for peer in &registration.desired_peers {
                if peer == &registration.owner_peer_id
                    || self
                        .mesh_auth
                        .is_authorized(&registration.owner_peer_id, peer, self.mesh.clone())
                        .await
                {
                    allowed.push(peer.clone());
                }
            }
            if allowed.len() == registration.desired_peers.len() {
                continue;
            }

            let revoked = registration.desired_peers.len() - allowed.len();
            let completion_rooms: Vec<_> = registration
                .completion_rooms
                .iter()
                .filter(|filter| allowed.contains(&filter.peer))
                .cloned()
                .collect();
            let store = self.store.clone();
            let id = registration.id.clone();
            if allowed.is_empty() {
                let owner = registration.owner_peer_id.clone();
                database(move || store.remove(&id, &owner)).await?;
            } else {
                database(move || store.update_filters(&id, &allowed, &completion_rooms, now_ms()))
                    .await?;
            }
            self.metrics
                .revoked
                .fetch_add(revoked as u64, Ordering::Relaxed);
            pruned += 1;
        }
        Ok(pruned)
    }
}

async fn database<F, T>(operation: F) -> Result<T, RegistrationError>
where
    F: FnOnce() -> Result<T, RegistrationError> + Send + 'static,
    T: Send + 'static,
{
    tokio::task::spawn_blocking(operation)
        .await
        .map_err(|error| RegistrationError::Task(error.to_string()))?
}

async fn run_worker(
    mut receiver: mpsc::Receiver<PushEvent>,
    store: PushRegistrationStore,
    mesh: Arc<MeshStore>,
    mesh_auth: Arc<MeshAuthCache>,
    transport: Arc<dyn PushTransport>,
    config: PushWorkerConfig,
    metrics: Arc<PushMetrics>,
) {
    let mut dedup = HashSet::new();
    while let Some(event) = receiver.recv().await {
        let registrations = match target_registrations(&store, &event, &mesh, &mesh_auth).await {
            Ok(registrations) => registrations,
            Err(error) => {
                tracing::warn!(error = %error, event = ?event.kind, "push target lookup failed");
                continue;
            }
        };
        for registration in registrations {
            if dedup.len() >= MAX_DEDUP_ENTRIES {
                dedup.clear();
            }
            if !dedup.insert((registration.id.clone(), event.id.clone())) {
                metrics.deduplicated.fetch_add(1, Ordering::Relaxed);
                continue;
            }
            send_with_retry(
                &store,
                transport.as_ref(),
                &config,
                &metrics,
                &registration,
                &event,
            )
            .await;
        }
    }
}

async fn target_registrations(
    store: &PushRegistrationStore,
    event: &PushEvent,
    mesh: &Arc<MeshStore>,
    mesh_auth: &Arc<MeshAuthCache>,
) -> Result<Vec<StoredRegistration>, RegistrationError> {
    if event.kind == PushEventKind::PushValidate {
        let registration_id = event.registration_id.clone().unwrap_or_default();
        let token = event.validation_token.clone().unwrap_or_default();
        let store = store.clone();
        let registration = database(move || store.get(&registration_id))
            .await?
            .into_iter()
            .filter(|registration| {
                registration.state == RegistrationState::Pending
                    && registration
                        .validation_expires_at
                        .is_some_and(|expiry| expiry >= now_ms())
                    && registration.validation_token_hash.as_deref()
                        == Some(validation_token_hash(&token).as_str())
            })
            .collect();
        return Ok(registration);
    }

    let Some(peer) = event.peer.as_deref() else {
        return Ok(Vec::new());
    };
    let store_clone = store.clone();
    let registrations = database(move || store_clone.list_all()).await?;
    let mut targets = Vec::new();
    for registration in registrations {
        if registration.state != RegistrationState::Validated
            || !registration
                .desired_peers
                .iter()
                .any(|candidate| candidate == peer)
        {
            continue;
        }
        if event.kind == PushEventKind::RunDone
            && !registration
                .completion_rooms
                .iter()
                .any(|filter| filter.peer == peer && Some(&filter.room) == event.room.as_ref())
        {
            continue;
        }
        if registration.owner_peer_id != peer
            && !mesh_auth
                .is_authorized(&registration.owner_peer_id, peer, mesh.clone())
                .await
        {
            continue;
        }
        targets.push(registration);
    }
    Ok(targets)
}

async fn send_with_retry(
    store: &PushRegistrationStore,
    transport: &dyn PushTransport,
    config: &PushWorkerConfig,
    metrics: &PushMetrics,
    registration: &StoredRegistration,
    event: &PushEvent,
) {
    let payload = match event.payload_bytes() {
        Ok(payload) => payload,
        Err(error) => {
            tracing::warn!(error = %error, event = ?event.kind, "push payload rejected");
            metrics.failed.fetch_add(1, Ordering::Relaxed);
            return;
        }
    };
    for attempt in 1..=config.max_attempts.max(1) {
        match transport.send(registration, event, &payload).await {
            Ok(()) => {
                let store = store.clone();
                let id = registration.id.clone();
                if let Err(error) = database(move || store.mark_success(&id, now_ms())).await {
                    tracing::warn!(error = %error, "push success metadata update failed");
                }
                metrics.sent.fetch_add(1, Ordering::Relaxed);
                if event.kind == PushEventKind::PushValidate {
                    metrics.validation_sent.fetch_add(1, Ordering::Relaxed);
                }
                return;
            }
            Err(error) => {
                let retry = error.kind == PushSendFailureKind::Transient
                    && attempt < config.max_attempts.max(1);
                if retry {
                    let jitter = Duration::from_millis(rand::random::<u64>() % 100);
                    tokio::time::sleep(config.retry_base + jitter).await;
                    continue;
                }
                let store = store.clone();
                let id = registration.id.clone();
                let code = error.code;
                let result = match error.kind {
                    PushSendFailureKind::Stale => {
                        metrics.stale.fetch_add(1, Ordering::Relaxed);
                        database(move || store.mark_stale(&id, code, now_ms())).await
                    }
                    _ => database(move || store.mark_error(&id, code, now_ms())).await,
                };
                if let Err(error) = result {
                    tracing::warn!(error = %error, "push error metadata update failed");
                }
                metrics.failed.fetch_add(1, Ordering::Relaxed);
                return;
            }
        }
    }
}

fn validate_register_request(request: &PushRegisterRequest) -> Result<(), PushServiceError> {
    validate_id(&request.registration_id, "invalid_registration_id")?;
    validate_id(&request.device_id, "invalid_device_id")?;
    if request.endpoint.is_empty() || request.endpoint.len() > 1000 {
        return Err(PushServiceError::InvalidRequest("invalid_endpoint"));
    }
    web_push::parse_endpoint_url(&request.endpoint)
        .map_err(|_| PushServiceError::InvalidRequest("invalid_endpoint"))?;
    let p256dh = URL_SAFE_NO_PAD
        .decode(&request.p256dh)
        .map_err(|_| PushServiceError::InvalidRequest("invalid_crypto_keys"))?;
    let auth = URL_SAFE_NO_PAD
        .decode(&request.auth)
        .map_err(|_| PushServiceError::InvalidRequest("invalid_crypto_keys"))?;
    if p256dh.len() != 65 || p256dh.first() != Some(&4) || auth.len() != 16 {
        return Err(PushServiceError::InvalidRequest("invalid_crypto_keys"));
    }
    if request.peers.is_empty() || request.peers.len() > 64 {
        return Err(PushServiceError::InvalidRequest("invalid_peers"));
    }
    let unique_peers: HashSet<_> = request.peers.iter().collect();
    if unique_peers.len() != request.peers.len()
        || request.peers.iter().any(|peer| !valid_peer_id(peer))
        || request.completion_rooms.len() > 256
    {
        return Err(PushServiceError::InvalidRequest("invalid_peers"));
    }
    for PushRoomFilter { peer, room } in &request.completion_rooms {
        if !request.peers.contains(peer)
            || room.is_empty()
            || room.len() > 100
            || room.chars().any(char::is_control)
        {
            return Err(PushServiceError::InvalidRequest("invalid_completion_rooms"));
        }
    }
    Ok(())
}

fn validate_id(value: &str, code: &'static str) -> Result<(), PushServiceError> {
    if value.is_empty() || value.len() > 100 || value.chars().any(char::is_control) {
        Err(PushServiceError::InvalidRequest(code))
    } else {
        Ok(())
    }
}

fn valid_peer_id(peer: &str) -> bool {
    !peer.is_empty() && peer.len() <= 128 && !peer.chars().any(char::is_control)
}

fn validation_token_hash(token: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(token.as_bytes()))
}

pub(crate) fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}
