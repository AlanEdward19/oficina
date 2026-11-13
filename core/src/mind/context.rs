//! O que você está fazendo agora, sem olhar a tela: o projeto do Claude Code
//! mais recente, o estado do git dele, o PR do branch e se há uma chamada.
//! Só nomes, contagens e assuntos de commit; nunca conteúdo de arquivo.

use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    path::Path,
    process::{Command, Stdio},
};

/// Retrato do git de um projeto.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct GitInfo {
    pub branch: Option<String>,
    /// Arquivos alterados e ainda sem commit.
    pub dirty: usize,
    pub last_commit: u64,
    /// Assuntos dos últimos commits, do mais novo ao mais antigo.
    pub subjects: Vec<String>,
    pub languages: Vec<String>,
}

/// Um PR do branch atual com checagens que falharam.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct FailingPr {
    pub number: u64,
    pub url: String,
    pub checks: Vec<String>,
}

/// O que a mente recebe a cada leitura do contexto.
#[derive(Clone, Debug, Default)]
pub struct WorkInput {
    pub project: Option<String>,
    pub path: Option<String>,
    /// Última atividade no projeto pelos logs do Claude Code.
    pub last: u64,
    pub git: Option<GitInfo>,
    pub failing: Option<FailingPr>,
}

/// O que as telas e o cérebro veem.
#[derive(Clone, Debug, Default, Serialize)]
pub struct WorkContext {
    pub project: Option<String>,
    pub path: Option<String>,
    pub branch: Option<String>,
    pub languages: Vec<String>,
    /// programando, revisando, reunião, lendo, pausa
    pub activity: String,
    pub since: u64,
    pub dirty: usize,
    pub last_commit: u64,
    pub subjects: Vec<String>,
    pub call: Option<String>,
    pub pending: Vec<String>,
    pub agenda: Option<String>,
}

/// O dia em blocos: tempo por projeto e em reunião. Só números.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Diary {
    /// AAAAMMDD local.
    pub day: u32,
    pub projects: BTreeMap<String, f64>,
    pub meeting_secs: f64,
    pub meetings: u32,
    pub shown: bool,
    /// O resumo do dia anterior, em uma frase.
    pub yesterday: Option<String>,
}

impl Diary {
    /// Vira o dia: guarda a frase de ontem e zera.
    pub fn roll(&mut self, day: u32) {
        if self.day == day {
            return;
        }
        if self.day != 0 {
            self.yesterday = self.sentence();
        }
        let yesterday = self.yesterday.take();
        *self = Diary { day, yesterday, ..Default::default() };
    }

    pub fn total(&self) -> f64 {
        self.projects.values().sum()
    }

    /// "3 h 10 min no oficina, 40 min no site e 1 reunião (25 min)."
    pub fn sentence(&self) -> Option<String> {
        let mut items: Vec<(&String, &f64)> = self.projects.iter().filter(|(_, s)| **s >= 300.0).collect();
        items.sort_by(|a, b| b.1.total_cmp(a.1));
        let mut parts: Vec<String> = items.iter().take(4).map(|(p, s)| format!("{} no {p}", super::memory::human_minutes(**s / 60.0))).collect();
        if self.meetings > 0 {
            let n = if self.meetings == 1 { "1 reunião".to_string() } else { format!("{} reuniões", self.meetings) };
            parts.push(format!("{n} ({})", super::memory::human_minutes(self.meeting_secs / 60.0)));
        }
        match parts.len() {
            0 => None,
            1 => Some(format!("{}.", parts[0])),
            _ => {
                let last = parts.pop().unwrap();
                Some(format!("{} e {last}.", parts.join(", ")))
            }
        }
    }
}

const LANGS: &[(&str, &str)] = &[
    ("rs", "Rust"), ("swift", "Swift"), ("ts", "TypeScript"), ("tsx", "TypeScript"), ("js", "JavaScript"), ("jsx", "JavaScript"),
    ("py", "Python"), ("go", "Go"), ("java", "Java"), ("kt", "Kotlin"), ("cs", "C#"), ("c", "C"), ("h", "C"), ("cpp", "C++"),
    ("rb", "Ruby"), ("php", "PHP"), ("dart", "Dart"), ("sql", "SQL"), ("md", "Markdown"), ("html", "HTML"), ("css", "CSS"),
    ("ino", "Arduino"), ("ato", "atopile"), ("kicad_sch", "KiCad"), ("scad", "OpenSCAD"),
];

