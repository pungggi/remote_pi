//! Plan 115 — LAN endpoint advertisement.
//!
//! The relay binds `0.0.0.0`, so the same process is reachable on the home
//! LAN (e.g. `192.168.1.10:3000`) AND over an overlay such as Tailscale
//! (`100.75.161.17:3000`). At handshake the relay tells the phone its local
//! RFC1918 IPv4 addresses so the app can dial LAN first and bypass the
//! overlay at home (the flaky layer on Android).
//!
//! This module only *enumerates and filters* candidates; the handshake
//! handler ([crate::handlers::peer]) is what puts them on the wire in the
//! `challenge` frame. Filtering is a pure function over a slice of IPs so it
//! is unit-testable without touching the OS.

use std::net::Ipv4Addr;

/// True for the three RFC1918 private ranges:
///   - `10.0.0.0/8`
///   - `172.16.0.0/12` (`172.16.0.0` – `172.31.255.255`)
///   - `192.168.0.0/16`
///
/// This whitelist implicitly drops everything we do NOT want to advertise:
/// loopback (`127.x`), link-local (`169.254.x`), and overlay ranges such as
/// Tailscale's CGNAT `100.64.0.0/10` — none of those are RFC1918.
pub fn is_rfc1918(ip: Ipv4Addr) -> bool {
    let o = ip.octets();
    o[0] == 10 || (o[0] == 172 && (16..=31).contains(&o[1])) || (o[0] == 192 && o[1] == 168)
}

/// Filter a raw list of local IPv4 addresses down to the LAN candidates,
/// then sort + dedupe for deterministic output. Pure (no I/O).
pub fn filter_lan_ipv4(ips: &[Ipv4Addr]) -> Vec<Ipv4Addr> {
    let mut out: Vec<Ipv4Addr> = ips.iter().copied().filter(|ip| is_rfc1918(*ip)).collect();
    out.sort();
    out.dedup();
    out
}

/// Enumerate this host's local IPv4 addresses and return the LAN candidate
/// URLs (`http://ip:port`) the relay should advertise at handshake.
///
/// Best effort: any failure to read the interface table yields an empty
/// list — the auth handshake is NEVER blocked by advertisement collection.
/// Callers pass the result to [`crate::auth::challenge::challenge_line`],
/// which omits the field entirely when the list is empty (backwards
/// compatible with apps older than plan 115).
pub fn lan_candidate_urls(port: u16) -> Vec<String> {
    let interfaces = match if_addrs::get_if_addrs() {
        Ok(it) => it,
        Err(_) => return Vec::new(),
    };
    let ips: Vec<Ipv4Addr> = interfaces
        .into_iter()
        .filter_map(|iface| match iface.addr {
            if_addrs::IfAddr::V4(v4) => Some(v4.ip),
            _ => None,
        })
        .collect();
    // filter_lan_ipv4 dedupes + sorts; then format each as an http URL.
    filter_lan_ipv4(&ips)
        .into_iter()
        .map(|ip| format!("http://{ip}:{port}"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(s: &str) -> Ipv4Addr {
        s.parse().unwrap()
    }

    #[test]
    fn rfc1918_whitelist_accepts_the_three_ranges() {
        assert!(is_rfc1918(ip("10.0.0.1")));
        assert!(is_rfc1918(ip("10.255.255.255")));
        assert!(is_rfc1918(ip("172.16.0.1")));
        assert!(is_rfc1918(ip("172.31.255.255")));
        assert!(is_rfc1918(ip("192.168.0.1")));
        assert!(is_rfc1918(ip("192.168.1.10")));
    }

    #[test]
    fn rfc1918_whitelist_rejects_non_private() {
        // loopback
        assert!(!is_rfc1918(ip("127.0.0.1")));
        // link-local
        assert!(!is_rfc1918(ip("169.254.1.1")));
        // Tailscale CGNAT 100.64.0.0/10
        assert!(!is_rfc1918(ip("100.64.0.1")));
        assert!(!is_rfc1918(ip("100.127.255.255")));
        // 172.32 is just outside the /12
        assert!(!is_rfc1918(ip("172.32.0.1")));
        assert!(!is_rfc1918(ip("172.15.0.1")));
        // public
        assert!(!is_rfc1918(ip("203.0.113.5")));
    }

    #[test]
    fn filter_dedupes_and_sorts_and_keeps_only_rfc1918() {
        let ips = vec![
            ip("192.168.1.10"),
            ip("127.0.0.1"), // dropped (loopback)
            ip("10.0.0.5"),
            ip("192.168.1.10"), // dup
            ip("100.75.161.17"), // dropped (Tailscale)
            ip("172.20.0.1"),
        ];
        assert_eq!(
            filter_lan_ipv4(&ips),
            vec![ip("10.0.0.5"), ip("172.20.0.1"), ip("192.168.1.10")],
        );
    }

    #[test]
    fn empty_input_yields_empty_output() {
        assert!(filter_lan_ipv4(&[]).is_empty());
    }

    #[test]
    fn challenge_line_emits_lan_when_present() {
        // The challenge frame must carry `lan` only when there is something
        // to advertise, so older apps see the exact pre-plan-115 frame when
        // the relay has no LAN address (skip_serializing_if).
        use crate::auth::challenge::challenge_line;
        let with_lan = challenge_line("nb64", &["http://192.168.1.10:3000".to_string()]);
        let v: serde_json::Value = serde_json::from_str(&with_lan).unwrap();
        assert_eq!(v["type"], "challenge");
        assert_eq!(v["nonce"], "nb64");
        assert_eq!(v["lan"], serde_json::json!(["http://192.168.1.10:3000"]));

        let without_lan = challenge_line("nb64", &[]);
        let v2: serde_json::Value = serde_json::from_str(&without_lan).unwrap();
        assert_eq!(v2["type"], "challenge");
        assert_eq!(v2["nonce"], "nb64");
        // Field omitted entirely — backwards compatible.
        assert!(v2.get("lan").is_none());
    }
}
