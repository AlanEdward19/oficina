//! Escolhe o modelo mais barato que dá conta do pedido, sem gastar tokens:
//! regras simples dão o ponto de partida e um modelo linear pequeno aprende
//! com o resultado de cada tarefa. Quem manda é o resultado: se o barato
//! falha, a fábrica sobe um degrau (Haiku → Sonnet → Opus) e anota.

use serde::{Deserialize, Serialize};
use std::{collections::HashMap, fs, path::PathBuf, sync::Mutex};

pub const AUTO: &str = "auto";
pub const OPUS: u8 = 2;
const TIERS: [(&str, &str); 3] = [("haiku", "low"), ("sonnet", "medium"), ("opus", "high")];
const DIM: usize = 256;
const WEIGHT_LIMIT: f32 = 3.0;
/// Precisa de mais que Haiku a partir de 0,5; de mais que Sonnet, a partir de 2,5.
const LIMITS: [f32; 2] = [0.5, 2.5];
/// A cada tantas etapas só de leitura, testa um degrau abaixo para aprender a economizar.
const PROBE_EVERY: u32 = 8;

const SIMPLE: &[&str] = &["resum", "traduz", "list", "format", "renomei", "explique", "ortografia", "quantos", "o que e", "qual e"];
const MEDIUM: &[&str] = &["implement", "corrig", "corrij", "bug", "adicion", "teste", "crie", "criar", "funcao", "refator", "integr", "depur", "debug", "api", "endpoint", "banco de dados"];
const HARD: &[&str] = &[
    "arquitetura", "migracao", "migrar", "seguranca", "concorrencia", "race condition", "deadlock", "redesenh", "criptograf", "distribuid",
    "vulnerabil", "auditoria", "vazamento de memoria", "memory leak", "refatorar todo", "refatore todo",
];
const WIDE: &[&str] = &["todos os arquivos", "todo o projeto", "projeto inteiro", "repositorio inteiro", "varios modulos"];
const COMPLAINTS: &[&str] = &["nao funcionou", "nao deu certo", "esta errado", "ta errado", "continua errado", "nao era isso", "tente de novo", "tenta de novo", "refaca", "piorou"];
/// Reclamação é curta; um pedido longo com "refaça" é um pedido novo.
const COMPLAINT_WORDS: usize = 12;
/// "Sim, pode fazer" não diz nada sobre a dificuldade: vale o nível anterior.
const FOLLOW_UP_WORDS: usize = 4;
const REMEMBERED_CHARS: usize = 600;

#[derive(Clone, Copy)]
pub struct Need<'a> {
    pub text: &'a str,
    /// Ajuste pelo tipo de trabalho (etapa da missão).
    pub bias: f32,
    pub floor: u8,
    pub ceiling: u8,
    pub probe: bool,
    /// Missão não herda o nível da conversa.
    pub fresh: bool,
}

