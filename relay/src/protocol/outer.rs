// Tipos ainda não usados no handler — serão conectados no próximo passo
#![allow(dead_code)]

use std::sync::OnceLock;

use serde::{Deserialize, Serialize};

fn default_room() -> String {
    "main".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OuterEnvelope {
    pub peer: String,
    /// Optional sub-channel (plano 17). Absent in legacy frames → "main".
    #[serde(default = "default_room")]
    pub room: String,
    pub ct: String, // base64 — nunca decodificado aqui
    /// End-to-end sender signature over `ct` (security fix 2026-08 — see
    /// `transport/inner_sig.ts` on the extension side and PROTOCOL.md).
    /// Base64(Ed25519(domain-prefix || ct-utf8)) made with the sender's
    /// WS-auth key. The relay does NOT verify it — it only forwards the
    /// field verbatim so the recipient (who trusts the key, not the relay)
    /// can. Absent in legacy frames → forwarded as absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sig: Option<String>,
    /// v2 signature (PR #25 review #1): dest-bound + ts-windowed, carried
    /// alongside the legacy `sig` (dual-sign keeps old recipients verifying).
    /// Forwarded verbatim like `sig`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sig2: Option<String>,
    /// Sender epoch-ms timestamp covered by `sig2` (v2 scheme — replay
    /// window + recipient binding). Forwarded verbatim like `sig`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ts: Option<u64>,
}

/// Nome da env var que sobrescreve o teto do outer envelope (inteiro em MiB).
pub const MAX_CT_ENV: &str = "RELAY_MAX_CT_MIB";

/// Default do teto: 4 MiB de payload base64-decoded. Históricamente era 1 MiB
/// fixo, mas imagens passam por base64 duplo (inner `data` + outer `ct` ≈
/// 1,333× o JPEG bruto), então 1 MiB dropava em silêncio qualquer imagem
/// acima de ~768 KB e travava o app em "sending…". 4 MiB cobre o teto de
/// compressão do app (~1,5 MB, ~2 MB estimado) com folga.
pub const DEFAULT_MAX_CT_MIB: usize = 4;

/// Teto efetivo do outer envelope, em bytes. Lido **uma vez** de
/// [`MAX_CT_ENV`] (valor em MiB) na primeira chamada e memoizado. Ausência ou
/// valor inválido (não-inteiro, zero, vazio) cai no default de 4 MiB —
/// **nunca** entra em panic (convenção do relay: zero `unwrap`/`expect` em
/// prod).
pub fn max_ct_bytes() -> usize {
    static MAX_CT_BYTES: OnceLock<usize> = OnceLock::new();
    *MAX_CT_BYTES.get_or_init(|| {
        let mib = std::env::var(MAX_CT_ENV)
            .ok()
            .and_then(|s| s.trim().parse::<usize>().ok())
            .filter(|&n| n > 0)
            .unwrap_or(DEFAULT_MAX_CT_MIB);
        mib * 1024 * 1024
    })
}

#[derive(Debug, thiserror::Error)]
pub enum ParseError {
    #[error("invalid json: {0}")]
    InvalidJson(#[from] serde_json::Error),
    #[error("payload too large: {0} bytes (max {1})")]
    TooLarge(usize, usize),
}

/// Parseia uma linha JSONL no outer envelope e valida o tamanho de `ct`
/// contra o teto configurado ([`max_ct_bytes`]). Nunca decodifica o conteúdo
/// de `ct` — apenas mede o comprimento da string base64 para estimar o tamanho
/// do payload (3/4 do len base64).
pub fn parse_line(line: &str) -> Result<OuterEnvelope, ParseError> {
    parse_line_with_max(line, max_ct_bytes())
}

/// Núcleo testável de [`parse_line`] com o teto injetado, para que os testes
/// exerçam o limite sem mexer na env var global (evita corrida entre testes
/// paralelos e o `OnceLock` memoizado).
fn parse_line_with_max(line: &str, max_ct_bytes: usize) -> Result<OuterEnvelope, ParseError> {
    let env: OuterEnvelope = serde_json::from_str(line)?;
    let estimated = env.ct.len() * 3 / 4;
    if estimated > max_ct_bytes {
        return Err(ParseError::TooLarge(estimated, max_ct_bytes));
    }
    Ok(env)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_minimal_envelope() {
        let line = r#"{"peer":"abc","ct":"AAA="}"#;
        let env = parse_line(line).unwrap();
        assert_eq!(env.peer, "abc");
        assert_eq!(env.room, "main"); // defaults to "main" when absent
        assert_eq!(env.ct, "AAA=");
    }

    #[test]
    fn parses_envelope_with_room() {
        let line = r#"{"peer":"abc","room":"aB12CD34eF56","ct":"AAA="}"#;
        let env = parse_line(line).unwrap();
        assert_eq!(env.room, "aB12CD34eF56");
    }

    #[test]
    fn sig_round_trips_and_defaults_to_none() {
        // Legacy frames (no sig) parse with sig == None.
        let legacy = parse_line(r#"{"peer":"abc","ct":"AAA="}"#).unwrap();
        assert!(legacy.sig.is_none());
        // Sig-bearing frames keep it; re-serialization emits the field back.
        let signed = parse_line(r#"{"peer":"abc","ct":"AAA=","sig":"U0lH"}"#).unwrap();
        assert_eq!(signed.sig.as_deref(), Some("U0lH"));
        let reserialized = serde_json::to_string(&signed).unwrap();
        assert!(reserialized.contains("\"sig\":\"U0lH\""));
        // And serializing a None envelope omits the field (legacy wire shape).
        assert!(!serde_json::to_string(&legacy).unwrap().contains("sig"));
    }

    #[test]
    fn dual_sig_fields_round_trip() {
        // v2 wire: v1 sig + v2 sig2 + ts coexist; all forwarded verbatim.
        let line = r#"{"peer":"abc","ct":"AAA=","sig":"U0lH","sig2":"U0lHMg==","ts":1739577600000}"#;
        let env = parse_line(line).unwrap();
        assert_eq!(env.sig.as_deref(), Some("U0lH"));
        assert_eq!(env.sig2.as_deref(), Some("U0lHMg=="));
        assert_eq!(env.ts, Some(1_739_577_600_000));
        let out = serde_json::to_string(&env).unwrap();
        assert!(out.contains("\"sig2\":\"U0lHMg==\""));
        // Legacy + v1-only frames omit sig2 entirely.
        let v1 = parse_line(r#"{"peer":"abc","ct":"AAA=","sig":"U0lH"}"#).unwrap();
        assert!(v1.sig2.is_none());
        assert!(!serde_json::to_string(&v1).unwrap().contains("sig2"));
    }

    #[test]
    fn ts_round_trips_and_defaults_to_none() {
        // v2 frames carry the sender's epoch-ms next to sig — forwarded verbatim.
        let v2 = parse_line(r#"{"peer":"abc","ct":"AAA=","sig":"U0lH","ts":1739577600000}"#)
            .unwrap();
        assert_eq!(v2.ts, Some(1_739_577_600_000));
        assert!(serde_json::to_string(&v2).unwrap().contains("\"ts\":1739577600000"));
        // Legacy frames omit it entirely.
        let legacy = parse_line(r#"{"peer":"abc","ct":"AAA="}"#).unwrap();
        assert!(legacy.ts.is_none());
        assert!(!serde_json::to_string(&legacy).unwrap().contains("ts"));
    }

    #[test]
    fn rejects_too_large() {
        // 12 MiB de "A" → estimativa 9 MiB, acima do default de 4 MiB.
        // (Antes era 2 MiB → 1,5 MiB estimado, que agora PASSARIA no default.)
        let big = "A".repeat(12 * 1024 * 1024);
        let line = format!(r#"{{"peer":"abc","ct":"{}"}}"#, big);
        assert!(matches!(parse_line(&line), Err(ParseError::TooLarge(..))));
    }

    #[test]
    fn accepts_two_mb_payload_under_default() {
        // Regressão do bug da imagem: 3 MiB de base64 → ~2,25 MiB estimado.
        // Sob o antigo teto de 1 MiB isto era dropado em silêncio (app travava
        // em "sending…"); sob o default atual de 4 MiB deve passar.
        let img = "A".repeat(3 * 1024 * 1024);
        let line = format!(r#"{{"peer":"abc","ct":"{}"}}"#, img);
        let env = parse_line(&line).expect("≈2 MB payload must pass under 4 MiB default");
        assert_eq!(env.peer, "abc");
    }

    #[test]
    fn default_max_ct_bytes_is_four_mib() {
        // Sem RELAY_MAX_CT_MIB no ambiente de teste, o teto efetivo é 4 MiB.
        assert_eq!(max_ct_bytes(), DEFAULT_MAX_CT_MIB * 1024 * 1024);
        assert_eq!(max_ct_bytes(), 4 * 1024 * 1024);
    }

    #[test]
    fn injected_max_overrides_limit() {
        // Override testável via núcleo com teto injetado — sem mexer na env
        // global (evita corrida com o OnceLock memoizado / testes paralelos).
        // ~2,25 MiB estimado: rejeitado por um teto de 1 MiB, aceito por 4 MiB.
        let payload = "A".repeat(3 * 1024 * 1024);
        let line = format!(r#"{{"peer":"abc","ct":"{}"}}"#, payload);

        assert!(matches!(
            parse_line_with_max(&line, 1024 * 1024),
            Err(ParseError::TooLarge(..))
        ));
        assert!(parse_line_with_max(&line, 4 * 1024 * 1024).is_ok());
    }

    #[test]
    fn rejects_invalid_json() {
        assert!(matches!(
            parse_line("not json at all"),
            Err(ParseError::InvalidJson(_))
        ));
    }
}
