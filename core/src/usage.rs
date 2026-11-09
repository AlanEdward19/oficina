//! Uso do Claude: percentuais oficiais (`/usage`) e contagem local de tokens.
//! Dos logs só saem números: nada do conteúdo das conversas é guardado.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{HashMap, hash_map::DefaultHasher},
    fs,
    hash::{Hash, Hasher},
    io::{BufRead, BufReader, Seek, SeekFrom},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

const DAY: u64 = 86_400;
const RETENTION: u64 = 8 * DAY;
const WEEK: u64 = 7 * DAY;
const ACTIVE_SECS: u64 = 120;

#[derive(Clone, Default, Serialize)]
pub struct Limit {
    pub kind: String,
    pub scope: Option<String>,
    pub percent: f64,
    pub resets_at: Option<String>,
}

#[derive(Clone, Default, Serialize)]
pub struct ModelUse {
    pub model: String,
    pub tokens: u64,
}

#[derive(Clone, Default, Serialize)]
pub struct Local {
    pub today: u64,
    pub week: u64,
    pub models: Vec<ModelUse>,
    pub active_sessions: usize,
}

#[derive(Clone, Default, Serialize)]
pub struct Usage {
    pub limits: Vec<Limit>,
    pub limits_note: Option<String>,
    pub limits_at: u64,
    #[serde(flatten)]
    pub local: Local,
    pub updated_at: u64,
}

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Início do dia no fuso local, em segundos Unix.
fn local_day_start(ts: u64) -> u64 {
    // SAFETY: `tm` é inicializada por localtime_r antes de ser lida.
    let offset = unsafe {
        let t = ts as libc::time_t;
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&t, &mut tm);
        tm.tm_gmtoff
    };
    let local = ts as i64 + offset;
    (local - local.rem_euclid(DAY as i64) - offset) as u64
}

