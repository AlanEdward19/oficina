//! Decisões puras de roteamento e leitura do protocolo do CLI.

use crate::store::Target;
use serde_json::Value;

const MARKER: &str = "@@delegar ";

#[derive(Debug, PartialEq)]
pub enum Dest {
    Cloud,
    Machine,
}

/// Um alvo explícito vence; depois, atalhos no início do texto.
pub fn resolve(target: Target, text: &str) -> (Target, String) {
    let t = text.trim();
    if target != Target::Auto {
        return (target, t.to_string());
    }
    for (prefix, dest) in [
        ("/nuvem", Target::Cloud),
        ("/pc", Target::Machine),
        ("/mac", Target::Machine),
        ("/chat", Target::Chat),
    ] {
        if let Some(rest) = t.strip_prefix(prefix) {
            if rest.is_empty() || rest.starts_with(char::is_whitespace) {
                return (dest, rest.trim().to_string());
            }
        }
    }
    (Target::Auto, t.to_string())
}

/// O cérebro delega respondendo apenas com `@@delegar nuvem|maquina: instrução`.
pub fn parse_delegate(text: &str) -> Option<(Dest, String)> {
    let rest = text.trim().strip_prefix(MARKER)?;
    let (dest, prompt) = rest.split_once(':')?;
    let dest = match dest.trim() {
        "nuvem" => Dest::Cloud,
        "maquina" | "máquina" => Dest::Machine,
        _ => return None,
    };
    let prompt = prompt.trim();
    (!prompt.is_empty()).then(|| (dest, prompt.to_string()))
}

/// Segura o início da resposta até saber se é uma delegação, para que o
/// marcador nunca apareça na tela.
#[derive(Default)]
pub struct Holdback {
    held: String,
    decided: bool,
    suppress: bool,
}

impl Holdback {
    pub fn feed(&mut self, chunk: &str) -> Option<String> {
        if self.suppress {
            return None;
        }
        if self.decided {
            return Some(chunk.to_string());
        }
        self.held.push_str(chunk);
        let t = self.held.trim_start();
        if t.len() >= 2 {
            self.decided = true;
            if t.starts_with("@@") {
                self.suppress = true;
                return None;
            }
            return Some(std::mem::take(&mut self.held));
        }
        None
    }

    /// Resposta curta demais para decidir ainda precisa aparecer.
    pub fn finish(&mut self) -> Option<String> {
        (!self.decided && !self.held.is_empty()).then(|| std::mem::take(&mut self.held))
    }
}

#[derive(Debug, PartialEq)]
pub enum CliEvent {
    Delta(String),
    Session(String),
    Result {
        text: String,
        is_error: bool,
        session: Option<String>,
    },
    Other,
}

/// Interpreta uma linha de `--output-format stream-json`.
pub fn parse_line(line: &str) -> CliEvent {
    let Ok(v) = serde_json::from_str::<Value>(line) else {
        return CliEvent::Other;
    };
    let session = v["session_id"].as_str().map(String::from);
    match v["type"].as_str() {
        Some("stream_event")
            if v["event"]["type"] == "content_block_delta"
                && v["event"]["delta"]["type"] == "text_delta" =>
        {
            CliEvent::Delta(v["event"]["delta"]["text"].as_str().unwrap_or("").to_string())
        }
        Some("system") if v["subtype"] == "init" => {
            session.map(CliEvent::Session).unwrap_or(CliEvent::Other)
        }
        Some("result") => CliEvent::Result {
            text: v["result"].as_str().unwrap_or("").to_string(),
            is_error: v["is_error"].as_bool().unwrap_or(false),
            session,
        },
        _ => CliEvent::Other,
    }
}

/// Remove sequências de controle da saída de um terminal.
pub fn clean_tty(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\u{1b}' => match chars.next() {
                Some('[') => {
                    for n in chars.by_ref() {
                        if ('@'..='~').contains(&n) {
                            break;
                        }
                    }
                }
                Some(']') => {
                    while let Some(n) = chars.next() {
                        if n == '\u{7}' {
                            break;
                        }
                        if n == '\u{1b}' {
                            chars.next();
                            break;
                        }
                    }
                }
                _ => {}
            },
            '\r' => {}
            c if c.is_control() && c != '\n' && c != '\t' => {}
            c => out.push(c),
        }
    }
    out
}

/// O CLI parou numa tela que só uma pessoa deve responder?
pub fn needs_cli_setup(text: &str) -> bool {
    let t: String = text.chars().filter(|c| !c.is_whitespace()).collect::<String>().to_lowercase();
    ["syntaxtheme", "choosethetextstyle", "doyoutrust", "oneyoutrust", "trustthefiles", "trustthisfolder"]
        .iter()
        .any(|needle| t.contains(needle))
}

