mod common;
use common::{connect_and_auth, connect_and_auth_with_room, start_relay};

use ed25519_dalek::Signer;
use ed25519_dalek::SigningKey;
use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use tokio_tungstenite::tungstenite::Message;

fn random_key() -> SigningKey {
    SigningKey::generate(&mut rand::thread_rng())
}

/// Security fix 2026-08 — the outer envelope's optional `sig` (sender's
/// end-to-end Ed25519 signature over `ct`) must be forwarded VERBATIM. The
/// relay cannot forge it and must not strip it — recipients rely on it to
/// authenticate the sender independently of the relay.
#[tokio::test]
async fn envelope_sig_is_forwarded_verbatim() {
    let port = start_relay().await;
    let (mut ws_a, peer_a) = connect_and_auth(port).await;
    let (mut ws_b, peer_b) = connect_and_auth(port).await;

    // `sig` is any opaque-to-the-relay string here — we only assert
    // passthrough, not validity.
    let ct = "aGVsbG8=";
    let sig = "U0lHMDAwMDA=";
    ws_a.send(Message::text(
        json!({"peer": peer_b, "ct": ct, "sig": sig}).to_string(),
    ))
    .await
    .unwrap();

    let received = tokio::time::timeout(tokio::time::Duration::from_secs(1), ws_b.next())
        .await
        .expect("timed out waiting for forwarded message")
        .unwrap()
        .unwrap();
    let v: serde_json::Value = serde_json::from_str(received.to_text().unwrap()).unwrap();
    assert_eq!(v["peer"], peer_a);
    assert_eq!(v["ct"], ct);
    assert_eq!(v["sig"], sig, "sig must be forwarded verbatim");

    // ...and the legacy unsigned shape still round-trips without a `sig`
    // field (back-compat on the wire).
    ws_a.send(Message::text(
        json!({"peer": peer_b, "ct": ct}).to_string(),
    ))
    .await
    .unwrap();
    let received2 = tokio::time::timeout(tokio::time::Duration::from_secs(1), ws_b.next())
        .await
        .expect("timed out waiting for second forwarded message")
        .unwrap()
        .unwrap();
    let v2: serde_json::Value = serde_json::from_str(received2.to_text().unwrap()).unwrap();
    assert!(v2.get("sig").is_none(), "unsigned frames stay unsigned");
}

/// Security fix 2026-08 — a WS text frame larger than the message cap must
/// be rejected by the WS layer instead of parsed + forwarded (~64 MiB was
/// the previous implicit ceiling).
#[tokio::test]
async fn oversized_ws_message_is_rejected() {
    use relay::handlers::peer::MAX_WS_MESSAGE_BYTES;

    let port = start_relay().await;
    let url = format!("ws://127.0.0.1:{port}");
    let (mut ws, _) = tokio_tungstenite::connect_async(&url).await.unwrap();

    use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
    let sk = ed25519_dalek::SigningKey::generate(&mut rand::thread_rng());
    ws.send(Message::text(
        json!({"type": "hello", "pubkey": B64.encode(sk.verifying_key().to_bytes())})
            .to_string(),
    ))
    .await
    .unwrap();
    let challenge: serde_json::Value =
        serde_json::from_str(ws.next().await.unwrap().unwrap().to_text().unwrap()).unwrap();
    let nonce: [u8; 32] = B64
        .decode(challenge["nonce"].as_str().unwrap())
        .unwrap()
        .try_into()
        .unwrap();
    ws.send(Message::text(
        json!({"type": "auth", "sig": B64.encode(sk.sign(&nonce).to_bytes())}).to_string(),
    ))
    .await
    .unwrap();

    // A frame above the cap → tungstenite should error/close the stream.
    let oversized = format!("{{\"peer\":\"x\",\"ct\":\"{}\"}}", "A".repeat(MAX_WS_MESSAGE_BYTES));
    let send_result = ws.send(Message::text(oversized)).await;
    let closed = send_result.is_err()
        || tokio::time::timeout(tokio::time::Duration::from_millis(500), ws.next())
            .await
            .map(|next| matches!(next, None | Some(Err(_)) | Some(Ok(Message::Close(_)))))
            .unwrap_or(true);
    assert!(closed, "oversized frame must terminate the connection");
}

