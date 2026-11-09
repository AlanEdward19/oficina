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
pub struct ProjectUse {
    pub name: String,
    pub path: String,
    pub branch: Option<String>,
    pub today: u64,
    pub week: u64,
    pub last: u64,
}

#[derive(Clone, Default, Serialize)]
pub struct Local {
    pub today: u64,
    pub week: u64,
    pub models: Vec<ModelUse>,
    pub active_sessions: usize,
    /// Projetos em que você atuou com o Claude Code, do mais recente ao mais antigo.
    pub projects: Vec<ProjectUse>,
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
    cwd: Option<String>,
    #[serde(rename = "gitBranch")]
    branch: Option<String>,
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

/// Respostas recentes, para não contar duas vezes a mesma resposta (que é
/// gravada várias vezes seguidas, a última com o total final).
const RECENT: usize = 4096;

pub struct Scanner {
    root: PathBuf,
    offsets: HashMap<PathBuf, u64>,
    /// Totais por (hora desde 1970, modelo): poucos KB em vez de uma entrada por resposta.
    buckets: HashMap<(u32, u16), u64>,
    recent: HashMap<u64, (u32, u16, u16, u64)>,
    project_buckets: HashMap<(u32, u16), u64>,
    project_paths: Vec<String>,
    project_last: HashMap<u16, (u64, Option<String>)>,
    order: std::collections::VecDeque<u64>,
    models: Vec<String>,
    active: usize,
}

impl Scanner {
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            offsets: HashMap::new(),
            buckets: HashMap::new(),
            recent: HashMap::new(),
            project_buckets: HashMap::new(),
            project_paths: Vec::new(),
            project_last: HashMap::new(),
            order: std::collections::VecDeque::new(),
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
        let oldest = (now.saturating_sub(RETENTION) / 3600) as u32;
        self.buckets.retain(|(hour, _), _| *hour >= oldest);
        self.project_buckets.retain(|(hour, _), _| *hour >= oldest);
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
        let hour = (ts / 3600) as u32;
        let key = h.finish();
        // A mesma resposta é gravada várias vezes; a última tem o total final.
        let project = self.project_index(row.cwd.as_deref().unwrap_or(""));
        if let Some((h0, m0, p0, t0)) = self.recent.insert(key, (hour, model, project, tokens)) {
            if let Some(b) = self.buckets.get_mut(&(h0, m0)) {
                *b = b.saturating_sub(t0);
            }
            if let Some(b) = self.project_buckets.get_mut(&(h0, p0)) {
                *b = b.saturating_sub(t0);
            }
        } else {
            self.order.push_back(key);
            if self.order.len() > RECENT {
                if let Some(old) = self.order.pop_front() {
                    self.recent.remove(&old);
                }
            }
        }
        *self.buckets.entry((hour, model)).or_default() += tokens;
        *self.project_buckets.entry((hour, project)).or_default() += tokens;
        let last = self.project_last.entry(project).or_insert((0, None));
        if ts >= last.0 {
            *last = (ts, row.branch.filter(|b| !b.is_empty() && b != "HEAD"));
        }
    }

    fn project_index(&mut self, path: &str) -> u16 {
        if let Some(i) = self.project_paths.iter().position(|p| p == path) {
            return i as u16;
        }
        self.project_paths.push(path.to_string());
        (self.project_paths.len() - 1) as u16
    }