/// Converte `2026-11-09T17:29:44.123Z` em segundos Unix.
pub fn parse_ts(s: &str) -> Option<u64> {
    let b = s.as_bytes();
    if b.len() < 19 || b[4] != b'-' || b[10] != b'T' {
        return None;
    }
    let num = |r: std::ops::Range<usize>| s.get(r)?.parse::<i64>().ok();
    let (y, m, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (h, mi, sec) = (num(11..13)?, num(14..16)?, num(17..19)?);
    // Dias desde 1970 pelo calendário civil (algoritmo de Hinnant).
    let y2 = if m <= 2 { y - 1 } else { y };
    let era = y2.div_euclid(400);
    let yoe = y2 - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    u64::try_from(days * 86_400 + h * 3600 + mi * 60 + sec).ok()
}

#[derive(Deserialize)]
struct Row {
    #[serde(rename = "type")]
    kind: String,
    timestamp: Option<String>,
    #[serde(rename = "requestId")]
    request_id: Option<String>,
    message: Option<Msg>,
}

#[derive(Deserialize)]
struct Msg {
    id: Option<String>,
    model: Option<String>,
    usage: Option<Tokens>,
}

#[derive(Deserialize)]
struct Tokens {
    #[serde(default)]
    input_tokens: u64,
    #[serde(default)]
    output_tokens: u64,
    #[serde(default)]
    cache_creation_input_tokens: u64,
}

struct Entry {
    ts: u64,
    model: u16,
    tokens: u32,
}

pub struct Scanner {
    root: PathBuf,
    offsets: HashMap<PathBuf, u64>,
    entries: HashMap<u64, Entry>,
    models: Vec<String>,
    active: usize,
}

impl Scanner {
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            offsets: HashMap::new(),
            entries: HashMap::new(),
            models: Vec::new(),
            active: 0,
        }
    }

    /// Lê só o que foi acrescentado desde a última vez.
    pub fn scan(&mut self) -> Local {
        let now = now();
        self.active = 0;
        let mut seen = Vec::new();
        let root = self.root.clone();
        self.walk(&root, now, &mut seen);
        self.offsets.retain(|p, _| seen.contains(p));
        self.entries.retain(|_, e| now.saturating_sub(e.ts) < RETENTION);
        self.summary(now)
    }

    fn walk(&mut self, dir: &Path, now: u64, seen: &mut Vec<PathBuf>) {
        let Ok(items) = fs::read_dir(dir) else { return };
        for item in items.flatten() {
            let path = item.path();
            let Ok(meta) = item.metadata() else { continue };
            if meta.is_dir() {
                self.walk(&path, now, seen);
                continue;
            }
            if path.extension().is_none_or(|e| e != "jsonl") {
                continue;
            }
            let modified = meta
                .modified()
                .ok()
                .and_then(|m| m.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_secs())
                .unwrap_or(0);
            let age = now.saturating_sub(modified);
            if age >= RETENTION {
                continue;
            }
            if age < ACTIVE_SECS && !path.components().any(|c| c.as_os_str() == "subagents") {
                self.active += 1;
            }
            let offset = self.offsets.get(&path).copied().unwrap_or(0);
            let offset = if meta.len() < offset { 0 } else { offset };
            let next = if meta.len() == offset {
                offset
            } else {
                self.read_from(&path, offset).unwrap_or(offset)
            };
            self.offsets.insert(path.clone(), next);
            seen.push(path);
        }
    }

    /// Lê em pedaços de tamanho fixo. Linhas enormes (imagens coladas,
    /// resultados longos de ferramentas) nunca são respostas com contagem de
    /// tokens: são descartadas sem ir para a memória.
    fn read_from(&mut self, path: &Path, offset: u64) -> std::io::Result<u64> {
        const MAX_LINE: usize = 1024 * 1024;
        let mut file = fs::File::open(path)?;
        file.seek(SeekFrom::Start(offset))?;
        let mut reader = BufReader::with_capacity(64 * 1024, file);
        let mut line: Vec<u8> = Vec::with_capacity(16 * 1024);
        let mut too_long = false;
        let mut pos = offset;
        let mut pending = 0u64;
        loop {
            let chunk = reader.fill_buf()?;
            if chunk.is_empty() {
                break;
            }
            let (part, done) = match chunk.iter().position(|b| *b == b'\n') {
                Some(i) => (&chunk[..=i], true),
                None => (chunk, false),
            };
            let used = part.len();
            if !too_long {
                if line.len() + used > MAX_LINE {
                    too_long = true;
                    line.clear();
                } else {
                    line.extend_from_slice(part);
                }
            }
            reader.consume(used);
            pending += used as u64;
            if done {
                if !too_long {
                    self.ingest(&line);
                }
                // Só avança o ponto de leitura em linha completa: uma linha
                // ainda sendo escrita fica para a próxima vez.
                pos += pending;
                pending = 0;
                line.clear();
                too_long = false;
                if line.capacity() > 256 * 1024 {
                    line.shrink_to(16 * 1024);
                }
            }
        }
        Ok(pos)
    }

    fn ingest(&mut self, line: &[u8]) {
        const NEEDLE: &[u8] = b"\"type\":\"assistant\"";
        if !contains(line, NEEDLE) {
            return;
        }
        let Ok(row) = serde_json::from_slice::<Row>(line) else { return };
        if row.kind != "assistant" {
            return;
        }
        let Some(msg) = row.message else { return };
        let (Some(model), Some(u), Some(id)) = (msg.model, msg.usage, msg.id) else { return };
        if model.starts_with('<') {
            return;
        }
        let Some(ts) = row.timestamp.as_deref().and_then(parse_ts) else { return };
        let mut h = DefaultHasher::new();
        id.hash(&mut h);
        row.request_id.hash(&mut h);
        let model = self.model_index(&model);
        let tokens = u.input_tokens + u.output_tokens + u.cache_creation_input_tokens;
        // A mesma resposta é gravada várias vezes; a última tem o total final.
        self.entries.insert(
            h.finish(),
            Entry {
                ts,
                model,
                tokens: u32::try_from(tokens).unwrap_or(u32::MAX),
            },
        );
    }

    fn model_index(&mut self, name: &str) -> u16 {
        if let Some(i) = self.models.iter().position(|m| m == name) {
            return i as u16;
        }
        self.models.push(name.to_string());
        (self.models.len() - 1) as u16
    }

    fn summary(&self, now: u64) -> Local {
        let day_start = local_day_start(now);
        let week_start = now.saturating_sub(WEEK);
        let (mut today, mut week) = (0, 0);
        let mut by_model = vec![0u64; self.models.len()];
        for e in self.entries.values().filter(|e| e.ts >= week_start) {
            week += e.tokens as u64;
            by_model[e.model as usize] += e.tokens as u64;
            if e.ts >= day_start {
                today += e.tokens as u64;
            }
        }
        let mut grouped: HashMap<String, u64> = HashMap::new();
        for (i, tokens) in by_model.into_iter().enumerate() {
            if tokens > 0 {
                *grouped.entry(family(&self.models[i])).or_default() += tokens;
            }
        }
        let mut models: Vec<ModelUse> = grouped
            .into_iter()
            .map(|(model, tokens)| ModelUse { model, tokens })
            .collect();
        models.sort_by(|a, b| b.tokens.cmp(&a.tokens));
        Local {
            today,
            week,
            models,
            active_sessions: self.active,
        }
    }
}

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    let first = needle[0];
    let mut i = 0;
    while let Some(p) = hay[i..].iter().position(|b| *b == first) {
        i += p;
        if hay.len() - i < needle.len() {
            return false;
        }
        if &hay[i..i + needle.len()] == needle {
            return true;
        }
        i += 1;
    }
    false
}