/// Peer A sends an OuterEnvelope addressed to peer B.
/// B receives a rewritten envelope where outer.peer = A (the sender),
/// not B (the original dest) — per protocol.md semantics.
#[tokio::test]
async fn two_peers_route_message() {
    let port = start_relay().await;
    let (mut ws_a, peer_a) = connect_and_auth(port).await;
    let (mut ws_b, peer_b) = connect_and_auth(port).await;

    let ct = "aGVsbG8="; // "hello" in base64, never decoded by relay
    // A sends: peer = dest (peer_b)
    ws_a.send(Message::text(json!({"peer": peer_b, "ct": ct}).to_string()))
        .await
        .unwrap();

    let received = tokio::time::timeout(tokio::time::Duration::from_secs(1), ws_b.next())
        .await
        .expect("timed out waiting for forwarded message")
        .unwrap()
        .unwrap();

    // B receives: peer = sender (peer_a), ct unchanged
    let received_json: serde_json::Value =
        serde_json::from_str(received.to_text().unwrap()).unwrap();
    assert_eq!(
        received_json["peer"], peer_a,
        "relay must rewrite peer to sender id"
    );
    assert_eq!(received_json["ct"], ct, "ct must be forwarded unchanged");
}

/// Plan/137 — sending to an unknown destination NACKs the sender with a
/// rate-limited `route_error` control frame (identifies the destination,
/// since the envelope body is opaque); duplicates within the TTL window are
/// suppressed. The connection stays alive.
#[tokio::test]
async fn dest_offline_nacks_with_route_error_then_rate_limits() {
    let port = start_relay().await;
    let (mut ws_a, _) = connect_and_auth(port).await;

    let dest = "bm9uZXhpc3RlbnRwZWVy";
    ws_a
        .send(Message::text(
            json!({"peer": dest, "room": "deadroom", "ct": "aGVsbG8="}).to_string(),
        ))
        .await
        .unwrap();

    let nack = tokio::time::timeout(tokio::time::Duration::from_secs(1), ws_a.next())
        .await
        .expect("timed out waiting for route_error")
        .unwrap()
        .unwrap();
    let v: serde_json::Value = serde_json::from_str(nack.to_text().unwrap()).unwrap();
    assert_eq!(v["type"], "route_error", "got: {v}");
    assert_eq!(v["peer"], dest);
    assert_eq!(v["room"], "deadroom");

    // Same destination again inside the 5 s window → suppressed (silence,
    // not a duplicate NACK).
    ws_a
        .send(Message::text(
            json!({"peer": dest, "room": "deadroom", "ct": "aGVsbG8="}).to_string(),
        ))
        .await
        .unwrap();
    let result =
        tokio::time::timeout(tokio::time::Duration::from_millis(200), ws_a.next()).await;
    assert!(
        result.is_err(),
        "expected no duplicate route_error within the TTL, got {:?}",
        result
    );

    // A DIFFERENT dead destination is not suppressed by the first NACK.
    ws_a
        .send(Message::text(
            json!({"peer": dest, "room": "otherroom", "ct": "aGVsbG8="}).to_string(),
        ))
        .await
        .unwrap();
    let nack2 = tokio::time::timeout(tokio::time::Duration::from_secs(1), ws_a.next())
        .await
        .expect("timed out waiting for second route_error (different room)")
        .unwrap()
        .unwrap();
    let v2: serde_json::Value = serde_json::from_str(nack2.to_text().unwrap()).unwrap();
    assert_eq!(v2["type"], "route_error");
    assert_eq!(v2["room"], "otherroom");
}

