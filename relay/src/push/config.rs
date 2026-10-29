use std::collections::HashSet;
use std::io::Write;
use std::net::IpAddr;
use std::path::Path;

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use ipnet::IpNet;
use openssl::bn::BigNumContext;
use openssl::ec::{EcGroup, EcKey, PointConversionForm};
use openssl::nid::Nid;

#[derive(Debug, thiserror::Error)]
pub enum PushConfigError {
    #[error("I/O: {0}")]
    Io(#[from] std::io::Error),
    #[error("OpenSSL: {0}")]
    OpenSsl(#[from] openssl::error::ErrorStack),
    #[error("invalid endpoint allowlist entry: {0}")]
    InvalidAllowlistEntry(String),
    #[error("invalid VAPID key: {0}")]
    InvalidKey(&'static str),
}

/// Long-lived VAPID identity. The private PEM is never exposed through Debug.
#[derive(Clone)]
pub struct VapidKeyMaterial {
    private_key_pem: String,
    public_key_base64: String,
}

impl std::fmt::Debug for VapidKeyMaterial {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VapidKeyMaterial").finish_non_exhaustive()
    }
}

impl VapidKeyMaterial {
    pub fn generate() -> Result<Self, PushConfigError> {
        let group = EcGroup::from_curve_name(Nid::X9_62_PRIME256V1)?;
        let key = EcKey::generate(&group)?;
        Self::from_openssl_key(&key, &group)
    }

    pub fn from_pem(pem: &str) -> Result<Self, PushConfigError> {
        let key = EcKey::private_key_from_pem(pem.as_bytes())?;
        let group = EcGroup::from_curve_name(Nid::X9_62_PRIME256V1)?;
        Self::from_openssl_key(&key, &group)
    }

    fn from_openssl_key(
        key: &EcKey<openssl::pkey::Private>,
        group: &EcGroup,
    ) -> Result<Self, PushConfigError> {
        key.check_key()?;
        let mut context = BigNumContext::new()?;
        let public_bytes =
            key.public_key()
                .to_bytes(group, PointConversionForm::UNCOMPRESSED, &mut context)?;
        if public_bytes.len() != 65 || public_bytes.first() != Some(&4) {
            return Err(PushConfigError::InvalidKey(
                "invalid P-256 public key encoding",
            ));
        }
        let private_key_pem = String::from_utf8(key.private_key_to_pem()?).map_err(|error| {
            PushConfigError::Io(std::io::Error::new(std::io::ErrorKind::InvalidData, error))
        })?;
        Ok(Self {
            private_key_pem,
            public_key_base64: URL_SAFE_NO_PAD.encode(public_bytes),
        })
    }

    /// Loads a stable identity or creates it with user-only permissions on
    /// Unix. A replacement key can invalidate distributor registrations, so
    /// an existing file is never overwritten automatically.
    pub fn load_or_create(path: impl AsRef<Path>) -> Result<Self, PushConfigError> {
        let path = path.as_ref();
        if path.exists() {
            return Self::from_pem(&std::fs::read_to_string(path)?);
        }
        if let Some(parent) = path.parent()
            && !parent.as_os_str().is_empty()
        {
            std::fs::create_dir_all(parent)?;
        }

        let material = Self::generate()?;
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        match options.open(path) {
            Ok(mut file) => {
                file.write_all(material.private_key_pem.as_bytes())?;
                file.sync_all()?;
                Ok(material)
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                Self::from_pem(&std::fs::read_to_string(path)?)
            }
            Err(error) => Err(error.into()),
        }
    }

    pub fn public_key_base64(&self) -> &str {
        &self.public_key_base64
    }

    pub(crate) fn private_key_pem(&self) -> &str {
        &self.private_key_pem
    }
}

/// Exact domain and IP/CIDR exceptions for private self-hosted push servers.
/// Entries come from REMOTEPI_PUSH_ENDPOINT_ALLOWLIST, comma-separated.
#[derive(Clone, Debug, Default)]
pub struct EndpointPolicy {
    domains: HashSet<String>,
    networks: Vec<IpNet>,
}

impl EndpointPolicy {
    pub fn parse(raw: Option<&str>) -> Result<Self, PushConfigError> {
        let mut policy = Self::default();
        for entry in raw
            .unwrap_or_default()
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            if let Ok(network) = entry.parse::<IpNet>() {
                policy.networks.push(network);
                continue;
            }
            if let Ok(ip) = entry.parse::<IpAddr>() {
                policy.networks.push(IpNet::from(ip));
                continue;
            }
            let domain = entry.trim_end_matches('.').to_ascii_lowercase();
            if domain.is_empty()
                || domain.len() > 253
                || !domain
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_'))
            {
                return Err(PushConfigError::InvalidAllowlistEntry(entry.to_owned()));
            }
            policy.domains.insert(domain);
        }
        Ok(policy)
    }

    pub fn host_is_allowlisted(&self, host: &str) -> bool {
        self.domains
            .contains(&host.trim_end_matches('.').to_ascii_lowercase())
    }

    pub fn ip_is_allowlisted(&self, ip: IpAddr) -> bool {
        self.networks.iter().any(|network| network.contains(&ip))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vapid_identity_survives_pem_roundtrip() {
        let original = VapidKeyMaterial::generate().unwrap();
        let restored = VapidKeyMaterial::from_pem(original.private_key_pem()).unwrap();
        assert_eq!(original.public_key_base64(), restored.public_key_base64());
        assert_eq!(
            URL_SAFE_NO_PAD
                .decode(original.public_key_base64())
                .unwrap()
                .len(),
            65
        );
        assert!(!format!("{original:?}").contains("PRIVATE KEY"));
    }

    #[test]
    fn allowlist_accepts_domains_ips_and_cidr() {
        let policy = EndpointPolicy::parse(Some("Push.LAN.,100.64.0.1,10.20.0.0/16")).unwrap();
        assert!(policy.host_is_allowlisted("push.lan"));
        assert!(policy.ip_is_allowlisted("100.64.0.1".parse().unwrap()));
        assert!(policy.ip_is_allowlisted("10.20.30.40".parse().unwrap()));
        assert!(!policy.ip_is_allowlisted("10.21.0.1".parse().unwrap()));
    }
}
