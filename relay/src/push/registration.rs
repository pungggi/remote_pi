use std::sync::Arc;

use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};

use crate::mesh::MeshStore;
use crate::protocol::push::PushRoomFilter;

const REGISTRATION_COLUMNS: &str = "id, owner_peer_id, device_id, endpoint, p256dh, auth, temporary, desired_peers, completion_rooms, state, validation_token_hash, validation_expires_at, created_at, updated_at, last_successful_push_at, last_terminal_error";

#[derive(Debug, thiserror::Error)]
pub enum RegistrationError {
    #[error("sqlite: {0}")]
    Sql(#[from] rusqlite::Error),
    #[error("registration metadata: {0}")]
    Json(#[from] serde_json::Error),
    #[error("registration not found")]
    NotFound,
    #[error("registration is owned by another peer")]
    OwnershipConflict,
    #[error("endpoint belongs to another registration")]
    EndpointConflict,
    #[error("validation token is invalid")]
    ValidationFailed,
    #[error("validation token expired")]
    ValidationExpired,
    #[error("invalid registration state: {0}")]
    InvalidState(String),
    #[error("database task failed: {0}")]
    Task(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RegistrationState {
    Pending,
    Validated,
    Stale,
}

impl RegistrationState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Validated => "validated",
            Self::Stale => "stale",
        }
    }

    fn from_database(value: &str) -> Result<Self, RegistrationError> {
        match value {
            "pending" => Ok(Self::Pending),
            "validated" => Ok(Self::Validated),
            "stale" => Ok(Self::Stale),
            other => Err(RegistrationError::InvalidState(other.to_owned())),
        }
    }
}

#[derive(Clone)]
pub struct StoredRegistration {
    pub id: String,
    pub owner_peer_id: String,
    pub device_id: String,
    pub endpoint: String,
    pub p256dh: String,
    pub auth: String,
    pub temporary: bool,
    pub desired_peers: Vec<String>,
    pub completion_rooms: Vec<PushRoomFilter>,
    pub state: RegistrationState,
    pub validation_token_hash: Option<String>,
    pub validation_expires_at: Option<i64>,
    pub created_at: i64,
    pub updated_at: i64,
    pub last_successful_push_at: Option<i64>,
    pub last_terminal_error: Option<String>,
}

impl std::fmt::Debug for StoredRegistration {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("StoredRegistration")
            .field("id", &self.id)
            .field("owner_peer_id", &self.owner_peer_id)
            .field("device_id", &self.device_id)
            .field("temporary", &self.temporary)
            .field("desired_peers", &self.desired_peers)
            .field("completion_rooms", &self.completion_rooms)
            .field("state", &self.state)
            .field("updated_at", &self.updated_at)
            .field("last_terminal_error", &self.last_terminal_error)
            .finish_non_exhaustive()
    }
}

#[derive(Clone)]
pub struct RegistrationInput {
    pub id: String,
    pub owner_peer_id: String,
    pub device_id: String,
    pub endpoint: String,
    pub p256dh: String,
    pub auth: String,
    pub temporary: bool,
    pub desired_peers: Vec<String>,
    pub completion_rooms: Vec<PushRoomFilter>,
}

#[derive(Clone)]
pub struct PushRegistrationStore {
    mesh: Arc<MeshStore>,
}

impl PushRegistrationStore {
    pub fn new(mesh: Arc<MeshStore>) -> Self {
        Self { mesh }
    }

    pub fn get(&self, id: &str) -> Result<Option<StoredRegistration>, RegistrationError> {
        let conn = self.mesh.connection();
        query_by_id(&conn, id)
    }

