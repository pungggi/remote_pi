use serde::{Deserialize, Serialize};

#[derive(Clone, Deserialize)]
pub struct PushRegisterRequest {
    pub registration_id: String,
    pub device_id: String,
    pub endpoint: String,
    pub p256dh: String,
    pub auth: String,
    #[serde(default)]
    pub temporary: bool,
    #[serde(default)]
    pub peers: Vec<String>,
    #[serde(default)]
    pub completion_rooms: Vec<PushRoomFilter>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub struct PushRoomFilter {
    pub peer: String,
    pub room: String,
}

#[derive(Clone, Deserialize)]
pub struct PushValidateRequest {
    pub registration_id: String,
    pub token: String,
}

#[derive(Clone, Deserialize)]
pub struct PushUnregisterRequest {
    pub registration_id: String,
}