/// Procura o link da sessão na saída do `claude --cloud`. Só devolve o link
/// completo: se o texto acaba nele, ainda pode faltar um pedaço.
pub fn find_session_url(text: &str) -> Option<String> {
    let start = text.find("https://claude.ai/code/")?;
    let rest = &text[start..];
    let end = rest.find(|c: char| c.is_whitespace() || matches!(c, '"' | '\'' | ')'))?;
    let url = &rest[..end];
    (url.len() > "https://claude.ai/code/".len()).then(|| url.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn atalhos_exigem_palavra_inteira() {
        assert_eq!(resolve(Target::Auto, "/pc limpa"), (Target::Machine, "limpa".into()));
        assert_eq!(resolve(Target::Auto, "/nuvem  faz x"), (Target::Cloud, "faz x".into()));
        assert_eq!(resolve(Target::Auto, "/pcx oi"), (Target::Auto, "/pcx oi".into()));
    }

    #[test]
    fn alvo_explicito_nao_interpreta_atalho() {
        assert_eq!(resolve(Target::Chat, "/pc oi"), (Target::Chat, "/pc oi".into()));
    }

    #[test]
    fn delegacao_valida() {
        assert_eq!(
            parse_delegate("@@delegar nuvem: criar PR\ncom testes"),
            Some((Dest::Cloud, "criar PR\ncom testes".into()))
        );
        assert_eq!(
            parse_delegate(" @@delegar maquina: abrir x\n"),
            Some((Dest::Machine, "abrir x".into()))
        );
    }

    #[test]
    fn delegacao_invalida_vira_texto() {
        assert_eq!(parse_delegate("oi @@delegar nuvem: x"), None);
        assert_eq!(parse_delegate("@@delegar marte: x"), None);
        assert_eq!(parse_delegate("@@delegar nuvem:   "), None);
    }

    #[test]
    fn holdback_esconde_marcador_mesmo_fatiado() {
        let mut h = Holdback::default();
        assert_eq!(h.feed("@"), None);
        assert_eq!(h.feed("@delegar nuvem"), None);
        assert_eq!(h.feed(": x"), None);
        assert_eq!(h.finish(), None);
    }

    #[test]
    fn holdback_libera_texto_normal_sem_perder_nada() {
        let mut h = Holdback::default();
        assert_eq!(h.feed("O"), None);
        assert_eq!(h.feed("lá"), Some("Olá".into()));
        assert_eq!(h.feed(" mundo"), Some(" mundo".into()));
    }

    #[test]
    fn holdback_entrega_resposta_de_um_caractere() {
        let mut h = Holdback::default();
        assert_eq!(h.feed("k"), None);
        assert_eq!(h.finish(), Some("k".into()));
    }

    #[test]
    fn linhas_do_cli() {
        let d = r#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"oi"}}}"#;
        assert_eq!(parse_line(d), CliEvent::Delta("oi".into()));
        let i = r#"{"type":"system","subtype":"init","session_id":"s1"}"#;
        assert_eq!(parse_line(i), CliEvent::Session("s1".into()));
        let r = r#"{"type":"result","result":"ok","is_error":true,"session_id":"s1"}"#;
        assert_eq!(
            parse_line(r),
            CliEvent::Result { text: "ok".into(), is_error: true, session: Some("s1".into()) }
        );
        assert_eq!(parse_line("lixo"), CliEvent::Other);
    }

    #[test]
    fn acha_link_da_sessao() {
        assert_eq!(
            find_session_url("Criada: https://claude.ai/code/session_01abc\nfim"),
            Some("https://claude.ai/code/session_01abc".into())
        );
        assert_eq!(find_session_url("nada"), None);
        assert_eq!(find_session_url("https://claude.ai/code/sess"), None);
    }

    #[test]
    fn reconhece_telas_de_configuracao() {
        assert!(needs_cli_setup("1. Dark mode\nSyntax theme: Monokai"));
        assert!(needs_cli_setup("Do you trust the files in this folder?"));
        assert!(!needs_cli_setup("Criando sessão na nuvem"));
    }

    #[test]
    fn limpa_saida_de_terminal() {
        let t = "\u{1b}[1mCriada\u{1b}[0m\r\n\u{1b}]8;;x\u{7}https://claude.ai/code/s1\u{1b}]8;;\u{7} fim";
        assert_eq!(clean_tty(t), "Criada\nhttps://claude.ai/code/s1 fim");
        assert_eq!(find_session_url(&clean_tty(t)), Some("https://claude.ai/code/s1".into()));
    }
}
