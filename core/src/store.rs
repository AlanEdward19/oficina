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
    pub fn open(path: PathBuf) -> Arc<Self> {
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
            tx: broadcast::channel(256).0,
            dirty: Notify::new(),
            path,
            seq: AtomicU64::new(0),
        })
    }

    pub fn create(&self, text: String, target: Target, machine: Option<String>) -> Task {
        let now = now_ms();
        let task = Task {
            id: format!("t{now:x}{:x}", self.seq.fetch_add(1, Ordering::Relaxed)),
            text,
            target,
            machine,
            prompt: None,
            status: Status::Queued,
            output: String::new(),
            url: None,
            error: None,
            created_at: now,
            updated_at: now,
        };
        {
            let mut tasks = self.tasks.lock().unwrap();
            tasks.push(task.clone());
            while tasks.len() > MAX_TASKS {
                match tasks.iter().position(|t| t.status.is_terminal()) {
                    Some(i) => tasks.remove(i),
                    None => break,
                };
            }
        }
        self.publish(task.clone());
        task
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