/// `claude-opus-5-5` vira `Opus`.
fn family(model: &str) -> String {
    let name = model.strip_prefix("claude-").unwrap_or(model);
    let name = name.split('-').next().unwrap_or(name);
    let mut c = name.chars();
    match c.next() {
        Some(f) => f.to_uppercase().chain(c).collect(),
        None => model.to_string(),
    }
}

/// Procura o relatório de limites numa linha de saída do `/usage`.
pub fn parse_limits(line: &str) -> Option<Vec<Limit>> {
    let v: Value = serde_json::from_str(line).ok()?;
    let report = [&v["usage_report"], &v["message"]["usage_report"]]
        .into_iter()
        .find(|r| r.is_object())?;
    let rows = report["rate_limits"]["limits"].as_array()?;
    let limits = rows
        .iter()
        .filter_map(|r| {
            Some(Limit {
                kind: r["kind"].as_str()?.to_string(),
                scope: r["scope"]["model"]["display_name"].as_str().map(String::from),
                percent: r["percent"].as_f64()?,
                resets_at: r["resets_at"].as_str().map(String::from),
            })
        })
        .collect();
    Some(limits)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn data_iso() {
        assert_eq!(parse_ts("1970-01-01T00:00:00.000Z"), Some(0));
        assert_eq!(parse_ts("2026-11-09T17:29:44.123Z"), Some(1_794_245_384));
        assert_eq!(parse_ts("2024-02-29T12:00:00Z"), Some(1_709_208_000));
        assert_eq!(parse_ts("lixo"), None);
    }

    fn iso(ts: u64) -> String {
        // Inverso simples para os testes, usando dias civis.
        let z = (ts / DAY) as i64 + 719_468;
        let era = z.div_euclid(146_097);
        let doe = z - era * 146_097;
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let d = doy - (153 * mp + 2) / 5 + 1;
        let m = if mp < 10 { mp + 3 } else { mp - 9 };
        let y = yoe + era * 400 + i64::from(m <= 2);
        let s = ts % DAY;
        format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.000Z", s / 3600, s % 3600 / 60, s % 60)
    }

    fn row(id: &str, ts: u64, model: &str, output: u64) -> String {
        format!(
            r#"{{"type":"assistant","timestamp":"{}","requestId":"r{id}","message":{{"id":"{id}","model":"{model}","content":[{{"type":"text","text":"SEGREDO"}}],"usage":{{"input_tokens":10,"output_tokens":{output},"cache_creation_input_tokens":5,"cache_read_input_tokens":9000}}}}}}"#,
            iso(ts)
        ) + "\n"
    }

    fn dir() -> PathBuf {
        let d = std::env::temp_dir().join(format!("oficina-usage-{}-{:?}", std::process::id(), std::thread::current().id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(d.join("proj")).unwrap();
        d
    }

    #[test]
    fn soma_sem_duplicar_e_usa_o_ultimo_total() {
        let d = dir();
        let t = now() - 10;
        let body = row("a", t, "claude-opus-5-5", 1) + &row("a", t, "claude-opus-5-5", 100) + &row("b", t, "claude-sonnet-5-5", 50);
        fs::write(d.join("proj/s.jsonl"), body).unwrap();
        let l = Scanner::new(d.clone()).scan();
        assert_eq!(l.week, (10 + 100 + 5) + (10 + 50 + 5));
        assert_eq!(l.models[0].model, "Opus");
        assert_eq!(l.models[0].tokens, 115);
        assert_eq!(l.models[1].model, "Sonnet");
        assert_eq!(l.active_sessions, 1);
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn leitura_incremental_ignora_linha_incompleta() {
        let d = dir();
        let p = d.join("proj/s.jsonl");
        let t = now() - 10;
        let whole = row("a", t, "claude-opus-5-5", 1);
        let next = row("b", t, "claude-opus-5-5", 1);
        fs::write(&p, format!("{whole}{}", &next[..20])).unwrap();
        let mut s = Scanner::new(d.clone());
        assert_eq!(s.scan().week, 16);
        fs::write(&p, format!("{whole}{next}")).unwrap();
        assert_eq!(s.scan().week, 32);
        assert_eq!(s.scan().week, 32);
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn nao_conta_sintetico_nem_antigo_nem_subagente_como_sessao() {
        let d = dir();
        let t = now() - 10;
        fs::write(d.join("proj/s.jsonl"), row("a", t, "<synthetic>", 500) + &row("b", t - 9 * DAY, "claude-opus-5-5", 500)).unwrap();
        fs::create_dir_all(d.join("proj/subagents")).unwrap();
        fs::write(d.join("proj/subagents/x.jsonl"), row("c", t, "claude-opus-5-5", 1)).unwrap();
        let l = Scanner::new(d.clone()).scan();
        assert_eq!(l.week, 16);
        assert_eq!(l.active_sessions, 1);
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn hoje_comeca_no_fuso_local() {
        let n = now();
        let start = local_day_start(n);
        assert!(start <= n && n - start < DAY);
        assert_eq!(local_day_start(start), start);
    }

    #[test]
    fn limites_nas_duas_posicoes() {
        let a = r#"{"type":"assistant","message":{"usage_report":{"rate_limits":{"limits":[{"kind":"session","percent":23.5,"resets_at":"2026-11-09T20:00:00Z"}]}}}}"#;
        let l = parse_limits(a).unwrap();
        assert_eq!(l[0].kind, "session");
        assert_eq!(l[0].percent, 23.5);
        let b = r#"{"usage_report":{"rate_limits":{"limits":[{"kind":"weekly_scoped","scope":{"model":{"display_name":"Fable"},"surface":null},"percent":4,"resets_at":null}]}}}"#;
        assert_eq!(parse_limits(b).unwrap()[0].scope.as_deref(), Some("Fable"));
        assert!(parse_limits(r#"{"type":"assistant","usage_report":{"rate_limits":null}}"#).is_none());
        assert!(parse_limits("lixo").is_none());
    }

    #[test]
    fn familia_do_modelo() {
        assert_eq!(family("claude-opus-5-5"), "Opus");
        assert_eq!(family("claude-fable-5-1"), "Fable");
    }
}