/// Linguagens pelos nomes dos arquivos, da mais frequente à menos.
pub fn languages<'a>(files: impl IntoIterator<Item = &'a str>) -> Vec<String> {
    let mut count: BTreeMap<&str, usize> = BTreeMap::new();
    for f in files {
        let Some(ext) = Path::new(f).extension().and_then(|e| e.to_str()) else { continue };
        let ext = ext.to_ascii_lowercase();
        if let Some((_, lang)) = LANGS.iter().find(|(e, _)| *e == ext) {
            *count.entry(lang).or_default() += 1;
        }
    }
    let mut v: Vec<(&str, usize)> = count.into_iter().collect();
    v.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(b.0)));
    v.into_iter().take(3).map(|(l, _)| l.to_string()).collect()
}

/// Nomes dos arquivos em `git status --porcelain`.
pub fn porcelain_files(out: &str) -> Vec<String> {
    out.lines()
        .filter(|l| l.len() > 3)
        .map(|l| {
            let path = &l[3..];
            // Renomeado: "antigo -> novo".
            path.rsplit(" -> ").next().unwrap_or(path).trim_matches('"').to_string()
        })
        .collect()
}

fn git(dir: &Path, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Lê o git do projeto. Bloqueia: chame fora do runtime.
pub fn git_info(dir: &Path) -> Option<GitInfo> {
    let branch = git(dir, &["rev-parse", "--abbrev-ref", "HEAD"])?.trim().to_string();
    let status = git(dir, &["status", "--porcelain"]).unwrap_or_default();
    let mut files = porcelain_files(&status);
    let log = git(dir, &["log", "-5", "--format=%ct%x09%s"]).unwrap_or_default();
    let mut last_commit = 0;
    let mut subjects = Vec::new();
    for (i, line) in log.lines().enumerate() {
        let (ts, subject) = line.split_once('\t').unwrap_or(("0", line));
        if i == 0 {
            last_commit = ts.parse().unwrap_or(0);
        }
        subjects.push(subject.chars().take(100).collect());
    }
    if files.is_empty() {
        let recent = git(dir, &["log", "-10", "--name-only", "--format="]).unwrap_or_default();
        files = recent.lines().filter(|l| !l.is_empty()).map(String::from).collect();
    }
    Some(GitInfo {
        branch: (branch != "HEAD").then_some(branch),
        dirty: porcelain_files(&status).len(),
        last_commit,
        subjects,
        languages: languages(files.iter().map(String::as_str)),
    })
}

/// Lê a resposta de `gh pr view --json number,url,statusCheckRollup`.
pub fn failing_pr(json: &str) -> Option<FailingPr> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    let checks: Vec<String> = v["statusCheckRollup"]
        .as_array()?
        .iter()
        .filter(|c| {
            let state = c["conclusion"].as_str().or(c["state"].as_str()).unwrap_or("").to_ascii_uppercase();
            matches!(state.as_str(), "FAILURE" | "ERROR" | "TIMED_OUT" | "CANCELLED" | "ACTION_REQUIRED")
        })
        .map(|c| c["name"].as_str().or(c["context"].as_str()).unwrap_or("checagem").to_string())
        .collect();
    if checks.is_empty() {
        return None;
    }
    Some(FailingPr { number: v["number"].as_u64()?, url: v["url"].as_str().unwrap_or("").to_string(), checks })
}

/// O que você está fazendo, por regras simples.
pub fn activity(call: bool, idle: f64, working: bool, recent_project: bool, browsing: bool, pr_open: bool) -> &'static str {
    if call {
        "reunião"
    } else if idle > 120.0 {
        "pausa"
    } else if working && recent_project {
        "programando"
    } else if browsing && pr_open {
        "revisando"
    } else if working {
        "programando"
    } else {
        "lendo"
    }
}

const BROWSERS: &[&str] = &["safari", "chrome", "firefox", "arc", "brave", "edge", "opera", "orion", "vivaldi"];

pub fn is_browser(bundle: &str, name: &str) -> bool {
    let b = format!("{} {}", bundle.to_lowercase(), name.to_lowercase());
    BROWSERS.iter().any(|h| b.contains(h))
}

