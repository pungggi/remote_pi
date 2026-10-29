use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

pub const MAX_CLEARTEXT_PAYLOAD_BYTES: usize = 3993;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PushEventKind {
    PushValidate,
    RunStarted,
    RunFinished,
    RunDone,
    WaitingStarted,
    WaitingCleared,
}

#[derive(Clone)]
pub struct PushEvent {
    pub id: String,
    pub kind: PushEventKind,
    pub peer: Option<String>,
    pub room: Option<String>,
    pub occurred_at: i64,
    pub registration_id: Option<String>,
    pub validation_token: Option<String>,
    pub ended_at: Option<i64>,
}

impl std::fmt::Debug for PushEvent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PushEvent")
            .field("id", &self.id)
            .field("kind", &self.kind)
            .field("peer", &self.peer)
            .field("room", &self.room)
            .field("occurred_at", &self.occurred_at)
            .field("registration_id", &self.registration_id)
            .field("ended_at", &self.ended_at)
            .finish_non_exhaustive()
    }
}

#[derive(Debug, thiserror::Error)]
pub enum PushEventError {
    #[error("payload serialization: {0}")]
    Json(#[from] serde_json::Error),
    #[error("push payload too large: {0} bytes")]
    TooLarge(usize),
}

impl PushEvent {
    pub fn transition(kind: PushEventKind, peer: &str, room: &str, occurred_at: i64) -> Self {
        Self {
            id: random_id(),
            kind,
            peer: Some(peer.to_owned()),
            room: Some(room.to_owned()),
            occurred_at,
            registration_id: None,
            validation_token: None,
            ended_at: None,
        }
    }

    pub fn run_done(peer: &str, room: &str, marker: &Value, occurred_at: i64) -> Self {
        let ended_at = marker.get("ended_at").and_then(Value::as_i64);
        let canonical = serde_json::to_vec(marker).unwrap_or_else(|_| b"invalid".to_vec());
        let mut hash_input = Vec::with_capacity(peer.len() + room.len() + canonical.len() + 2);
        hash_input.extend_from_slice(peer.as_bytes());
        hash_input.push(0);
        hash_input.extend_from_slice(room.as_bytes());
        hash_input.push(0);
        hash_input.extend_from_slice(&canonical);
        let digest = Sha256::digest(&hash_input);
        Self {
            id: URL_SAFE_NO_PAD.encode(&digest[..16]),
            kind: PushEventKind::RunDone,
            peer: Some(peer.to_owned()),
            room: Some(room.to_owned()),
            occurred_at: ended_at.unwrap_or(occurred_at),
            registration_id: None,
            validation_token: None,
            ended_at,
        }
    }

    pub fn validation(registration_id: &str, token: &str, occurred_at: i64) -> Self {
        Self {
            id: random_id(),
            kind: PushEventKind::PushValidate,
            peer: None,
            room: None,
            occurred_at,
            registration_id: Some(registration_id.to_owned()),
            validation_token: Some(token.to_owned()),
            ended_at: None,
        }
    }

    pub fn payload_bytes(&self) -> Result<Vec<u8>, PushEventError> {
        let payload = if self.kind == PushEventKind::PushValidate {
            json!({
                "v": 1,
                "event": self.kind,
                "event_id": self.id,
                "registration_id": self.registration_id,
                "token": self.validation_token,
                "occurred_at": self.occurred_at,
            })
        } else {
            let mut payload = json!({
                "v": 1,
                "event": self.kind,
                "event_id": self.id,
                "peer": self.peer,
                "room": self.room,
                "occurred_at": self.occurred_at,
            });
            if let Some(ended_at) = self.ended_at {
                payload["ended_at"] = ended_at.into();
            }
            payload
        };
        let bytes = serde_json::to_vec(&payload)?;
        if bytes.len() > MAX_CLEARTEXT_PAYLOAD_BYTES {
            return Err(PushEventError::TooLarge(bytes.len()));
        }
        Ok(bytes)
    }
}

#[derive(Debug, Clone, Copy)]
pub struct RoomTransitionState {
    pub previous_working: bool,
    pub current_working: bool,
    pub previous_waiting: bool,
    pub current_waiting: bool,
}

pub fn transition_events(
    peer: &str,
    room: &str,
    state: RoomTransitionState,
    run_done_marker: Option<&Value>,
    occurred_at: i64,
) -> Vec<PushEvent> {
    let mut events = Vec::with_capacity(3);
    match (state.previous_working, state.current_working) {
        (false, true) => events.push(PushEvent::transition(
            PushEventKind::RunStarted,
            peer,
            room,
            occurred_at,
        )),
        (true, false) => events.push(PushEvent::transition(
            PushEventKind::RunFinished,
            peer,
            room,
            occurred_at,
        )),
        _ => {}
    }
    if let Some(marker) = run_done_marker {
        events.push(PushEvent::run_done(peer, room, marker, occurred_at));
    }
    match (state.previous_waiting, state.current_waiting) {
        (false, true) => events.push(PushEvent::transition(
            PushEventKind::WaitingStarted,
            peer,
            room,
            occurred_at,
        )),
        (true, false) => events.push(PushEvent::transition(
            PushEventKind::WaitingCleared,
            peer,
            room,
            occurred_at,
        )),
        _ => {}
    }
    events
}

pub fn random_id() -> String {
    URL_SAFE_NO_PAD.encode(rand::random::<[u8; 16]>())
}

pub fn random_validation_token() -> String {
    URL_SAFE_NO_PAD.encode(rand::random::<[u8; 32]>())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_only_real_edges_and_unique_marker() {
        let marker = json!({"turn_id":"turn-1","ended_at":1234});
        let events = transition_events(
            "p",
            "r",
            RoomTransitionState {
                previous_working: false,
                current_working: true,
                previous_waiting: true,
                current_waiting: false,
            },
            Some(&marker),
            1200,
        );
        let kinds: Vec<_> = events.iter().map(|event| event.kind).collect();
        assert_eq!(
            kinds,
            vec![
                PushEventKind::RunStarted,
                PushEventKind::RunDone,
                PushEventKind::WaitingCleared
            ]
        );
        assert_eq!(events[1].occurred_at, 1234);
        assert_eq!(
            events[1].id,
            PushEvent::run_done("p", "r", &marker, 9999).id
        );
        assert!(
            transition_events(
                "p",
                "r",
                RoomTransitionState {
                    previous_working: true,
                    current_working: true,
                    previous_waiting: false,
                    current_waiting: false,
                },
                None,
                1,
            )
            .is_empty()
        );
    }

    #[test]
    fn validation_debug_does_not_expose_token() {
        let event = PushEvent::validation("registration", "super-secret", 1);
        assert!(!format!("{event:?}").contains("super-secret"));
        assert!(event.payload_bytes().unwrap().len() < MAX_CLEARTEXT_PAYLOAD_BYTES);
    }
}