impl<'a> Need<'a> {
    pub fn plain(text: &'a str) -> Self {
        Self { text, bias: 0.0, floor: 0, ceiling: OPUS, probe: false, fresh: false }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Choice {
    pub tier: u8,
    pub model: &'static str,
    pub effort: &'static str,
}

pub fn tier_of(model: &str) -> Option<u8> {
    TIERS.iter().position(|t| t.0 == model).map(|i| i as u8)
}

#[derive(Default, Serialize, Deserialize)]
#[serde(default)]
struct Saved {
    weights: [Vec<f32>; 2],
    counts: [u32; 3],
    escalations: u32,
    learned: u32,
    probes: u32,
}

#[derive(Serialize)]
pub struct Stats {
    pub haiku: u32,
    pub sonnet: u32,
    pub opus: u32,
    pub escalations: u32,
    pub learned: u32,
}

struct Inner {
    saved: Saved,
    /// Último nível e pedido de cada conversa; não vale guardar em disco.
    last: HashMap<String, (u8, String)>,
}

pub struct Router {
    inner: Mutex<Inner>,
    path: PathBuf,
}

/// Minúsculas e sem acentos, para "migração" e "migracao" contarem igual.
fn normalize(text: &str) -> String {
    text.chars()
        .flat_map(char::to_lowercase)
        .map(|c| match c {
            'á' | 'à' | 'â' | 'ã' => 'a',
            'é' | 'ê' => 'e',
            'í' => 'i',
            'ó' | 'ô' | 'õ' => 'o',
            'ú' | 'ü' => 'u',
            'ç' => 'c',
            c => c,
        })
        .collect()
}

fn words(norm: &str) -> impl Iterator<Item = &str> {
    norm.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty())
}

/// Palavra solta vale como começo de palavra; expressão, como trecho do texto.
fn hits(norm: &str, list: &[&str]) -> f32 {
    list.iter().filter(|k| if k.contains(' ') { norm.contains(**k) } else { words(norm).any(|w| w.starts_with(**k)) }).count() as f32
}

/// Quão difícil o pedido parece, antes de qualquer aprendizado.
fn prior(norm: &str) -> f32 {
    let count = words(norm).count();
    let mut score = hits(norm, HARD).min(2.0) * 2.0 + hits(norm, MEDIUM).min(1.5) - hits(norm, SIMPLE).min(1.0) + hits(norm, WIDE).min(1.0);
    if norm.contains("```") {
        score += 1.0;
    }
    if count <= 8 {
        score -= 0.5;
    } else if count > 120 {
        score += 1.0;
    } else if count > 40 {
        score += 0.5;
    }
    score
}

/// FNV-1a: o resultado não muda entre execuções, como o pesos salvos exigem.
fn slot(word: &str) -> usize {
    let hash = word.bytes().fold(0x811c_9dc5u32, |h, b| (h ^ b as u32).wrapping_mul(0x0100_0193));
    hash as usize % DIM
}

fn features(norm: &str) -> Vec<(usize, f32)> {
    let mut slots: Vec<usize> = words(norm).filter(|w| w.len() >= 3).map(slot).collect();
    slots.sort_unstable();
    slots.dedup();
    let value = 1.0 / (slots.len().max(1) as f32).sqrt();
    slots.into_iter().map(|i| (i, value)).collect()
}

impl Saved {
    fn learned_score(&self, boundary: usize, x: &[(usize, f32)]) -> f32 {
        let w = &self.weights[boundary];
        x.iter().map(|(i, v)| w.get(*i).copied().unwrap_or(0.0) * v).sum()
    }

    fn estimate(&self, norm: &str, bias: f32) -> u8 {
        let x = features(norm);
        let base = prior(norm) + bias;
        if base - LIMITS[0] + self.learned_score(0, &x) <= 0.0 {
            0
        } else if base - LIMITS[1] + self.learned_score(1, &x) <= 0.0 {
            1
        } else {
            OPUS
        }
    }

    /// Só o degrau usado aprende: sucesso no Sonnet nada diz sobre o Haiku.
    fn train(&mut self, text: &str, tier: u8, sufficient: bool) {
        let Some(w) = self.weights.get_mut(tier as usize) else { return };
        w.resize(DIM, 0.0);
        let step = if sufficient { -1.0 } else { 1.0 };
        for (i, v) in features(&normalize(text)) {
            w[i] = (w[i] + step * v).clamp(-WEIGHT_LIMIT, WEIGHT_LIMIT);
        }
        self.learned += 1;
    }
}

impl Router {
    pub fn open(path: PathBuf) -> Self {
        let saved = fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        Self { inner: Mutex::new(Inner { saved, last: HashMap::new() }), path }
    }

    fn save(&self, saved: &Saved) {
        if let Ok(bytes) = serde_json::to_vec(saved) {
            let tmp = self.path.with_extension("tmp");
            if fs::write(&tmp, bytes).is_ok() {
                let _ = fs::rename(tmp, &self.path);
            }
        }
    }

    pub fn choose(&self, key: &str, need: Need) -> Choice {
        let mut guard = self.inner.lock().unwrap();
        let inner = &mut *guard;
        let norm = normalize(need.text);
        let count = words(&norm).count();
        let previous = if need.fresh { None } else { inner.last.get(key).cloned() };
        let complaint = count <= COMPLAINT_WORDS && COMPLAINTS.iter().any(|c| norm.contains(c));
        let (mut tier, remembered) = match previous {
            Some((t, old)) if complaint => {
                inner.saved.train(&old, t, false);
                if t < OPUS {
                    inner.saved.escalations += 1;
                }
                ((t + 1).min(OPUS), old)
            }
            Some((t, old)) if count <= FOLLOW_UP_WORDS && hits(&norm, SIMPLE) == 0.0 => (t, old),
            _ => (inner.saved.estimate(&norm, need.bias), need.text.chars().take(REMEMBERED_CHARS).collect()),
        };
        let ceiling = need.ceiling.max(need.floor);
        tier = tier.clamp(need.floor, ceiling);
        if need.probe && tier > need.floor {
            inner.saved.probes += 1;
            if inner.saved.probes % PROBE_EVERY == 0 {
                tier -= 1;
            }
        }
        inner.last.insert(key.to_string(), (tier, remembered));
        inner.saved.counts[tier as usize] += 1;
        self.save(&inner.saved);
        let (model, effort) = TIERS[tier as usize];
        Choice { tier, model, effort }
    }

