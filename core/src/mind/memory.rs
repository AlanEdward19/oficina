//! O que a Faísca lembra: apps e horários, interesses, fatos ditos pelo
//! usuário, roupinhas e o que já aprendeu. Fica só neste Mac.

use super::context::Diary;
use super::decor::Decor;
use super::outfit::Outfit;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Clone, Default, Serialize, Deserialize)]
pub struct AppStat {
    pub name: String,
    pub secs: f64,
    pub hours: Vec<f64>,
    pub last: u64,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Fact {
    pub text: String,
    pub at: u64,
}

#[derive(Clone, Copy, Default, Serialize, Deserialize)]
pub struct Bandit {
    pub shown: u32,
    pub accepted: u32,
    pub declined: u32,
}

impl Bandit {
    /// Média com prior otimista: o que nunca foi tentado ainda tem chance.
    pub fn mean(&self) -> f32 {
        (self.accepted as f32 + 1.0) / (self.shown as f32 + 2.0)
    }
}

#[derive(Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Memory {
    pub apps: HashMap<String, AppStat>,
    pub interests: HashMap<String, u32>,
    pub facts: Vec<Fact>,
    pub outfits: Vec<Outfit>,
    pub outfit: Option<String>,
    pub decors: Vec<Decor>,
    pub decor: Option<String>,
    pub researched: Vec<String>,
    pub bandit: HashMap<String, Bandit>,
    pub readout: Vec<f32>,
    pub energy: Option<f32>,
    /// O dia em blocos: projetos e reuniões.
    pub diary: Diary,
    /// Apps de chamada em que ela nunca pergunta se deve ouvir.
    pub call_never: Vec<String>,
}

const AI_HINTS: &[&str] = &["claude", "chatgpt", "openai", "cursor", "windsurf", "ollama", "lmstudio", "copilot", "codex"];
const WORK_HINTS: &[&str] = &[
    "vscode", "visual studio", "xcode", "terminal", "iterm", "ghostty", "warp", "docker", "jetbrains", "intellij",
    "pycharm", "webstorm", "rider", "android studio", "postman", "zed", "sublime", "figma", "tableplus", "datagrip",
];
const AI_WORDS: &[&str] = &["ia", "ai", "agente", "agentes", "llm", "claude", "modelo", "modelos", "prompt", "rede", "neural", "mcp"];

const STOP: &[&str] = &[
    "para", "como", "com", "que", "uma", "umas", "uns", "das", "dos", "nas", "nos", "pelo", "pela", "sobre", "mais", "menos",
    "isso", "isto", "esse", "essa", "este", "esta", "aqui", "agora", "depois", "antes", "muito", "pouco", "tudo", "nada",
    "você", "voce", "meu", "minha", "meus", "minhas", "seu", "sua", "pode", "poderia", "quero", "queria", "favor", "faça",
    "fazer", "faz", "crie", "criar", "cria", "pesquise", "pesquisar", "resuma", "resumir", "responda", "apenas", "palavra",
    "arquivo", "arquivos", "pasta", "altere", "nenhum", "nenhuma", "liste", "listar", "diga", "quantos", "quantas", "ferramenta",
    "português", "portugues", "explica", "explique", "frase", "também", "tambem", "então", "entao", "porque", "quando", "onde",
    "qual", "quais", "tem", "ter", "ser", "está", "esta", "estão", "foi", "vai", "vou", "the", "and", "for", "with", "what",
    "olá", "ola", "oi", "tudo", "bem", "obrigado", "obrigada", "lembre", "lembra",
];

pub fn is_ai(bundle: &str, name: &str) -> bool {
    let s = format!("{} {}", bundle.to_lowercase(), name.to_lowercase());
    AI_HINTS.iter().any(|h| s.contains(h))
}

pub fn is_work(bundle: &str, name: &str) -> bool {
    let s = format!("{} {}", bundle.to_lowercase(), name.to_lowercase());
    is_ai(bundle, name) || WORK_HINTS.iter().any(|h| s.contains(h))
}

