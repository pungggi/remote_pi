//! Teclas nomeadas do `send-key` (vocabulário estilo tmux).
//!
//! Porte fiel do `_resolveKey` do Dart: devolve a sequência de bytes que vai
//! pra PTY, ou `None` quando o nome é desconhecido.

/// Resolve um nome de tecla na sua sequência. `None` = nome desconhecido.
pub fn resolve(name: &str) -> Option<String> {
    let lower = name.to_lowercase();
    let seq = match lower.as_str() {
        "enter" | "return" | "cr" => "\r",
        "tab" => "\t",
        "escape" | "esc" => "\x1b",
        "space" => " ",
        "bspace" | "backspace" => "\x7f",
        "up" => "\x1b[A",
        "down" => "\x1b[B",
        "right" => "\x1b[C",
        "left" => "\x1b[D",
        "home" => "\x1b[H",
        "end" => "\x1b[F",
        "pageup" | "ppage" => "\x1b[5~",
        "pagedown" | "npage" => "\x1b[6~",
        "delete" | "del" => "\x1b[3~",
        _ => {
            // Ctrl: C-<letra> → byte de controle (a=0x01 … z=0x1a).
            let bytes = lower.as_bytes();
            if bytes.len() == 3 && bytes[0] == b'c' && bytes[1] == b'-' {
                let ch = bytes[2];
                if ch.is_ascii_lowercase() {
                    return Some(((ch - 0x60) as char).to_string());
                }
            }
            // Nome de 1 caractere → literal (ex.: `cockpit send-key a`).
            // Conta em chars (não bytes) pra não fatiar UTF-8.
            if name.chars().count() == 1 {
                return Some(name.to_string());
            }
            return None;
        }
    };
    Some(seq.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nomeadas_e_aliases() {
        assert_eq!(resolve("Enter").as_deref(), Some("\r"));
        assert_eq!(resolve("cr").as_deref(), Some("\r"));
        assert_eq!(resolve("ESC").as_deref(), Some("\x1b"));
        assert_eq!(resolve("PageUp").as_deref(), Some("\x1b[5~"));
        assert_eq!(resolve("backspace").as_deref(), Some("\x7f"));
    }

    #[test]
    fn control_chars() {
        assert_eq!(resolve("C-c").as_deref(), Some("\u{3}"));
        assert_eq!(resolve("c-a").as_deref(), Some("\u{1}"));
        assert_eq!(resolve("C-z").as_deref(), Some("\u{1a}"));
        // fora do range a-z não é control
        assert_eq!(resolve("C-1"), None);
    }

    #[test]
    fn caractere_unico_vira_literal() {
        assert_eq!(resolve("a").as_deref(), Some("a"));
        assert_eq!(resolve("ç").as_deref(), Some("ç"));
    }

    #[test]
    fn desconhecida_e_none() {
        assert_eq!(resolve("nope"), None);
        assert_eq!(resolve(""), None);
    }
}
