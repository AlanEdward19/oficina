//! Conversas: cada uma é uma sessão do próprio Claude Code (dá para continuar
//! lá depois) e guarda o histórico completo na Oficina, com cartões e links.

use crate::usage::now;
use serde::{Deserialize, Serialize};
use std::{
    fs,
    path::PathBuf,
    sync::{
        Mutex,
        atomic::{AtomicU64, Ordering},
    },
};

pub const NEW_TITLE: &str = "Nova conversa";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Conversation {
    pub id: String,
    pub title: String,
    /// Sessão do Claude Code por trás da conversa.
    pub session: Option<String>,
    pub created_at: u64,
    pub updated_at: u64,
}

pub struct Conversations {
    list: Mutex<Vec<Conversation>>,
    path: PathBuf,
    seq: AtomicU64,
}

fn ms() -> u64 {
    now() * 1000 + (std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.subsec_millis()).unwrap_or(0) as u64)
}

/// Só ids gerados aqui (letras e números) viram nome de arquivo.
pub fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 40 && id.chars().all(|c| c.is_ascii_alphanumeric())
}

/// Título a partir da primeira mensagem: uma linha, até 48 caracteres.
pub fn title_from(text: &str) -> String {
    let line = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut title: String = line.chars().take(48).collect();
    if line.chars().count() > 48 {
        title = title.trim_end().to_string() + "…";
    }
    if title.is_empty() { NEW_TITLE.into() } else { title }
}

impl Conversations {
    pub fn open(path: PathBuf) -> Self {
        let list = fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        Self { list: Mutex::new(list), path, seq: AtomicU64::new(0) }
    }

    fn save(&self, list: &[Conversation]) {
        if let Ok(bytes) = serde_json::to_vec(list) {
            let tmp = self.path.with_extension("tmp");
            if fs::write(&tmp, bytes).is_ok() {
                let _ = fs::rename(tmp, &self.path);
            }
        }
    }

    /// Mais recentes primeiro.
    pub fn list(&self) -> Vec<Conversation> {
        let mut v = self.list.lock().unwrap().clone();
        v.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
        v
    }

    pub fn get(&self, id: &str) -> Option<Conversation> {
        self.list.lock().unwrap().iter().find(|c| c.id == id).cloned()
    }

    pub fn create(&self, title: Option<&str>, created_at: Option<u64>) -> Conversation {
        let now = ms();
        let c = Conversation {
            id: format!("c{now:x}{:x}", self.seq.fetch_add(1, Ordering::Relaxed)),
            title: title.map(title_from).unwrap_or_else(|| NEW_TITLE.into()),
            session: None,
            created_at: created_at.unwrap_or(now),
            updated_at: created_at.unwrap_or(now),
        };
        let mut list = self.list.lock().unwrap();
        list.push(c.clone());
        self.save(&list);
        c
    }

    /// Nova mensagem: sobe na lista e, se ainda sem título, ganha um.
    pub fn touch(&self, id: &str, text: Option<&str>) {
        let mut list = self.list.lock().unwrap();
        if let Some(c) = list.iter_mut().find(|c| c.id == id) {
            c.updated_at = ms();
            if c.title == NEW_TITLE {
                if let Some(t) = text {
                    c.title = title_from(t);
                }
            }
        }
        self.save(&list);
    }

    pub fn set_session(&self, id: &str, session: Option<String>) {
        let mut list = self.list.lock().unwrap();
        if let Some(c) = list.iter_mut().find(|c| c.id == id) {
            if c.session != session {
                c.session = session;
                self.save(&list);
            }
        }
    }

    pub fn rename(&self, id: &str, title: &str) -> bool {
        let mut list = self.list.lock().unwrap();
        let Some(c) = list.iter_mut().find(|c| c.id == id) else { return false };
        c.title = title_from(title);
        self.save(&list);
        true
    }

    pub fn delete(&self, id: &str) -> bool {
        let mut list = self.list.lock().unwrap();
        let before = list.len();
        list.retain(|c| c.id != id);
        let removed = list.len() != before;
        if removed {
            self.save(&list);
        }
        removed
    }

    /// A conversa usada por último (para tarefas da própria Faísca).
    pub fn current(&self) -> Option<String> {
        self.list.lock().unwrap().iter().max_by_key(|c| c.updated_at).map(|c| c.id.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn convs() -> Conversations {
        let p = std::env::temp_dir().join(format!("oficina-conv-{}-{:?}.json", std::process::id(), std::thread::current().id()));
        let _ = fs::remove_file(&p);
        Conversations::open(p)
    }

    #[test]
    fn titulo_vem_da_primeira_mensagem() {
        let c = convs();
        let a = c.create(None, None);
        assert_eq!(a.title, NEW_TITLE);
        c.touch(&a.id, Some("  Me ajuda   a planejar o painel da cozinha com ESP32 e tela touch  "));
        assert_eq!(c.get(&a.id).unwrap().title, "Me ajuda a planejar o painel da cozinha com ESP3…");
        c.touch(&a.id, Some("outra coisa"));
        assert!(c.get(&a.id).unwrap().title.starts_with("Me ajuda"));
    }

    #[test]
    fn ordem_sessao_e_persistencia() {
        let c = convs();
        let a = c.create(Some("primeira"), None);
        std::thread::sleep(std::time::Duration::from_millis(3));
        let b = c.create(Some("segunda"), None);
        assert_eq!(c.list()[0].id, b.id);
        std::thread::sleep(std::time::Duration::from_millis(3));
        c.touch(&a.id, None);
        assert_eq!(c.current().unwrap(), a.id);
        c.set_session(&a.id, Some("s1".into()));
        let again = Conversations::open(c.path.clone());
        assert_eq!(again.get(&a.id).unwrap().session.as_deref(), Some("s1"));
        assert!(again.delete(&b.id) && !again.delete(&b.id));
    }

    #[test]
    fn ids_seguros() {
        assert!(valid_id("c18f3a2b0"));
        assert!(!valid_id("../x") && !valid_id("") && !valid_id("a/b"));
    }
}