    pub fn list_all(&self) -> Result<Vec<StoredRegistration>, RegistrationError> {
        let conn = self.mesh.connection();
        let sql = format!("SELECT {REGISTRATION_COLUMNS} FROM push_registrations");
        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map([], row_to_registration)?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// Atomically replaces a registration owned by the same app peer. Only a
    /// filter-only update of an already validated credential set preserves
    /// validation; new endpoints/keys and stale endpoints always revalidate.
    pub fn upsert(
        &self,
        input: &RegistrationInput,
        validation_token_hash: &str,
        validation_expires_at: i64,
        now: i64,
    ) -> Result<RegistrationState, RegistrationError> {
        let mut conn = self.mesh.connection();
        let tx = conn.transaction()?;
        let existing = query_by_id(&tx, &input.id)?;
        if let Some(current) = &existing
            && current.owner_peer_id != input.owner_peer_id
        {
            return Err(RegistrationError::OwnershipConflict);
        }

        let endpoint_owner: Option<String> = tx
            .query_row(
                "SELECT id FROM push_registrations WHERE endpoint = ?1",
                params![input.endpoint],
                |row| row.get(0),
            )
            .optional()?;
        if endpoint_owner.as_deref().is_some_and(|id| id != input.id) {
            return Err(RegistrationError::EndpointConflict);
        }

        let preserve_validation = existing.as_ref().is_some_and(|current| {
            current.state == RegistrationState::Validated
                && current.endpoint == input.endpoint
                && current.p256dh == input.p256dh
                && current.auth == input.auth
        });
        let state = if preserve_validation {
            RegistrationState::Validated
        } else {
            RegistrationState::Pending
        };
        let created_at = existing.as_ref().map_or(now, |current| current.created_at);
        let last_successful = existing
            .as_ref()
            .and_then(|current| current.last_successful_push_at);
        let last_error = if preserve_validation {
            existing
                .as_ref()
                .and_then(|current| current.last_terminal_error.clone())
        } else {
            None
        };
        let token_hash = (!preserve_validation).then_some(validation_token_hash);
        let expires_at = (!preserve_validation).then_some(validation_expires_at);

        tx.execute(
            "INSERT INTO push_registrations (
                id, owner_peer_id, device_id, endpoint, p256dh, auth, temporary,
                desired_peers, completion_rooms, state, validation_token_hash,
                validation_expires_at, created_at, updated_at,
                last_successful_push_at, last_terminal_error
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
             ON CONFLICT(id) DO UPDATE SET
                device_id = excluded.device_id,
                endpoint = excluded.endpoint,
                p256dh = excluded.p256dh,
                auth = excluded.auth,
                temporary = excluded.temporary,
                desired_peers = excluded.desired_peers,
                completion_rooms = excluded.completion_rooms,
                state = excluded.state,
                validation_token_hash = excluded.validation_token_hash,
                validation_expires_at = excluded.validation_expires_at,
                updated_at = excluded.updated_at,
                last_successful_push_at = excluded.last_successful_push_at,
                last_terminal_error = excluded.last_terminal_error",
            params![
                input.id,
                input.owner_peer_id,
                input.device_id,
                input.endpoint,
                input.p256dh,
                input.auth,
                input.temporary,
                serde_json::to_string(&input.desired_peers)?,
                serde_json::to_string(&input.completion_rooms)?,
                state.as_str(),
                token_hash,
                expires_at,
                created_at,
                now,
                last_successful,
                last_error,
            ],
        )?;
        tx.commit()?;
        Ok(state)
    }

    pub fn validate(
        &self,
        id: &str,
        owner_peer_id: &str,
        token_hash: &str,
        now: i64,
    ) -> Result<RegistrationState, RegistrationError> {
        let mut conn = self.mesh.connection();
        let tx = conn.transaction()?;
        let registration = query_by_id(&tx, id)?.ok_or(RegistrationError::NotFound)?;
        if registration.owner_peer_id != owner_peer_id {
            return Err(RegistrationError::NotFound);
        }
        if registration.state != RegistrationState::Pending {
            return Err(RegistrationError::ValidationFailed);
        }
        if registration
            .validation_expires_at
            .is_some_and(|expiry| expiry < now)
        {
            return Err(RegistrationError::ValidationExpired);
        }
        if registration.validation_token_hash.as_deref() != Some(token_hash) {
            return Err(RegistrationError::ValidationFailed);
        }
        tx.execute(
            "UPDATE push_registrations SET state = 'validated',
                validation_token_hash = NULL, validation_expires_at = NULL,
                updated_at = ?2, last_terminal_error = NULL WHERE id = ?1",
            params![id, now],
        )?;
        tx.commit()?;
        Ok(RegistrationState::Validated)
    }

    pub fn remove(&self, id: &str, owner_peer_id: &str) -> Result<bool, RegistrationError> {
        let conn = self.mesh.connection();
        let deleted = conn.execute(
            "DELETE FROM push_registrations WHERE id = ?1 AND owner_peer_id = ?2",
            params![id, owner_peer_id],
        )?;
        Ok(deleted > 0)
    }

    pub fn update_filters(
        &self,
        id: &str,
        desired_peers: &[String],
        completion_rooms: &[PushRoomFilter],
        now: i64,
    ) -> Result<(), RegistrationError> {
        let conn = self.mesh.connection();
        conn.execute(
            "UPDATE push_registrations SET desired_peers = ?2,
                completion_rooms = ?3, updated_at = ?4 WHERE id = ?1",
            params![
                id,
                serde_json::to_string(desired_peers)?,
                serde_json::to_string(completion_rooms)?,
                now
            ],
        )?;
        Ok(())
    }

    pub fn mark_success(&self, id: &str, now: i64) -> Result<(), RegistrationError> {
        let conn = self.mesh.connection();
        conn.execute(
            "UPDATE push_registrations SET last_successful_push_at = ?2,
                last_terminal_error = NULL, updated_at = ?2 WHERE id = ?1",
            params![id, now],
        )?;
        Ok(())
    }

    pub fn mark_error(&self, id: &str, code: &str, now: i64) -> Result<(), RegistrationError> {
        let conn = self.mesh.connection();
        conn.execute(
            "UPDATE push_registrations SET last_terminal_error = ?2,
                updated_at = ?3 WHERE id = ?1",
            params![id, code, now],
        )?;
        Ok(())
    }

    pub fn mark_stale(&self, id: &str, code: &str, now: i64) -> Result<(), RegistrationError> {
        let conn = self.mesh.connection();
        conn.execute(
            "UPDATE push_registrations SET state = 'stale',
                validation_token_hash = NULL, validation_expires_at = NULL,
                last_terminal_error = ?2, updated_at = ?3 WHERE id = ?1",
            params![id, code, now],
        )?;
        Ok(())
    }
}

fn query_by_id(
    conn: &Connection,
    id: &str,
) -> Result<Option<StoredRegistration>, RegistrationError> {
    let sql = format!("SELECT {REGISTRATION_COLUMNS} FROM push_registrations WHERE id = ?1");
    let row = conn
        .query_row(&sql, params![id], row_to_registration)
        .optional()?;
    Ok(row)
}

fn row_to_registration(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoredRegistration> {
    let state: String = row.get(9)?;
    Ok(StoredRegistration {
        id: row.get(0)?,
        owner_peer_id: row.get(1)?,
        device_id: row.get(2)?,
        endpoint: row.get(3)?,
        p256dh: row.get(4)?,
        auth: row.get(5)?,
        temporary: row.get::<_, i64>(6)? != 0,
        desired_peers: parse_json(row, 7)?,
        completion_rooms: parse_json(row, 8)?,
        state: RegistrationState::from_database(&state).map_err(|error| {
            rusqlite::Error::FromSqlConversionFailure(
                9,
                rusqlite::types::Type::Text,
                Box::new(error),
            )
        })?,
        validation_token_hash: row.get(10)?,
        validation_expires_at: row.get(11)?,
        created_at: row.get(12)?,
        updated_at: row.get(13)?,
        last_successful_push_at: row.get(14)?,
        last_terminal_error: row.get(15)?,
    })
}

fn parse_json<T: serde::de::DeserializeOwned>(
    row: &rusqlite::Row<'_>,
    index: usize,
) -> rusqlite::Result<T> {
    let raw: String = row.get(index)?;
    serde_json::from_str(&raw).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(
            index,
            rusqlite::types::Type::Text,
            Box::new(error),
        )
    })
}