impl Memory {
    pub fn add_app_time(&mut self, bundle: &str, name: &str, secs: f64, hour: usize, now: u64) {
        if secs <= 0.0 || bundle.is_empty() {
            return;
        }
        let stat = self.apps.entry(bundle.to_string()).or_default();
        if stat.hours.len() != 24 {
            stat.hours = vec![0.0; 24];
        }
        stat.name = name.to_string();
        stat.secs += secs;
        stat.hours[hour.min(23)] += secs;
        stat.last = now;
    }

    pub fn knows_app(&self, bundle: &str) -> bool {
        self.apps.contains_key(bundle)
    }

    /// Guarda palavras de interesse e, se for o caso, um fato a lembrar.
    /// Devolve o fato guardado.
    pub fn observe_text(&mut self, text: &str, now: u64) -> Option<String> {
        let lower = text.trim().to_lowercase();
        for prefix in ["lembre-se que ", "lembre que ", "lembra que ", "lembre-se de ", "lembre de "] {
            if let Some(rest) = lower.strip_prefix(prefix) {
                let start = text.trim().len() - rest.len();
                let fact: String = text.trim()[start..].chars().take(200).collect();
                if !fact.trim().is_empty() {
                    self.facts.push(Fact { text: fact.trim().to_string(), at: now });
                    if self.facts.len() > 50 {
                        self.facts.remove(0);
                    }
                    return Some(fact.trim().to_string());
                }
            }
        }
        for word in lower.split(|c: char| !c.is_alphanumeric()) {
            let short_ai = AI_WORDS.contains(&word) && word.len() >= 2;
            if (word.chars().count() >= 4 || short_ai) && !STOP.contains(&word) && !word.chars().all(|c| c.is_numeric()) {
                *self.interests.entry(word.to_string()).or_default() += 1;
            }
        }
        if self.interests.len() > 300 {
            let mut v: Vec<_> = self.interests.drain().collect();
            v.sort_by(|a, b| b.1.cmp(&a.1));
            v.truncate(200);
            self.interests = v.into_iter().collect();
        }
        None
    }

    pub fn top_apps(&self, n: usize) -> Vec<(&String, &AppStat)> {
        let mut v: Vec<_> = self.apps.iter().collect();
        v.sort_by(|a, b| b.1.secs.total_cmp(&a.1.secs));
        v.truncate(n);
        v
    }

    pub fn top_interests(&self, n: usize) -> Vec<(&String, u32)> {
        let mut v: Vec<_> = self.interests.iter().map(|(k, c)| (k, *c)).collect();
        v.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(b.0)));
        v.truncate(n);
        v
    }

    pub fn ai_minutes(&self) -> f64 {
        self.apps.iter().filter(|(b, s)| is_ai(b, &s.name)).map(|(_, s)| s.secs).sum::<f64>() / 60.0
    }

    pub fn ai_interest(&self) -> u32 {
        AI_WORDS.iter().map(|w| self.interests.get(*w).copied().unwrap_or(0)).sum()
    }

    /// Faixa de horas com mais uso, se já houver dados suficientes.
    pub fn peak_hours(&self) -> Option<(usize, usize)> {
        let mut hours = [0.0f64; 24];
        for s in self.apps.values() {
            for (h, v) in s.hours.iter().enumerate().take(24) {
                hours[h] += v;
            }
        }
        let total: f64 = hours.iter().sum();
        if total < 3600.0 {
            return None;
        }
        let busy: Vec<usize> = (0..24).filter(|h| hours[*h] >= total * 0.04).collect();
        Some((*busy.first()?, *busy.last()? + 1))
    }

    /// Resumo curto para o cérebro conversar com contexto.
    pub fn summary(&self) -> String {
        let mut parts = Vec::new();
        let apps: Vec<String> = self
            .top_apps(5)
            .iter()
            .filter(|(_, s)| s.secs >= 300.0)
            .map(|(_, s)| format!("{} ({})", s.name, human_minutes(s.secs / 60.0)))
            .collect();
        if !apps.is_empty() {
            parts.push(format!("Apps que o usuário mais usa: {}.", apps.join(", ")));
        }
        if let Some((a, b)) = self.peak_hours() {
            parts.push(format!("Costuma usar o Mac das {a}h às {b}h."));
        }
        let interests: Vec<String> = self.top_interests(8).into_iter().filter(|(_, c)| *c >= 2).map(|(w, _)| w.clone()).collect();
        if !interests.is_empty() {
            parts.push(format!("Assuntos recorrentes: {}.", interests.join(", ")));
        }
        let facts: Vec<String> = self.facts.iter().rev().take(10).map(|f| f.text.clone()).collect();
        if !facts.is_empty() {
            parts.push(format!("O usuário pediu para você lembrar: {}.", facts.join("; ")));
        }
        if let Some(o) = self.outfit.as_ref().and_then(|id| self.outfits.iter().find(|o| &o.id == id)) {
            parts.push(format!("Você está vestindo a roupinha \"{}\".", o.name));
        }
        parts.join(" ")
    }

    pub fn forget(&mut self) {
        self.apps.clear();
        self.interests.clear();
        self.facts.clear();
        self.researched.clear();
        self.bandit.clear();
        self.diary = Diary::default();
        self.call_never.clear();
    }
}

