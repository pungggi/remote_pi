//! PR #24 review follow-up (#6) — subscription re-validation.
//!
//! Presence/rooms subscriptions are authorized once, at subscribe time; mesh
//! membership can be revoked later. `prune_unauthorized_subscriptions`
//! re-checks every stored (target, subscriber) pair against current mesh
//! membership and prunes the stale ones, so a revoked peer stops receiving
//! the target's presence/room metadata — matching how `pi_envelope`
//! forwarding behaves (TTL-cached authorization).
//!
//! These tests drive the managers directly (no WS): write an owner blob
//! making A and B siblings, subscribe B→A, then bump the owner blob to drop
//! B and verify the sweep prunes the pair. A zero-TTL `MeshAuthCache`
//! bypasses the 60 s positive cache so revocation is observed immediately.

mod common;

use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
use ed25519_dalek::Signer;
use relay::prune_unauthorized_subscriptions;

fn pk_b64(key: &ed25519_dalek::SigningKey) -> String {
    B64.encode(key.verifying_key().to_bytes())
}

async fn publish_owner_blob(port: u16, owner: &ed25519_dalek::SigningKey, members: &[String], version: u64) {
    let owner_pk = pk_b64(owner);
    let blob = serde_json::json!({
        "issued_at": 1_700_000_000_000_u64,
        "version": version,
        "owner_pk": owner_pk,
        "members": members.iter().map(|epk| serde_json::json!({
            "remote_epk": epk,
            "relay_url": "wss://relay.example.test",
            "paired_at": "2025-01-01T00:00:00.000Z",
        })).collect::<Vec<_>>(),
    });
    let blob_bytes = serde_json::to_vec(&blob).unwrap();
    let sig = owner.sign(&blob_bytes);
    let envelope = serde_json::json!({
        "blob": B64.encode(&blob_bytes),
        "sig": B64.encode(sig.to_bytes()),
    });
    use sha2::{Digest, Sha256};
    let hash = Sha256::digest(owner.verifying_key().to_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    let url = format!("http://127.0.0.1:{port}/mesh/{hash}");
    let resp = reqwest::Client::new().post(&url).json(&envelope).send().await.unwrap();
    assert!(resp.status().is_success(), "blob publish failed: {}", resp.status());
}

async fn test_state() -> relay::AppState {
    let (_port, state) = common::start_relay_with_state().await;
    state
}

#[tokio::test]
async fn revocation_prunes_presence_and_rooms_subscriptions() {
    let (port, state) = common::start_relay_with_state().await;

    let owner = ed25519_dalek::SigningKey::generate(&mut rand::thread_rng());
    let a = pk_b64(&ed25519_dalek::SigningKey::generate(&mut rand::thread_rng()));
    let b = pk_b64(&ed25519_dalek::SigningKey::generate(&mut rand::thread_rng()));

    publish_owner_blob(port, &owner, &[a.clone(), b.clone()], 1).await;

    // B subscribes to A's presence and rooms (authorized at subscribe time).
    state.presence.subscribe(b.clone(), vec![a.clone()]).await;
    state.rooms.subscribe(b.clone(), vec![a.clone()]).await;

    // Still siblings → sweep prunes nothing.
    assert_eq!(prune_unauthorized_subscriptions(&state).await, 0);
    assert_eq!(state.presence.subscribers_of(&a).await, vec![b.clone()]);

    // Owner revokes B (version bump, B removed from the member list).
    publish_owner_blob(port, &owner, std::slice::from_ref(&a), 2).await;
    // MeshAuthCache holds the pre-revocation positive for its TTL (60 s in
    // production); simulate expiry so the sweep observes the new blob now.
    state.mesh_auth.clear();

    // Sweep now prunes both the presence and the rooms subscription.
    let pruned = prune_unauthorized_subscriptions(&state).await;
    assert_eq!(pruned, 2, "presence + rooms pairs must be pruned");
    assert!(state.presence.subscribers_of(&a).await.is_empty());
    assert!(state.rooms.subscribers_of(&a).await.is_empty());

    // Idempotent: a second sweep finds nothing.
    assert_eq!(prune_unauthorized_subscriptions(&state).await, 0);
}

#[tokio::test]
async fn self_subscription_survives_the_sweep() {
    let state = test_state().await;

    // A subscribes to itself with NO mesh blob at all — self-watch is always
    // allowed and must never be pruned.
    let a = pk_b64(&ed25519_dalek::SigningKey::generate(&mut rand::thread_rng()));
    state.presence.subscribe(a.clone(), vec![a.clone()]).await;

    assert_eq!(prune_unauthorized_subscriptions(&state).await, 0);
    assert_eq!(state.presence.subscribers_of(&a).await.len(), 1);
}
