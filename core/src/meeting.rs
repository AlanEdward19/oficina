//! Reuniões transcritas no Mac. O app ouve e transcreve; o core guarda o
//! texto (nunca o áudio) e, se você pedir, resume com o Claude.

use serde::{Deserialize, Serialize};
use std::{fs, path::PathBuf, sync::Mutex};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Segment {
    /// "Você" (microfone) ou "Outros" (áudio do app da chamada).
    pub who: String,
    pub text: String,
    pub at: u64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Meeting {
    pub id: String,
    pub app: String,
    pub title: String,
    pub started: u64,
    pub ended: Option<u64>,
    pub segments: Vec<Segment>,
    pub summary: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MeetingItem {
    pub id: String,
    pub app: String,
    pub title: String,
    pub started: u64,
    pub ended: Option<u64>,
    pub words: usize,
    pub summarized: bool,
}

impl Meeting {
    fn item(&self) -> MeetingItem {
        MeetingItem {
            id: self.id.clone(),
            app: self.app.clone(),
            title: self.title.clone(),
            started: self.started,
            ended: self.ended,
            words: self.segments.iter().map(|s| s.text.split_whitespace().count()).sum(),
            summarized: self.summary.is_some(),
        }
    }

    /// A transcrição em texto corrido, juntando falas seguidas da mesma pessoa.
    pub fn transcript(&self) -> String {
        let mut out = String::new();
        let mut last: Option<&str> = None;
        for s in &self.segments {
            let text = s.text.trim();
            if text.is_empty() {
                continue;
            }
            if last == Some(s.who.as_str()) {
                out.push(' ');
            } else {
                if !out.is_empty() {
                    out.push('\n');
                }
                out.push_str(&format!("{}: ", s.who));
            }
            out.push_str(text);
            last = Some(&s.who);
        }
        out
    }

    pub fn summary_prompt(&self) -> String {
        // Uma reunião longa não pode estourar o pedido: fica o fim, que costuma ter as decisões.
        let full = self.transcript();
        let chars: Vec<char> = full.chars().collect();
        let text: String = if chars.len() > 60_000 { chars[chars.len() - 60_000..].iter().collect() } else { full };
        format!(
            "Resuma a transcrição da reunião \"{}\" ({}). Responda em português do Brasil, em Markdown, com três seções: \
## Decisões, ## Tarefas (uma por linha, com o dono quando der para saber) e ## Dúvidas em aberto. \
Seja curto. \"Você\" é o usuário; \"Outros\" são os demais participantes.\n\nTranscrição:\n{text}",
            self.title, self.app
        )
    }
}

pub struct Meetings {
    dir: PathBuf,
    index: Mutex<Vec<MeetingItem>>,
}

fn clean(s: &str, max: usize) -> String {
    s.trim().chars().filter(|c| !c.is_control()).take(max).collect()
}

impl Meetings {
    pub fn open(dir: PathBuf) -> Self {
        let _ = fs::create_dir_all(&dir);
        let mut index: Vec<MeetingItem> = fs::read_dir(&dir)
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
            .filter_map(|e| fs::read(e.path()).ok())
            .filter_map(|b| serde_json::from_slice::<Meeting>(&b).ok())
            .map(|m| m.item())
            .collect();
        index.sort_by_key(|m| std::cmp::Reverse(m.started));
        Self { dir, index: Mutex::new(index) }
    }

    fn path(&self, id: &str) -> Option<PathBuf> {
        let ok = !id.is_empty() && id.chars().all(|c| c.is_ascii_alphanumeric());
        ok.then(|| self.dir.join(format!("{id}.json")))
    }

    pub fn get(&self, id: &str) -> Option<Meeting> {
        serde_json::from_slice(&fs::read(self.path(id)?).ok()?).ok()
    }

    fn save(&self, m: &Meeting) {
        let Some(path) = self.path(&m.id) else { return };
        let tmp = path.with_extension("tmp");
        if fs::write(&tmp, serde_json::to_vec(m).unwrap_or_default()).is_ok() {
            let _ = fs::rename(tmp, path);
        }
        let mut index = self.index.lock().unwrap();
        index.retain(|i| i.id != m.id);
        index.insert(0, m.item());
        index.sort_by_key(|m| std::cmp::Reverse(m.started));
    }

    pub fn list(&self) -> Vec<MeetingItem> {
        self.index.lock().unwrap().clone()
    }

    pub fn start(&self, app: &str, title: &str, now: u64) -> Meeting {
        let app = clean(app, 60);
        let title = clean(title, 120);
        let m = Meeting {
            id: format!("m{:x}", crate::conv::next_id()),
            title: if title.is_empty() { format!("Chamada no {app}") } else { title },
            app,
            started: now,
            ..Default::default()
        };
        self.save(&m);
        m
    }

    pub fn append(&self, id: &str, segments: Vec<Segment>) -> bool {
        let Some(mut m) = self.get(id) else { return false };
        if m.ended.is_some() {
            return false;
        }
        for s in segments {
            let text = clean(&s.text, 4000);
            if text.is_empty() {
                continue;
            }
            let who = if s.who == "Você" { "Você" } else { "Outros" };
            m.segments.push(Segment { who: who.into(), text, at: s.at });
        }
        self.save(&m);
        true
    }

    /// Fecha a reunião. Devolve-a se tiver algo para resumir.
    pub fn end(&self, id: &str, now: u64) -> Option<Meeting> {
        let mut m = self.get(id)?;
        if m.ended.is_none() {
            m.ended = Some(now);
            self.save(&m);
        }
        Some(m)
    }

    pub fn set_summary(&self, id: &str, summary: String) {
        if let Some(mut m) = self.get(id) {
            m.summary = Some(summary);
            self.save(&m);
        }
    }

    pub fn delete(&self, id: &str) -> bool {
        let Some(path) = self.path(id) else { return false };
        let ok = fs::remove_file(path).is_ok();
        self.index.lock().unwrap().retain(|i| i.id != id);
        ok
    }

    /// "Esquecer tudo" apaga também as reuniões.
    pub fn forget(&self) {
        for m in self.list() {
            self.delete(&m.id);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn meetings() -> Meetings {
        let dir = std::env::temp_dir().join(format!("oficina-reunioes-{}-{:?}", std::process::id(), std::thread::current().id()));
        let _ = fs::remove_dir_all(&dir);
        Meetings::open(dir)
    }

    fn seg(who: &str, text: &str) -> Segment {
        Segment { who: who.into(), text: text.into(), at: 1 }
    }

    #[test]
    fn grava_junta_e_reabre() {
        let ms = meetings();
        let m = ms.start("Zoom", "", 100);
        assert_eq!(m.title, "Chamada no Zoom");
        assert!(ms.append(&m.id, vec![seg("Você", "oi"), seg("Você", "tudo bem?"), seg("Fulano", "tudo"), seg("Outros", " ")]));
        let got = ms.get(&m.id).unwrap();
        assert_eq!(got.transcript(), "Você: oi tudo bem?\nOutros: tudo");
        assert_eq!(ms.list()[0].words, 4);
        let ended = ms.end(&m.id, 200).unwrap();
        assert_eq!(ended.ended, Some(200));
        assert!(!ms.append(&m.id, vec![seg("Você", "depois do fim")]));
        let again = Meetings::open(ms.dir.clone());
        assert_eq!(again.list().len(), 1);
        assert!(again.get(&m.id).unwrap().summary_prompt().contains("## Decisões"));
    }

    #[test]
    fn id_estranho_nao_vira_caminho() {
        let ms = meetings();
        assert!(ms.get("../state").is_none());
        assert!(!ms.delete("a/b"));
    }

    #[test]
    fn esquecer_apaga_tudo() {
        let ms = meetings();
        ms.start("Teams", "Daily", 1);
        ms.start("Meet", "1:1", 2);
        assert_eq!(ms.list()[0].title, "1:1");
        ms.forget();
        assert!(ms.list().is_empty());
    }
}