    /// Resultado medido de uma etapa: `sufficient` falso significa subir.
    pub fn outcome(&self, text: &str, tier: u8, sufficient: bool) {
        let mut inner = self.inner.lock().unwrap();
        inner.saved.train(text, tier, sufficient);
        if !sufficient && tier < OPUS {
            inner.saved.escalations += 1;
        }
        self.save(&inner.saved);
    }

    pub fn stats(&self) -> Stats {
        let inner = self.inner.lock().unwrap();
        let s = &inner.saved;
        Stats { haiku: s.counts[0], sonnet: s.counts[1], opus: s.counts[2], escalations: s.escalations, learned: s.learned }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn router(name: &str) -> Router {
        let p = std::env::temp_dir().join(format!("oficina-router-{}-{name}.json", std::process::id()));
        let _ = fs::remove_file(&p);
        Router::open(p)
    }

    fn model(r: &Router, text: &str) -> &'static str {
        r.choose("", Need { fresh: true, ..Need::plain(text) }).model
    }

    #[test]
    fn cada_pedido_no_modelo_que_basta() {
        let r = router("tabela");
        for t in ["resuma este texto", "traduza para inglês", "bom dia", "liste os arquivos"] {
            assert_eq!(model(&r, t), "haiku", "{t}");
        }
        for t in ["corrija o bug no login", "implemente uma função que valida CPF", "adicione testes ao módulo de pagamento"] {
            assert_eq!(model(&r, t), "sonnet", "{t}");
        }
        for t in ["redesenhe a arquitetura de autenticação e planeje a migração", "corrija a race condition e o deadlock no gerenciador de fila"] {
            assert_eq!(model(&r, t), "opus", "{t}");
        }
    }

    #[test]
    fn falha_ensina_a_subir_e_persiste() {
        let r = router("aprende");
        let task = "ajuste o carrossel da página inicial";
        assert_eq!(model(&r, task), "haiku");
        r.outcome(task, 0, false);
        r.outcome(task, 0, false);
        assert_eq!(model(&r, task), "sonnet");
        let again = Router::open(r.path.clone());
        assert_eq!(model(&again, task), "sonnet");
        assert_eq!(again.stats().learned, 2);
        assert_eq!(again.stats().escalations, 2);
    }

    #[test]
    fn sucesso_ensina_a_economizar() {
        let r = router("economiza");
        let task = "corrija o bug do botão";
        assert_eq!(model(&r, task), "sonnet");
        for _ in 0..4 {
            r.outcome(task, 0, true);
        }
        assert_eq!(model(&r, task), "haiku");
    }

    #[test]
    fn sucesso_em_opus_nao_ensina_nada() {
        let r = router("topo");
        r.outcome("qualquer coisa", OPUS, true);
        assert_eq!(r.stats().learned, 0);
    }

    #[test]
    fn continuacao_herda_e_reclamacao_sobe() {
        let r = router("conversa");
        assert_eq!(r.choose("c", Need::plain("corrija o bug no login")).model, "sonnet");
        assert_eq!(r.choose("c", Need::plain("sim, pode fazer")).model, "sonnet");
        assert_eq!(r.choose("c", Need::plain("não funcionou")).model, "opus");
        assert_eq!(r.stats().escalations, 1);
        assert_eq!(r.choose("outra", Need::plain("não funcionou")).model, "haiku");
    }

    #[test]
    fn piso_teto_e_vies() {
        let r = router("limites");
        assert_eq!(r.choose("", Need { floor: 1, fresh: true, ..Need::plain("bom dia") }).model, "sonnet");
        assert_eq!(r.choose("", Need { ceiling: 1, fresh: true, ..Need::plain("redesenhe a arquitetura e planeje a migração") }).model, "sonnet");
        let code = "corrija o bug no login";
        assert_eq!(r.choose("", Need { bias: -2.0, fresh: true, ..Need::plain(code) }).model, "haiku");
    }

    #[test]
    fn de_vez_em_quando_testa_um_degrau_abaixo() {
        let r = router("prova");
        let need = Need { probe: true, fresh: true, ..Need::plain("corrija o bug no login") };
        let picks: Vec<&str> = (0..PROBE_EVERY).map(|_| r.choose("", need).model).collect();
        assert_eq!(picks.iter().filter(|m| **m == "haiku").count(), 1);
        assert_eq!(picks.last(), Some(&"haiku"));
    }
}