/// Frase para o cérebro.
pub fn summary(c: &WorkContext) -> String {
    let mut parts = Vec::new();
    if let Some(p) = &c.project {
        let branch = c.branch.as_ref().map(|b| format!(", branch {b}")).unwrap_or_default();
        let langs = if c.languages.is_empty() { String::new() } else { format!(", em {}", c.languages.join(" e ")) };
        parts.push(format!("Agora o usuário está {} no projeto {p}{branch}{langs}.", c.activity));
        if c.dirty > 0 {
            parts.push(format!("Há {} arquivo(s) alterado(s) sem commit.", c.dirty));
        }
        if !c.subjects.is_empty() {
            parts.push(format!("Últimos commits: {}.", c.subjects.iter().take(3).cloned().collect::<Vec<_>>().join("; ")));
        }
    } else if !c.activity.is_empty() {
        parts.push(format!("Agora o usuário está {}.", c.activity));
    }
    if let Some(app) = &c.call {
        parts.push(format!("Ele está numa chamada no {app}."));
    }
    if !c.pending.is_empty() {
        parts.push(format!("Pendências: {}.", c.pending.join("; ")));
    }
    parts.join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn linguagens_pelos_arquivos() {
        let l = languages(["a.rs", "b.rs", "c.swift", "README", "d.RS"]);
        assert_eq!(l, vec!["Rust", "Swift"]);
    }

    #[test]
    fn porcelain_com_renomeado() {
        let f = porcelain_files(" M core/src/a.rs\nR  velho.rs -> novo.rs\n?? \"com espaço.md\"\n");
        assert_eq!(f, vec!["core/src/a.rs", "novo.rs", "com espaço.md"]);
    }

    #[test]
    fn pr_com_checagem_falhando() {
        let json = r#"{"number":42,"url":"https://github.com/o/r/pull/42","statusCheckRollup":[
            {"name":"build","conclusion":"FAILURE"},{"name":"lint","conclusion":"SUCCESS"},{"context":"ci/x","state":"ERROR"}]}"#;
        let pr = failing_pr(json).unwrap();
        assert_eq!(pr.number, 42);
        assert_eq!(pr.checks, vec!["build", "ci/x"]);
        assert!(failing_pr(r#"{"number":1,"url":"","statusCheckRollup":[{"name":"a","conclusion":"SUCCESS"}]}"#).is_none());
    }

    #[test]
    fn atividade_por_regras() {
        assert_eq!(activity(true, 0.0, true, true, false, false), "reunião");
        assert_eq!(activity(false, 300.0, true, true, false, false), "pausa");
        assert_eq!(activity(false, 0.0, true, true, false, false), "programando");
        assert_eq!(activity(false, 0.0, false, false, true, true), "revisando");
        assert_eq!(activity(false, 0.0, false, false, true, false), "lendo");
    }

    #[test]
    fn diario_vira_o_dia_e_resume() {
        let mut d = Diary::default();
        d.roll(20261112);
        d.projects.insert("oficina".into(), 3.0 * 3600.0 + 600.0);
        d.projects.insert("site".into(), 2400.0);
        d.projects.insert("rapidinho".into(), 60.0);
        d.meetings = 1;
        d.meeting_secs = 1500.0;
        assert_eq!(d.sentence().unwrap(), "3 h 10 min no oficina, 40 min no site e 1 reunião (25 min).");
        d.roll(20261113);
        assert_eq!(d.yesterday.as_deref(), Some("3 h 10 min no oficina, 40 min no site e 1 reunião (25 min)."));
        assert!(d.projects.is_empty());
        assert!(d.sentence().is_none());
    }

    #[test]
    fn git_de_um_repositorio_sintetico() {
        let dir = std::env::temp_dir().join(format!("oficina-ctx-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let run = |args: &[&str]| {
            Command::new("git").arg("-C").arg(&dir).args(args)
                .env("GIT_AUTHOR_NAME", "t").env("GIT_AUTHOR_EMAIL", "t@t").env("GIT_COMMITTER_NAME", "t").env("GIT_COMMITTER_EMAIL", "t@t")
                .stdout(Stdio::null()).stderr(Stdio::null()).status().unwrap()
        };
        if !run(&["init", "-q", "-b", "feat/x"]).success() {
            return; // sem git na máquina de teste
        }
        std::fs::write(dir.join("main.rs"), "fn main() {}").unwrap();
        run(&["add", "."]);
        run(&["commit", "-qm", "feat: começo"]);
        std::fs::write(dir.join("lib.swift"), "").unwrap();
        let g = git_info(&dir).unwrap();
        assert_eq!(g.branch.as_deref(), Some("feat/x"));
        assert_eq!(g.dirty, 1);
        assert_eq!(g.subjects, vec!["feat: começo"]);
        assert!(g.last_commit > 0);
        assert_eq!(g.languages, vec!["Swift"]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn resumo_para_o_cerebro() {
        let c = WorkContext {
            project: Some("oficina".into()),
            branch: Some("feat/dock".into()),
            languages: vec!["Swift".into()],
            activity: "programando".into(),
            dirty: 2,
            call: Some("Zoom".into()),
            ..Default::default()
        };
        let s = summary(&c);
        assert!(s.contains("programando no projeto oficina, branch feat/dock, em Swift"));
        assert!(s.contains("2 arquivo(s)"));
        assert!(s.contains("chamada no Zoom"));
    }
}
