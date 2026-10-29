use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use reqwest::header::{CONTENT_ENCODING, CONTENT_TYPE, HeaderName, HeaderValue};
use reqwest::{StatusCode, Url};
use web_push::{
    ContentEncoding, SubscriptionInfo, Urgency, VapidSignatureBuilder, WebPushMessage,
    WebPushMessageBuilder,
};

use super::config::{EndpointPolicy, VapidKeyMaterial};
use super::events::{PushEvent, PushEventKind};
use super::registration::StoredRegistration;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PushSendFailureKind {
    Transient,
    Stale,
    Terminal,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushSendError {
    pub kind: PushSendFailureKind,
    pub code: &'static str,
}

impl PushSendError {
    pub fn transient(code: &'static str) -> Self {
        Self {
            kind: PushSendFailureKind::Transient,
            code,
        }
    }

    pub fn stale(code: &'static str) -> Self {
        Self {
            kind: PushSendFailureKind::Stale,
            code,
        }
    }

    pub fn terminal(code: &'static str) -> Self {
        Self {
            kind: PushSendFailureKind::Terminal,
            code,
        }
    }
}

impl std::fmt::Display for PushSendError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.code)
    }
}

impl std::error::Error for PushSendError {}

#[async_trait::async_trait]
pub trait PushTransport: Send + Sync {
    async fn send(
        &self,
        registration: &StoredRegistration,
        event: &PushEvent,
        payload: &[u8],
    ) -> Result<(), PushSendError>;
}

pub struct ReqwestWebPush {
    vapid: Arc<VapidKeyMaterial>,
    policy: EndpointPolicy,
    request_timeout: Duration,
}

impl std::fmt::Debug for ReqwestWebPush {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ReqwestWebPush")
            .field("request_timeout", &self.request_timeout)
            .finish_non_exhaustive()
    }
}

impl ReqwestWebPush {
    pub fn new(vapid: Arc<VapidKeyMaterial>, policy: EndpointPolicy) -> Self {
        Self {
            vapid,
            policy,
            request_timeout: Duration::from_secs(10),
        }
    }

    #[cfg(test)]
    fn with_timeout(mut self, timeout: Duration) -> Self {
        self.request_timeout = timeout;
        self
    }

    fn build_message(
        &self,
        registration: &StoredRegistration,
        event: &PushEvent,
        payload: &[u8],
    ) -> Result<WebPushMessage, PushSendError> {
        let subscription = SubscriptionInfo::new(
            registration.endpoint.clone(),
            registration.p256dh.clone(),
            registration.auth.clone(),
        );
        let signature =
            VapidSignatureBuilder::from_pem(self.vapid.private_key_pem().as_bytes(), &subscription)
                .and_then(|builder| builder.build())
                .map_err(|_| PushSendError::terminal("vapid_signature_failed"))?;
        let mut builder = WebPushMessageBuilder::new(&subscription);
        builder.set_payload(ContentEncoding::Aes128Gcm, payload);
        builder.set_vapid_signature(signature);
        builder.set_ttl(300);
        builder.set_urgency(match event.kind {
            PushEventKind::RunStarted | PushEventKind::WaitingStarted => Urgency::High,
            _ => Urgency::Normal,
        });
        builder.build().map_err(|error| {
            PushSendError::terminal(match error.short_description() {
                "invalid_crypto_keys" => "invalid_crypto_keys",
                _ => "invalid_push_message",
            })
        })
    }

    async fn resolve(&self, endpoint: &str) -> Result<ResolvedEndpoint, PushSendError> {
        resolve_endpoint(&self.policy, endpoint).await
    }
}

#[async_trait::async_trait]
impl PushTransport for ReqwestWebPush {
    async fn send(
        &self,
        registration: &StoredRegistration,
        event: &PushEvent,
        payload: &[u8],
    ) -> Result<(), PushSendError> {
        let message = self.build_message(registration, event, payload)?;
        let resolved = self.resolve(&registration.endpoint).await?;
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .timeout(self.request_timeout)
            .resolve_to_addrs(&resolved.host, &resolved.addresses)
            .build()
            .map_err(|_| PushSendError::terminal("http_client_failed"))?;

        let WebPushMessage {
            endpoint: _,
            ttl,
            urgency,
            topic,
            payload,
        } = message;
        let mut request = client
            .post(resolved.url)
            .header("TTL", ttl.to_string())
            .timeout(self.request_timeout);
        if let Some(urgency) = urgency {
            request = request.header("Urgency", urgency.to_string());
        }
        if let Some(topic) = topic {
            request = request.header("Topic", topic);
        }
        if let Some(payload) = payload {
            request = request
                .header(CONTENT_ENCODING, payload.content_encoding.to_str())
                .header(CONTENT_TYPE, "application/octet-stream");
            for (name, value) in payload.crypto_headers {
                let name = HeaderName::from_bytes(name.as_bytes())
                    .map_err(|_| PushSendError::terminal("invalid_push_header"))?;
                let value = HeaderValue::from_str(&value)
                    .map_err(|_| PushSendError::terminal("invalid_push_header"))?;
                request = request.header(name, value);
            }
            request = request.body(payload.content);
        } else {
            request = request.body(Vec::new());
        }

        let response = request
            .send()
            .await
            .map_err(|_| PushSendError::transient("network_error"))?;
        match response.status() {
            status if status.is_success() => Ok(()),
            StatusCode::NOT_FOUND => Err(PushSendError::stale("endpoint_not_found")),
            StatusCode::GONE => Err(PushSendError::stale("endpoint_gone")),
            StatusCode::TOO_MANY_REQUESTS => Err(PushSendError::transient("rate_limited")),
            status if status.is_server_error() => {
                Err(PushSendError::transient("push_server_error"))
            }
            status if status.is_redirection() => Err(PushSendError::terminal("redirect_rejected")),
            _ => Err(PushSendError::terminal("push_rejected")),
        }
    }
}

