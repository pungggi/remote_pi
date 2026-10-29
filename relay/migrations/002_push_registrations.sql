-- Plan 153: UnifiedPush/Web Push registrations owned by an authenticated app peer.
-- Secrets are required for Web Push encryption, but must never appear in logs.

CREATE TABLE IF NOT EXISTS push_registrations (
    id                      TEXT PRIMARY KEY,
    owner_peer_id           TEXT NOT NULL,
    device_id               TEXT NOT NULL,
    endpoint                TEXT NOT NULL UNIQUE,
    p256dh                  TEXT NOT NULL,
    auth                    TEXT NOT NULL,
    temporary               INTEGER NOT NULL DEFAULT 0,
    desired_peers           TEXT NOT NULL,
    completion_rooms        TEXT NOT NULL,
    state                   TEXT NOT NULL CHECK (state IN ('pending', 'validated', 'stale')),
    validation_token_hash   TEXT,
    validation_expires_at   INTEGER,
    created_at              INTEGER NOT NULL,
    updated_at              INTEGER NOT NULL,
    last_successful_push_at INTEGER,
    last_terminal_error     TEXT
);

CREATE INDEX IF NOT EXISTS push_registrations_owner_idx
    ON push_registrations(owner_peer_id);

CREATE INDEX IF NOT EXISTS push_registrations_state_idx
    ON push_registrations(state);