    /// Projetos reais: worktrees e subpastas contam para o projeto raiz; a
    /// pasta interna da Oficina e temporárias ficam de fora.
    fn projects_summary(&self, day_hour: u32, week_hour: u32) -> Vec<ProjectUse> {
        let roots: Vec<Option<String>> = {
            let bases: Vec<Option<String>> = self.project_paths.iter().map(|p| project_base(p)).collect();
            let known: Vec<&String> = bases.iter().flatten().filter(|b| !is_container(b)).collect();
            bases
                .iter()
                .map(|b| {
                    b.as_ref().map(|b| {
                        known
                            .iter()
                            .filter(|k| b.starts_with(&format!("{k}/")))
                            .min_by_key(|k| k.len())
                            .map(|k| k.to_string())
                            .unwrap_or_else(|| b.clone())
                    })
                })
                .collect()
        };
        let mut grouped: HashMap<String, ProjectUse> = HashMap::new();
        for (i, root) in roots.iter().enumerate() {
            let Some(root) = root else { continue };
            let i = i as u16;
            let p = grouped.entry(root.clone()).or_insert_with(|| ProjectUse {
                name: root.rsplit('/').next().unwrap_or(root).to_string(),
                path: root.clone(),
                branch: None,
                today: 0,
                week: 0,
                last: 0,
            });
            for (&(hour, project), &tokens) in &self.project_buckets {
                if project == i && hour >= week_hour {
                    p.week += tokens;
                    if hour >= day_hour {
                        p.today += tokens;
                    }
                }
            }
            if let Some((last, branch)) = self.project_last.get(&i) {
                // Branches de worktree temporária não dizem em que você está.
                let useful = branch.as_ref().filter(|b| !b.starts_with("worktree-"));
                if useful.is_some() && (*last >= p.last || p.branch.is_none()) {
                    p.branch = useful.cloned();
                }
                p.last = p.last.max(*last);
            }
        }
        let mut out: Vec<ProjectUse> = grouped.into_values().filter(|p| p.week > 0).collect();
        out.sort_by(|a, b| b.last.cmp(&a.last));
        out.truncate(12);
        out
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
        let (week_hour, day_hour) = ((week_start / 3600) as u32, (day_start / 3600) as u32);
        for (&(hour, model), &tokens) in self.buckets.iter().filter(|((h, _), _)| *h >= week_hour) {
            week += tokens;
            by_model[model as usize] += tokens;
            if hour >= day_hour {
                today += tokens;
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
            projects: self.projects_summary(day_hour, week_hour),
        }
    }
}

/// Raiz de um caminho de trabalho, ou None se não é um projeto.
fn project_base(path: &str) -> Option<String> {
    if path.is_empty() || path.contains("Application Support/Oficina") || path.starts_with("/private/") || path.starts_with("/tmp") {
        return None;
    }
    if let Some(i) = path.find("/.claude/worktrees/") {
        return Some(path[..i].to_string());
    }
    if path.contains("/.claude/") || path.ends_with("/.claude") {
        return None;
    }
    Some(path.to_string())
}

/// Pasta que guarda vários projetos: não absorve as de dentro.
fn is_container(path: &str) -> bool {
    let base = path.rsplit('/').next().unwrap_or("").to_lowercase();
    path.matches('/').count() <= 2 || ["desktop", "projects", "projetos", "developer", "code", "repos", "src", "documents", "downloads", "work"].contains(&base.as_str())
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
    fn agrupa_worktrees_e_subpastas_no_projeto() {
        let d = dir();
        let t = now() - 10;
        let line = |id: &str, cwd: &str, branch: &str| {
            row(id, t, "claude-opus-5-5", 5).replacen("{\"type\":\"assistant\",", &format!("{{\"type\":\"assistant\",\"cwd\":\"{cwd}\",\"gitBranch\":\"{branch}\","), 1)
        };
        let body = line("a", "/Users/x/Projects/Vida", "main")
            + &line("b", "/Users/x/Projects/Vida/.claude/worktrees/agent-1", "worktree-agent-1")
            + &line("c", "/Users/x/Projects/Vida/core/src", "main")
            + &line("d", "/Users/x/Projects", "")
            + &line("e", "/Users/x/Projects/Outro", "dev")
            + &line("f", "/Users/x/.claude/spares/y", "z");
        fs::write(d.join("proj/s.jsonl"), body).unwrap();
        let l = Scanner::new(d.clone()).scan();
        let vida = l.projects.iter().find(|p| p.name == "Vida").unwrap();
        assert_eq!(vida.week, 60);
        assert_eq!(vida.branch.as_deref(), Some("main"));
        assert!(l.projects.iter().any(|p| p.name == "Outro"));
        assert!(!l.projects.iter().any(|p| p.name == "y" || p.name == "agent-1" || p.name == "src"));
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn reconhece_projetos_pelo_cwd() {
        let d = dir();
        let t = now() - 10;
        let line = |id: &str, cwd: &str, branch: &str| {
            row(id, t, "claude-opus-5-5", 5).replacen("{\"type\":\"assistant\",", &format!("{{\"type\":\"assistant\",\"cwd\":\"{cwd}\",\"gitBranch\":\"{branch}\","), 1)
        };
        fs::write(d.join("proj/s.jsonl"), line("a", "/Users/x/Oficina", "main") + &line("b", "/Users/x/Oficina", "dock") + &line("c", "/private/tmp/y", "z")).unwrap();
        let l = Scanner::new(d.clone()).scan();
        assert_eq!(l.projects.len(), 1);
        assert_eq!(l.projects[0].name, "Oficina");
        assert_eq!(l.projects[0].week, 40);
        assert_eq!(l.projects[0].branch.as_deref(), Some("dock"));
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