#[derive(Debug)]
pub struct ResolvedEndpoint {
    pub url: Url,
    pub host: String,
    pub addresses: Vec<SocketAddr>,
}

pub async fn resolve_endpoint(
    policy: &EndpointPolicy,
    endpoint: &str,
) -> Result<ResolvedEndpoint, PushSendError> {
    let url = parse_endpoint_url(endpoint)?;
    let host = url
        .host_str()
        .map(|host| {
            host.trim_start_matches('[')
                .trim_end_matches(']')
                .to_owned()
        })
        .ok_or_else(|| PushSendError::terminal("invalid_endpoint"))?;
    let port = url
        .port_or_known_default()
        .ok_or_else(|| PushSendError::terminal("invalid_endpoint"))?;
    let addresses = if let Ok(ip) = host.parse::<IpAddr>() {
        vec![SocketAddr::new(ip, port)]
    } else {
        tokio::net::lookup_host((host.as_str(), port))
            .await
            .map_err(|_| PushSendError::transient("dns_error"))?
            .collect::<Vec<_>>()
    };
    validate_resolved_addresses(policy, &host, &addresses)?;
    Ok(ResolvedEndpoint {
        url,
        host,
        addresses,
    })
}

pub fn parse_endpoint_url(endpoint: &str) -> Result<Url, PushSendError> {
    let url = Url::parse(endpoint).map_err(|_| PushSendError::terminal("invalid_endpoint"))?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
    {
        return Err(PushSendError::terminal("invalid_endpoint"));
    }
    Ok(url)
}

pub fn validate_resolved_addresses(
    policy: &EndpointPolicy,
    host: &str,
    addresses: &[SocketAddr],
) -> Result<(), PushSendError> {
    if addresses.is_empty() {
        return Err(PushSendError::transient("dns_error"));
    }
    let host_allowlisted = policy.host_is_allowlisted(host);
    for address in addresses {
        let ip = address.ip();
        if is_never_routable(ip) {
            return Err(PushSendError::terminal("endpoint_not_allowed"));
        }
        if !host_allowlisted && !is_global(ip) && !policy.ip_is_allowlisted(ip) {
            return Err(PushSendError::terminal("endpoint_not_allowed"));
        }
    }
    Ok(())
}

fn is_never_routable(ip: IpAddr) -> bool {
    ip.is_unspecified() || ip.is_multicast() || matches!(ip, IpAddr::V4(v4) if v4.is_broadcast())
}

fn is_global(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => ipv4_is_global(ip),
        IpAddr::V6(ip) => ipv6_is_global(ip),
    }
}

// Mirrors std's currently-unstable `is_global` classification, including
// IANA special-purpose ranges. Keeping the complete rules here avoids
// accidentally treating a non-global assignment as a public push destination.
fn ipv4_is_global(ip: Ipv4Addr) -> bool {
    let [a, b, c, d] = ip.octets();
    !(a == 0
        || a == 10
        || a == 127
        || (a == 100 && (64..=127).contains(&b))
        || (a == 169 && b == 254)
        || (a == 172 && (16..=31).contains(&b))
        || (a == 192 && b == 168)
        || (a == 192 && b == 0 && c == 0 && d != 9 && d != 10)
        || (a == 192 && b == 0 && c == 2)
        || (a == 198 && (b == 18 || b == 19))
        || (a == 198 && b == 51 && c == 100)
        || (a == 203 && b == 0 && c == 113)
        || a >= 240)
}