pub fn human_minutes(m: f64) -> String {
    if m >= 60.0 {
        let h = (m / 60.0).floor();
        let rest = (m - h * 60.0).round();
        if rest >= 1.0 { format!("{h:.0} h {rest:.0} min") } else { format!("{h:.0} h") }
    } else {
        format!("{:.0} min", m.max(1.0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fatos_mantem_o_texto_original() {
        let mut m = Memory::default();
        assert_eq!(m.observe_text("Lembre que eu prefiro Rust no Core", 1).as_deref(), Some("eu prefiro Rust no Core"));
        assert_eq!(m.facts.len(), 1);
        assert!(m.summary().contains("eu prefiro Rust no Core"));
    }

    #[test]
    fn interesses_ignoram_palavras_vazias() {
        let mut m = Memory::default();
        m.observe_text("Pesquise sobre ESP32 e IA para o painel", 1);
        m.observe_text("faça um agente de IA com ESP32", 2);
        let top = m.top_interests(3);
        assert_eq!(top[0], (&"esp32".to_string(), 2));
        assert_eq!(m.ai_interest(), 3);
        assert!(!m.interests.contains_key("pesquise"));
        assert!(!m.interests.contains_key("para"));
    }

    #[test]
    fn tempo_de_app_por_hora() {
        let mut m = Memory::default();
        m.add_app_time("com.anthropic.claude", "Claude", 1800.0, 10, 5);
        m.add_app_time("com.anthropic.claude", "Claude", 1800.0, 11, 6);
        m.add_app_time("com.apple.Safari", "Safari", 600.0, 23, 7);
        assert_eq!(m.ai_minutes(), 60.0);
        assert_eq!(m.top_apps(1)[0].1.name, "Claude");
        assert_eq!(m.peak_hours(), Some((10, 24)));
        assert!(m.summary().contains("Claude (1 h)"));
    }

    #[test]
    fn classifica_apps() {
        assert!(is_ai("com.anthropic.claudefordesktop", "Claude"));
        assert!(is_work("com.microsoft.VSCode", "Visual Studio Code"));
        assert!(!is_work("com.apple.Music", "Música"));
    }

    #[test]
    fn esquecer_apaga_o_pessoal_e_mantem_roupinhas() {
        let mut m = Memory::default();
        m.observe_text("lembre que gosto de café", 1);
        m.add_app_time("a", "A", 10.0, 1, 1);
        m.outfit = Some("x".into());
        m.forget();
        assert!(m.facts.is_empty() && m.apps.is_empty() && m.interests.is_empty());
        assert_eq!(m.outfit.as_deref(), Some("x"));
    }
}