/// A successful forward must NOT produce a route_error for that destination
/// (the NACK is purely a failure signal, never a delivery receipt).
#[tokio::test]
async fn successful_forward_never_nacks() {
    let port = start_relay().await;
    let (mut ws_a, _) = connect_and_auth(port).await;
    let (mut ws_b, peer_b) = connect_and_auth_with_room(port, &random_key(), "alive").await;

    ws_a
        .send(Message::text(
            json!({"peer": peer_b, "room": "alive", "ct": "aGVsbG8="}).to_string(),
        ))
        .await
        .unwrap();

    let received = tokio::time::timeout(tokio::time::Duration::from_secs(1), ws_b.next())
        .await
        .expect("timed out waiting for forwarded message")
        .unwrap()
        .unwrap();
    let v: serde_json::Value = serde_json::from_str(received.to_text().unwrap()).unwrap();
    assert_eq!(v["ct"], "aGVsbG8=");

    let result =
        tokio::time::timeout(tokio::time::Duration::from_millis(200), ws_a.next()).await;
    assert!(
        result.is_err(),
        "sender must not receive anything on success, got {:?}",
        result
    );
}

/// A client that sends an invalid signature must have its WS closed within 100 ms.
#[tokio::test]
async fn invalid_sig_closes_ws() {
    let port = start_relay().await;
    let url = format!("ws://127.0.0.1:{port}");
    let (mut ws, _) = tokio_tungstenite::connect_async(&url).await.unwrap();

    use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
    use ed25519_dalek::SigningKey;
    let sk = SigningKey::generate(&mut rand::thread_rng());
    let vk = sk.verifying_key();

    // send hello
    ws.send(Message::text(
        json!({"type": "hello", "pubkey": B64.encode(vk.to_bytes())}).to_string(),
    ))
    .await
    .unwrap();

    // receive and ignore challenge (we won't sign correctly)
    let challenge_msg = ws.next().await.unwrap().unwrap();
    let v: serde_json::Value = serde_json::from_str(challenge_msg.to_text().unwrap()).unwrap();
    assert_eq!(v["type"], "challenge");

    // send all-zero signature (invalid)
    ws.send(Message::text(
        json!({"type": "auth", "sig": B64.encode([0u8; 64])}).to_string(),
    ))
    .await
    .unwrap();

    // relay must close within 100 ms
    let close_result =
        tokio::time::timeout(tokio::time::Duration::from_millis(100), ws.next()).await;

    assert!(
        close_result.is_ok(),
        "relay did not close the connection within 100 ms"
    );
    match close_result.unwrap() {
        None | Some(Ok(Message::Close(_))) | Some(Err(_)) => {} // all acceptable
        Some(Ok(other)) => panic!("unexpected message after bad auth: {other:?}"),
    }
}

/// Security fix 2026-08 — a client that completes `hello` but never sends
/// `auth` must be closed after the auth timeout instead of lingering
/// indefinitely.
#[tokio::test]
async fn auth_timeout_closes_half_handshake() {
    let port = start_relay().await;
    let url = format!("ws://127.0.0.1:{port}");
    let (mut ws, _) = tokio_tungstenite::connect_async(&url).await.unwrap();

    use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
    let sk = ed25519_dalek::SigningKey::generate(&mut rand::thread_rng());
    ws.send(Message::text(
        json!({"type": "hello", "pubkey": B64.encode(sk.verifying_key().to_bytes())})
            .to_string(),
    ))
    .await
    .unwrap();
    let challenge_msg = ws.next().await.unwrap().unwrap();
    let v: serde_json::Value = serde_json::from_str(challenge_msg.to_text().unwrap()).unwrap();
    assert_eq!(v["type"], "challenge");

    // ...and then silence. AUTH_TIMEOUT_MS is 5 s; close must arrive well
    // within 8 s.
    let closed = tokio::time::timeout(std::time::Duration::from_secs(8), ws.next()).await;
    assert!(
        closed.is_ok(),
        "relay must close the connection after the auth timeout"
    );
}