fn ipv6_is_global(ip: Ipv6Addr) -> bool {
    if ip.is_loopback()
        || ip.is_unspecified()
        || ip.is_unique_local()
        || ip.is_unicast_link_local()
        || ip.to_ipv4_mapped().is_some()
    {
        return false;
    }
    let segments = ip.segments();
    let integer = u128::from_be_bytes(ip.octets());
    let ietf_protocol_assignment = segments[0] == 0x2001
        && segments[1] < 0x200
        && !(integer == 0x2001_0001_0000_0000_0000_0000_0000_0001
            || integer == 0x2001_0001_0000_0000_0000_0000_0000_0002
            || segments[1] == 3
            || (segments[1] == 4 && segments[2] == 0x112)
            || (0x20..=0x3f).contains(&segments[1]));
    !(ietf_protocol_assignment
        || (segments[0] == 0x64 && segments[1] == 0xff9b && segments[2] == 1)
        || (segments[0] == 0x100 && segments[1..4].iter().all(|segment| *segment == 0))
        || (segments[0] == 0x2001 && segments[1] == 0x0db8)
        || segments[0] == 0x2002
        || segments[0] == 0x5f00)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn socket(ip: &str) -> SocketAddr {
        SocketAddr::new(ip.parse().unwrap(), 443)
    }

    #[test]
    fn rejects_non_global_and_allows_explicit_private_targets() {
        let default_policy = EndpointPolicy::default();
        for ip in [
            "127.0.0.1",
            "10.0.0.2",
            "169.254.1.1",
            "::1",
            "fc00::1",
            "fe80::1",
        ] {
            assert!(
                validate_resolved_addresses(&default_policy, "push.test", &[socket(ip)]).is_err(),
                "{ip}"
            );
        }
        assert!(
            validate_resolved_addresses(&default_policy, "push.test", &[socket("93.184.216.34")])
                .is_ok()
        );
        assert!(
            validate_resolved_addresses(&default_policy, "push.test", &[socket("192.0.0.9")])
                .is_ok()
        );
        assert!(
            validate_resolved_addresses(&default_policy, "push.test", &[socket("2001:1::1")])
                .is_ok()
        );
        for ip in [
            "64:ff9b:1::1",
            "2001:2::1",
            "2002::1",
            "5f00::1",
            "::ffff:8.8.8.8",
        ] {
            assert!(
                validate_resolved_addresses(&default_policy, "push.test", &[socket(ip)]).is_err(),
                "{ip}"
            );
        }

        let private = EndpointPolicy::parse(Some("push.lan,100.64.0.0/10")).unwrap();
        assert!(validate_resolved_addresses(&private, "push.lan", &[socket("127.0.0.1")]).is_ok());
        assert!(
            validate_resolved_addresses(&private, "100.64.0.2", &[socket("100.64.0.2")]).is_ok()
        );
        assert!(
            validate_resolved_addresses(&default_policy, "push.test", &[socket("0.0.0.0")])
                .is_err()
        );
        assert!(validate_resolved_addresses(&private, "push.lan", &[socket("224.0.0.1")]).is_err());
    }

    #[test]
    fn endpoint_requires_clean_https_url() {
        assert!(parse_endpoint_url("https://push.example/path").is_ok());
        for endpoint in [
            "http://push.example/path",
            "https://user:pass@push.example/path",
            "https://push.example/path#fragment",
            "not a URL",
        ] {
            assert!(parse_endpoint_url(endpoint).is_err(), "{endpoint}");
        }
    }

    #[test]
    fn library_builds_aes128gcm_message() {
        let vapid = Arc::new(VapidKeyMaterial::generate().unwrap());
        let sender = ReqwestWebPush::new(vapid, EndpointPolicy::default())
            .with_timeout(Duration::from_secs(1));
        let registration = StoredRegistration {
            id: "r".into(), owner_peer_id: "o".into(), device_id: "d".into(),
            endpoint: "https://push.example/endpoint".into(),
            p256dh: "BLMbF9ffKBiWQLCKvTHb6LO8Nb6dcUh6TItC455vu2kElga6PQvUmaFyCdykxY2nOSSL3yKgfbmFLRTUaGv4yV8".into(),
            auth: "xS03Fi5ErfTNH_l9WHE9Ig".into(), temporary: false,
            desired_peers: vec![], completion_rooms: vec![], state: super::super::registration::RegistrationState::Validated,
            validation_token_hash: None, validation_expires_at: None, created_at: 0, updated_at: 0,
            last_successful_push_at: None, last_terminal_error: None,
        };
        let event = PushEvent::transition(PushEventKind::RunStarted, "peer", "room", 1);
        let message = sender
            .build_message(&registration, &event, br#"{"v":1}"#)
            .unwrap();
        assert_eq!(message.urgency, Some(Urgency::High));
        assert_eq!(
            message.payload.unwrap().content_encoding,
            ContentEncoding::Aes128Gcm
        );
    }
}
