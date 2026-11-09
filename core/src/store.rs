use serde::{Deserialize, Serialize};
use std::{
    fs,
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::sync::{Notify, broadcast};

const MAX_TASKS: usize = 200;
const MAX_OUTPUT: usize = 256 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Target {
    Auto,
    Chat,
    Cloud,
    Machine,
    /// Pedido de melhoria: vira uma issue no GitHub.
    Request,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Queued,
    AwaitingApproval,
    Running,
    Done,
    Failed,
    Cancelled,
}

impl Status {
    pub fn is_terminal(self) -> bool {
        matches!(self, Status::Done | Status::Failed | Status::Cancelled)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Task {
    pub id: String,
    pub text: String,
    pub target: Target,
    pub machine: Option<String>,
    /// Conversa a que a tarefa pertence.
    #[serde(default)]
    pub conversation: Option<String>,
    /// Tipo do pedido de melhoria (funcionalidade, widget, roupa, casa, bug).
    #[serde(default)]
    pub kind: Option<String>,
    /// Instrução que o cérebro escreveu ao delegar; aguarda aprovação.
    pub prompt: Option<String>,
    pub status: Status,
    pub output: String,
    pub url: Option<String>,
    pub error: Option<String>,
    pub created_at: u64,
    pub updated_at: u64,
}

#[derive(Clone, Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Event {
    Task { task: Task },
    Delta { id: String, text: String },
    Usage { usage: crate::usage::Usage },
    Mind { mind: crate::mind::Brief },
}

pub struct Store {
    tasks: Mutex<Vec<Task>>,
    /// Onde ficam as mensagens antigas de cada conversa.
    archive: PathBuf,
    pub tx: broadcast::Sender<Event>,
    dirty: Notify,
    path: PathBuf,
    seq: AtomicU64,
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

impl Store {
    pub fn open(path: PathBuf, archive: PathBuf) -> Arc<Self> {
        let _ = fs::create_dir_all(&archive);
        let mut tasks: Vec<Task> = fs::read(&path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        for t in &mut tasks {
            if matches!(t.status, Status::Queued | Status::Running) {
                t.status = Status::Failed;
                t.error = Some("Interrompida: o core foi reiniciado.".into());
            }
        }
        Arc::new(Self {
            tasks: Mutex::new(tasks),
            archive,
            tx: broadcast::channel(256).0,
            dirty: Notify::new(),
            path,
            seq: AtomicU64::new(0),
        })
    }

    pub fn create(&self, text: String, target: Target, machine: Option<String>, conversation: Option<String>) -> Task {
        let now = now_ms();
        let task = Task {
            id: format!("t{now:x}{:x}", self.seq.fetch_add(1, Ordering::Relaxed)),
            text,
            target,
            machine,
            conversation,
            kind: None,
            prompt: None,
            status: Status::Queued,
            output: String::new(),
            url: None,
            error: None,
            created_at: now,
            updated_at: now,
        };
        let evicted = {
            let mut tasks = self.tasks.lock().unwrap();
            tasks.push(task.clone());
            let mut out = Vec::new();
            while tasks.len() > MAX_TASKS {
                match tasks.iter().position(|t| t.status.is_terminal()) {
                    Some(i) => out.push(tasks.remove(i)),
                    None => break,
                };
            }
            out
        };
        // As mais antigas saem da memória e vão para o arquivo da conversa.
        for t in evicted {
            self.archive_task(&t);
        }
        self.publish(task.clone());
        task
    }

    fn archive_file(&self, conversation: &str) -> PathBuf {
        self.archive.join(format!("{conversation}.jsonl"))
    }

    fn archive_task(&self, t: &Task) {
        let Some(conv) = t.conversation.as_deref().filter(|c| crate::conv::valid_id(c)) else { return };
        if let Ok(mut line) = serde_json::to_vec(t) {
            line.push(b'\n');
            use std::io::Write;
            if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(self.archive_file(conv)) {
                let _ = f.write_all(&line);
            }
        }
    }

    /// Histórico completo de uma conversa: arquivo + o que está em memória.
    pub fn history(&self, conversation: &str) -> Vec<Task> {
        let mut out: Vec<Task> = fs::read(self.archive_file(conversation))
            .map(|b| b.split(|c| *c == b'\n').filter_map(|l| serde_json::from_slice(l).ok()).collect())
            .unwrap_or_default();
        let live: Vec<Task> = self.tasks.lock().unwrap().iter().filter(|t| t.conversation.as_deref() == Some(conversation)).cloned().collect();
        out.retain(|t| !live.iter().any(|l| l.id == t.id));
        out.extend(live);
        out.sort_by_key(|t| t.created_at);
        out
    }

    /// Apaga as mensagens de uma conversa (a sessão do Claude continua lá).
    pub fn forget_conversation(&self, conversation: &str) {
        self.tasks.lock().unwrap().retain(|t| t.conversation.as_deref() != Some(conversation));
        let _ = fs::remove_file(self.archive_file(conversation));
        self.dirty.notify_one();
    }

    /// Tarefas antigas, de antes das conversas, ganham uma conversa.
    pub fn adopt_orphans(&self, conversation: &str) -> usize {
        let mut tasks = self.tasks.lock().unwrap();
        let mut n = 0;
        for t in tasks.iter_mut().filter(|t| t.conversation.is_none()) {
            t.conversation = Some(conversation.to_string());
            n += 1;
        }
        drop(tasks);
        if n > 0 {
            self.dirty.notify_one();
        }
        n
    }

    pub fn has_orphans(&self) -> Option<u64> {
        self.tasks.lock().unwrap().iter().filter(|t| t.conversation.is_none()).map(|t| t.created_at).min()
    }

    pub fn get(&self, id: &str) -> Option<Task> {
        self.tasks.lock().unwrap().iter().find(|t| t.id == id).cloned()
    }

    pub fn list(&self) -> Vec<Task> {
        self.tasks.lock().unwrap().clone()
    }

    pub fn update(&self, id: &str, f: impl FnOnce(&mut Task)) -> Option<Task> {
        let task = {
            let mut tasks = self.tasks.lock().unwrap();
            let t = tasks.iter_mut().find(|t| t.id == id)?;
            f(t);
            t.updated_at = now_ms();
            t.clone()
        };
        self.publish(task.clone());
        Some(task)
    }

    /// Acrescenta texto em streaming, sem reenviar a tarefa inteira.
    pub fn append(&self, id: &str, text: &str) {
        {
            let mut tasks = self.tasks.lock().unwrap();
            let Some(t) = tasks.iter_mut().find(|t| t.id == id) else {
                return;
            };
            if t.output.len() + text.len() > MAX_OUTPUT {
                return;
            }
            t.output.push_str(text);
        }
        self.dirty.notify_one();
        let _ = self.tx.send(Event::Delta {
            id: id.into(),
            text: text.into(),
        });
    }

    fn publish(&self, task: Task) {
        self.dirty.notify_one();
        let _ = self.tx.send(Event::Task { task });
    }

    /// Sem acordar à toa: só grava depois que algo mudou.
    pub async fn persist_loop(self: Arc<Self>) {
        loop {
            self.dirty.notified().await;
            tokio::time::sleep(Duration::from_secs(1)).await;
            if let Err(e) = self.flush() {
                eprintln!("oficinad: falha ao gravar estado: {e}");
            }
        }
    }

    pub fn flush(&self) -> std::io::Result<()> {
        let bytes = serde_json::to_vec(&*self.tasks.lock().unwrap())?;
        let tmp = self.path.with_extension("tmp");
        fs::write(&tmp, bytes)?;
        fs::rename(tmp, &self.path)
    }
}
