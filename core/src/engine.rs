use crate::{
    config::{Config, Paths, Peer},
    conv::Conversations,
    peer,
    mind::{Action, Initiative, Mind, decor, outfit},
    route::{self, CliEvent, Dest, Holdback},
    store::{Event, Status, Store, Target, Task},
    usage::{self, Scanner, Usage},
};
use serde::Serialize;
use std::{
    collections::HashMap,
    path::PathBuf,
    process::Stdio,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    process::Command,
    sync::Semaphore,
};

const BRAIN_BASE: &str = "Você é a Faísca, assistente pessoal que vive no Mac do usuário. \
Responda em português do Brasil, curto e direto. Você não tem ferramentas nesta conversa.";

const BRAIN_DELEGATE: &str = " Se o pedido exigir trabalho real (programar, pesquisar a fundo, \
mexer em arquivos), não finja que fez: responda SOMENTE com uma linha no formato \
`@@delegar nuvem: <instrução completa>` para agentes na nuvem, ou \
`@@delegar maquina: <instrução completa>` quando precisar do computador do usuário. \
Sem texto antes ou depois da linha. Conversa e perguntas simples você responde normalmente. \
Se o usuário pedir uma melhoria em você mesma ou na Oficina (funcionalidade nova, widget da Dock, roupinha, \
casinha, ou um problema), responda SOMENTE com `@@delegar melhoria: <funcionalidade|widget|roupa|casa|bug>: \
<descrição clara do pedido>`.";

pub struct Engine {
    pub store: Arc<Store>,
    pub cfg: Config,
    pub paths: Paths,
    pub name: String,
    claude: PathBuf,
    /// Uma fila por conversa: duas conversas não esperam uma pela outra.
    brains: Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
    pub convs: Conversations,
    local: Semaphore,
    running: Mutex<HashMap<String, i32>>,
    usage: Mutex<Usage>,
    scanner: Arc<Mutex<Scanner>>,
    refreshing: AtomicBool,
    pub mind: Arc<Mind>,
}

#[derive(Serialize)]
pub struct Machine {
    pub name: String,
    pub online: bool,
    pub is_self: bool,
}

enum Where {
    Local,
    Remote(Peer),
}

struct RunOut {
    text: String,
    session: Option<String>,
}

/// Procura o `claude` também onde um app gráfico não enxerga pelo PATH.
fn find_gh() -> PathBuf {
    if let Some(p) = std::env::var_os("OFICINA_GH") {
        return PathBuf::from(p);
    }
    ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        .into_iter()
        .map(PathBuf::from)
        .find(|p| p.exists())
        .unwrap_or_else(|| PathBuf::from("gh"))
}

fn find_claude() -> PathBuf {
    if let Some(p) = std::env::var_os("OFICINA_CLAUDE") {
        return PathBuf::from(p);
    }
    let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
    [
        PathBuf::from("/opt/homebrew/bin/claude"),
        PathBuf::from("/usr/local/bin/claude"),
        home.join(".local/bin/claude"),
        home.join(".claude/local/claude"),
    ]
    .into_iter()
    .find(|p| p.exists())
    .unwrap_or_else(|| PathBuf::from("claude"))
}

fn claude_projects() -> PathBuf {
    if let Some(p) = std::env::var_os("OFICINA_CLAUDE_PROJECTS") {
        return PathBuf::from(p);
    }
    std::env::var_os("CLAUDE_CONFIG_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".claude"))
        .join("projects")
}

fn hostname() -> String {
    // O hostname do Mac muda com a rede (pode virar o IP do DHCP).
    let named = std::process::Command::new("/usr/sbin/scutil")
        .args(["--get", "ComputerName"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty());
    if let Some(name) = named {
        return name;
    }
    let mut buf = [0u8; 256];
    // SAFETY: o buffer é válido e seu tamanho é informado à chamada.
    let ok = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) } == 0;
    let end = buf.iter().position(|b| *b == 0).unwrap_or(0);
    let name = String::from_utf8_lossy(&buf[..end]);
    if ok && !name.is_empty() {
        name.trim_end_matches(".local").to_string()
    } else {
        "este-mac".into()
    }
}

/// Garante que o CLI use o login da assinatura, sem herdar chave de API nem
/// o contexto de outra sessão do Claude Code.
fn claude_cmd(path: &PathBuf) -> Command {
    let mut cmd = Command::new(path);
    for (key, _) in std::env::vars_os() {
        let k = key.to_string_lossy();
        if k.starts_with("ANTHROPIC_")
            || k == "CLAUDECODE"
            || (k.starts_with("CLAUDE_") && k != "CLAUDE_CONFIG_DIR")
        {
            cmd.env_remove(&key);
        }
    }
    cmd.kill_on_drop(true).process_group(0);
    cmd
}

const STREAM_ARGS: [&str; 6] = [
    "-p",
    "--output-format",
    "stream-json",
    "--verbose",
    "--include-partial-messages",
    "--strict-mcp-config",
];

impl Engine {
    pub fn new(store: Arc<Store>, cfg: Config, paths: Paths) -> Arc<Self> {
        let local = Semaphore::new(cfg.max_local_tasks.max(1));
        let mind = Arc::new(Mind::open(paths.home.join("mind.json"), store.tx.clone()));
        let convs = Conversations::open(paths.home.join("conversas.json"));
        // Tarefas de antes das conversas vão para uma conversa própria.
        if let Some(first) = store.has_orphans() {
            let c = convs.create(Some("Conversas anteriores"), Some(first));
            store.adopt_orphans(&c.id);
        }
        Arc::new(Self {
            mind,
            store,
            cfg,
            paths,
            name: hostname(),
            claude: find_claude(),
            brains: Default::default(),
            convs,
            local,
            running: Default::default(),
            usage: Default::default(),
            scanner: Arc::new(Mutex::new(Scanner::new(claude_projects()))),
            refreshing: AtomicBool::new(false),
        })
    }

    pub fn submit(
        self: &Arc<Self>,
        text: &str,
        target: Target,
        machine: Option<String>,
        conversation: Option<String>,
    ) -> Result<Task, String> {
        let (target, text) = route::resolve(target, text);
        if text.is_empty() {
            return Err("mensagem vazia".into());
        }
        self.mind.observe_task(&text);
        // Tarefa repassada por outra máquina não abre conversa aqui.
        let conversation = if machine.as_deref() == Some("local") {
            None
        } else {
            let id = conversation
                .filter(|c| self.convs.get(c).is_some())
                .unwrap_or_else(|| self.convs.create(None, None).id);
            self.convs.touch(&id, Some(&text));
            Some(id)
        };
        let task = self.store.create(text, target, machine, conversation);
        let (me, id) = (self.clone(), task.id.clone());
        tokio::spawn(async move { me.run(id).await });
        Ok(task)
    }

    async fn run(self: Arc<Self>, id: String) {
        let Some(t) = self.store.get(&id) else { return };
        match t.target {
            Target::Auto => self.run_brain(&id, &t.text, true).await,
            Target::Chat => self.run_brain(&id, &t.text, false).await,
            Target::Cloud => self.run_cloud(&id, &t.text).await,
            Target::Machine => self.run_machine(&id, &t.text).await,
            Target::Request => {}
        }
    }

    /// Espera a resposta em andamento terminar e esquece a conversa.
    /// Mantido por compatibilidade: hoje "nova conversa" é uma conversa nova.
    pub async fn reset_brain(&self) {
        self.convs.create(None, None);
    }

    /// Só tarefas à espera de aprovação podem ser liberadas.
    pub fn approve(self: &Arc<Self>, id: &str) -> Option<Task> {
        let t = self.store.get(id)?;
        if t.status != Status::AwaitingApproval {
            return None;
        }
        let task = self.store.update(id, |t| t.status = Status::Queued)?;
        let (me, id, prompt) = (self.clone(), id.to_string(), t.prompt.unwrap_or(t.text));
        if t.target == Target::Request {
            let kind = t.kind.unwrap_or_else(|| "funcionalidade".into());
            tokio::spawn(async move { me.run_request(&id, &kind, &prompt, true).await });
        } else {
            tokio::spawn(async move { me.run_machine(&id, &prompt).await });
        }
        Some(task)
    }

    /// Pedido feito direto pelo usuário (menu): abre a issue na hora.
    pub fn request(self: &Arc<Self>, kind: &str, text: &str, agent: bool) -> Result<Task, String> {
        let text = text.trim();
        if text.is_empty() {
            return Err("pedido vazio".into());
        }
        let kind = if route::REQUEST_KINDS.contains(&kind) { kind } else { "funcionalidade" };
        let task = self.store.create(text.to_string(), Target::Request, None, self.convs.current());
        self.store.update(&task.id, |t| t.kind = Some(kind.to_string()));
        let (me, id, kind, text) = (self.clone(), task.id.clone(), kind.to_string(), text.to_string());
        tokio::spawn(async move { me.run_request(&id, &kind, &text, agent).await });
        Ok(task)
    }

    /// Abre a issue com o `gh`. Com `agent`, a etiqueta "agente" faz um
    /// agente do Claude implementar no próprio GitHub e abrir um PR.
    async fn run_request(self: &Arc<Self>, id: &str, kind: &str, text: &str, agent: bool) {
        if !self.start(id) {
            return;
        }
        let Some(repo) = self.cfg.repo.clone() else {
            return self.finish(id, Err("A Oficina ainda não tem repositório no GitHub. Defina \"repo\" no config.json.".into()));
        };
        let first: String = text.lines().next().unwrap_or(text).chars().take(70).collect();
        let label = match kind {
            "widget" => "Widget",
            "roupa" => "Roupa",
            "casa" => "Casa",
            "bug" => "Problema",
            _ => "Funcionalidade",
        };
        let title = format!("[{label}] {first}");
        let body = format!("{text}\n\n---\nPedido feito pela Faísca, na Oficina.");
        let mut labels = vec![kind.to_string()];
        if agent {
            labels.push("agente".into());
        }
        let run = |with_labels: bool| {
            let mut cmd = Command::new(find_gh());
            cmd.args(["issue", "create", "--repo", &repo, "--title", &title, "--body", &body]);
            if with_labels {
                for l in &labels {
                    cmd.args(["--label", l]);
                }
            }
            cmd.stdin(Stdio::null()).kill_on_drop(true);
            cmd
        };
        let mut out = tokio::time::timeout(Duration::from_secs(60), run(true).output()).await;
        // Etiqueta que não existe no repositório não pode travar o pedido.
        if let Ok(Ok(o)) = &out {
            if !o.status.success() && String::from_utf8_lossy(&o.stderr).to_lowercase().contains("label") {
                out = tokio::time::timeout(Duration::from_secs(60), run(false).output()).await;
            }
        }
        let result = match out {
            Err(_) => Err("O GitHub demorou demais para responder.".to_string()),
            Ok(Err(e)) => Err(format!("Não consegui executar o gh: {e}")),
            Ok(Ok(o)) if o.status.success() => {
                let url = String::from_utf8_lossy(&o.stdout).lines().rev()
                    .find(|l| l.starts_with("https://")).map(|l| l.trim().to_string());
                if let Some(url) = url.clone() {
                    self.store.update(id, |t| t.url = Some(url));
                }
                Ok(Some(if agent {
                    "Abri a issue e pedi para um agente implementar. Ele abre um pull request quando terminar.".to_string()
                } else {
                    "Abri a issue no GitHub.".to_string()
                }))
            }
            Ok(Ok(o)) => Err(tail(String::from_utf8_lossy(&o.stderr).trim())),
        };
        self.finish(id, result);
    }

    pub fn cancel(self: &Arc<Self>, id: &str) -> Option<Task> {
        let t = self.store.get(id)?;
        if t.status.is_terminal() {
            return Some(t);
        }
        let task = self.store.update(id, |t| t.status = Status::Cancelled)?;
        let pid = self.running.lock().unwrap().get(id).copied();
        if let Some(pid) = pid {
            signal_group(pid, libc::SIGINT);
            // Quem ignorar o pedido educado não pode prender a fila.
            let (me, id) = (self.clone(), id.to_string());
            tokio::spawn(async move {
                tokio::time::sleep(GRACE).await;
                if me.running.lock().unwrap().get(&id) == Some(&pid) {
                    signal_group(pid, libc::SIGKILL);
                }
            });
        }
        Some(task)
    }

    fn start(&self, id: &str) -> bool {
        let t = self.store.update(id, |t| {
            if t.status != Status::Cancelled {
                t.status = Status::Running;
            }
        });
        let running = t.is_some_and(|t| t.status == Status::Running);
        if running {
            self.mind.task_started(id);
        }
        running
    }

    fn finish(&self, id: &str, result: Result<Option<String>, String>) {
        let ok = result.is_ok();
        let done = self.store.update(id, |t| {
            if t.status == Status::Cancelled {
                return;
            }
            match result {
                Ok(text) => {
                    if let Some(text) = text {
                        t.output = text;
                    }
                    t.status = Status::Done;
                }
                Err(e) => {
                    t.error = Some(e);
                    t.status = Status::Failed;
                }
            }
        });
        match done.map(|t| t.status) {
            Some(Status::Cancelled) | None => self.mind.task_dropped(id),
            _ => self.mind.task_finished(id, ok),
        }
    }

    /// O usuário aceitou uma iniciativa: o core faz a parte que é dele.
    pub fn accept_initiative(self: &Arc<Self>, id: &str) -> Option<Initiative> {
        let initiative = self.mind.accept(id)?;
        match &initiative.action {
            Action::Outfit { theme } => {
                let task = self.store.create(format!("Criar roupinha: {theme}"), Target::Chat, None, self.convs.current());
                let (me, theme) = (self.clone(), theme.clone());
                tokio::spawn(async move { me.run_outfit(&task.id, &theme).await });
            }
            Action::Decor { theme } => {
                self.create_decor(theme, None);
            }
            Action::Task { text, target } => {
                let _ = self.submit(text, *target, None, self.convs.current());
            }
            _ => {}
        }
        Some(initiative)
    }

    /// Cria uma casinha nova. Aparece no chat, porque gasta tokens.
    pub fn create_decor(self: &Arc<Self>, theme: &str, suggestion: Option<String>) -> Task {
        let label = suggestion.as_deref().unwrap_or(theme);
        let task = self.store.create(format!("Decorar casinha: {label}"), Target::Chat, None, self.convs.current());
        let (me, id, theme) = (self.clone(), task.id.clone(), theme.to_string());
        tokio::spawn(async move {
            if !me.start(&id) {
                return;
            }
            let result = match me.ask(&decor::prompt(&theme, suggestion.as_deref())).await {
                Ok(text) => {
                    let did = format!("d{:x}", usage::now());
                    let theme = suggestion.clone().unwrap_or(theme.clone());
                    decor::parse(&text, &theme, did, usage::now()).map(|d| {
                        let name = d.name.clone();
                        me.mind.add_decor(d);
                        Some(format!("Pronto! Montei a casinha \"{name}\". Vou estrear na próxima soneca."))
                    })
                }
                Err(e) => Err(e),
            };
            me.finish(&id, result);
        });
        task
    }

    /// Pede ao Claude as peças da roupinha; o app só desenha o que é válido.
    async fn run_outfit(self: &Arc<Self>, id: &str, theme: &str) {
        if !self.start(id) {
            return;
        }
        let result = match self.ask(&outfit::prompt(theme)).await {
            Ok(text) => {
                let oid = format!("o{:x}", usage::now());
                match outfit::parse(&text, theme, oid, usage::now()) {
                    Ok(o) => {
                        let name = o.name.clone();
                        self.mind.add_outfit(o);
                        Ok(Some(format!("Pronto! Vesti a roupinha \"{name}\". Ficou bom?")))
                    }
                    Err(e) => Err(e),
                }
            }
            Err(e) => Err(e),
        };
        self.finish(id, result);
    }

    /// Uma pergunta avulsa ao Claude, sem ferramentas e sem conversa.
    async fn ask(&self, prompt: &str) -> Result<String, String> {
        let mut cmd = claude_cmd(&self.claude);
        cmd.current_dir(self.paths.brain_dir())
            .args(STREAM_ARGS)
            .args(["--model", &self.cfg.brain_model, "--tools", "", "--setting-sources", "", "--no-session-persistence"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut child = cmd.spawn().map_err(|e| format!("Não consegui executar o claude: {e}"))?;
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(prompt.as_bytes()).await;
        }
        let out = tokio::time::timeout(Duration::from_secs(120), child.wait_with_output())
            .await
            .map_err(|_| "O Claude demorou demais.".to_string())?
            .map_err(|e| e.to_string())?;
        let text = String::from_utf8_lossy(&out.stdout);
        for line in text.lines() {
            if let CliEvent::Result { text, is_error, .. } = route::parse_line(line) {
                return if is_error { Err(tail(&text)) } else { Ok(text) };
            }
        }
        Err("O Claude não respondeu.".into())
    }

    async fn run_brain(self: &Arc<Self>, id: &str, text: &str, delegate: bool) {
        if !self.start(id) {
            return;
        }
        let conv = self.store.get(id).and_then(|t| t.conversation).unwrap_or_default();
        let lane = self.brains.lock().unwrap().entry(conv.clone()).or_default().clone();
        let _turn = lane.lock().await;
        let session = self.convs.get(&conv).and_then(|c| c.session);
        let memory = self.mind.summary();
        let memory = if memory.is_empty() { String::new() } else { format!(" Memória sobre o usuário (use com naturalidade, sem recitar): {memory}") };
        let system = if delegate {
            format!("{BRAIN_BASE}{memory}{BRAIN_DELEGATE}")
        } else {
            format!("{BRAIN_BASE}{memory}")
        };
        let mut cmd = claude_cmd(&self.claude);
        cmd.current_dir(self.paths.brain_dir())
            .args(STREAM_ARGS)
            .args(["--model", &self.cfg.brain_model, "--tools", "", "--setting-sources", ""])
            .args(["--system-prompt", &system]);
        if let Some(s) = session.as_deref() {
            cmd.args(["--resume", s]);
        }
        let out = match self.stream(id, cmd, text, delegate).await {
            Ok(out) => out,
            Err(e) => {
                // Uma sessão que não retoma mais não pode travar a conversa.
                self.convs.set_session(&conv, None);
                self.finish(id, Err(e));
                return;
            }
        };
        self.convs.set_session(&conv, out.session.clone());

        match route::parse_delegate(&out.text).filter(|_| delegate) {
            Some((Dest::Cloud, prompt)) => {
                self.store.update(id, |t| {
                    t.target = Target::Cloud;
                    t.prompt = Some(prompt.clone());
                });
                self.run_cloud(id, &prompt).await;
            }
            Some((Dest::Machine, prompt)) => {
                self.store.update(id, |t| {
                    t.target = Target::Machine;
                    t.prompt = Some(prompt);
                    if t.status != Status::Cancelled {
                        t.status = Status::AwaitingApproval;
                    }
                });
            }
            // Abrir issue é publicar: pede aprovação, com o agente já incluído.
            Some((Dest::Request(kind), prompt)) => {
                self.store.update(id, |t| {
                    t.target = Target::Request;
                    t.kind = Some(kind);
                    t.prompt = Some(prompt);
                    if t.status != Status::Cancelled {
                        t.status = Status::AwaitingApproval;
                    }
                });
            }
            None => self.finish(id, Ok(Some(out.text))),
        }
    }

    async fn run_machine(self: &Arc<Self>, id: &str, prompt: &str) {
        let requested = self.store.get(id).and_then(|t| t.machine);
        match self.pick(requested.as_deref()).await {
            Err(e) => self.finish(id, Err(e)),
            Ok(Where::Remote(peer)) => self.forward(id, prompt, peer).await,
            Ok(Where::Local) => {
                let Ok(_permit) = self.local.acquire().await else { return };
                if !self.start(id) {
                    return;
                }
                self.store.update(id, |t| t.machine = Some(self.name.clone()));
                let mut cmd = claude_cmd(&self.claude);
                cmd.current_dir(self.paths.workspace())
                    .args(STREAM_ARGS)
                    .args(["--permission-mode", "acceptEdits", "--allowedTools"])
                    .args(&self.cfg.allowed_tools);
                let result = self.stream(id, cmd, prompt, false).await;
                self.finish(id, result.map(|o| Some(o.text)));
            }
        }
    }

    async fn run_cloud(self: &Arc<Self>, id: &str, prompt: &str) {
        if !self.start(id) {
            return;
        }
        if let Err(e) = self.ensure_repo().await {
            self.finish(id, Err(e));
            return;
        }
        let result = match self.open_cloud(id, prompt).await {
            Ok(url) => {
                self.store.update(id, |t| t.url = Some(url));
                Ok(Some("Agente iniciado na nuvem. Acompanhe pelo link.".to_string()))
            }
            Err(e) => Err(e),
        };
        self.finish(id, result);
    }

    /// O `--cloud` só aceita rodar num terminal, então ganha um pseudo-terminal.
    /// Com o link em mãos a sessão já existe na nuvem e o processo local sai.
    async fn open_cloud(&self, id: &str, prompt: &str) -> Result<String, String> {
        let mut cmd = claude_cmd(&PathBuf::from("/usr/bin/script"));
        cmd.current_dir(self.paths.workspace())
            .args(["-q", "/dev/null"])
            .arg(&self.claude)
            .arg(format!("--cloud={prompt}"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut child = cmd.spawn().map_err(|e| format!("Não consegui executar o claude: {e}"))?;
        // Entrada aberta: se fechasse, o `script` enviaria ^D ao Claude.
        let _stdin = child.stdin.take();
        let pid = child.id().map(|p| p as i32);
        if let Some(pid) = pid {
            self.running.lock().unwrap().insert(id.to_string(), pid);
        }
        let mut stdout = child.stdout.take().expect("stdout");
        let mut raw = Vec::new();
        let mut chunk = [0u8; 4096];
        let read = async {
            loop {
                let n = stdout.read(&mut chunk).await.unwrap_or(0);
                if n == 0 {
                    return None;
                }
                raw.extend_from_slice(&chunk[..n]);
                let text = route::clean_tty(&String::from_utf8_lossy(&raw));
                if let Some(url) = route::find_session_url(&text) {
                    return Some(Ok(url));
                }
                if route::needs_cli_setup(&text) {
                    return Some(Err(format!("{CLOUD_SETUP}\n\nTela do CLI:\n{}", tail(text.trim()))));
                }
            }
        };
        let url = tokio::time::timeout(Duration::from_secs(90), read).await;
        self.running.lock().unwrap().remove(id);
        if let Some(pid) = pid {
            signal_group(pid, libc::SIGKILL);
        }
        let text = route::clean_tty(&String::from_utf8_lossy(&raw));
        match url {
            Ok(Some(found)) => found,
            Ok(None) => Err(tail(text.trim())),
            Err(_) => Err(format!("O Claude não abriu a sessão na nuvem a tempo. {}", tail(text.trim()))),
        }
    }

    /// O `--cloud` parte de um repositório git.
    async fn ensure_repo(&self) -> Result<(), String> {
        let dir = self.paths.workspace();
        if dir.join(".git").exists() {
            return Ok(());
        }
        for args in [
            vec!["init", "-q"],
            vec![
                "-c", "user.name=Oficina", "-c", "user.email=oficina@localhost",
                "commit", "-q", "--allow-empty", "-m", "Início do espaço de trabalho",
            ],
        ] {
            let status = Command::new("git").args(args).current_dir(&dir).status().await;
            if !status.is_ok_and(|s| s.success()) {
                return Err("Não consegui preparar o repositório de trabalho.".into());
            }
        }
        Ok(())
    }

    async fn stream(
        &self,
        id: &str,
        mut cmd: Command,
        prompt: &str,
        hold: bool,
    ) -> Result<RunOut, String> {
        cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = cmd.spawn().map_err(|e| format!("Não consegui executar o claude: {e}"))?;
        if let Some(pid) = child.id() {
            self.running.lock().unwrap().insert(id.to_string(), pid as i32);
        }
        // O texto vai pela entrada padrão: nunca é confundido com uma flag.
        let mut stdin = child.stdin.take().expect("stdin");
        let prompt = prompt.to_string();
        tokio::spawn(async move {
            let _ = stdin.write_all(prompt.as_bytes()).await;
        });
        let mut stderr = child.stderr.take().expect("stderr");
        let err_task = tokio::spawn(async move {
            let mut s = String::new();
            let _ = stderr.read_to_string(&mut s).await;
            s
        });

        let mut lines = BufReader::new(child.stdout.take().expect("stdout")).lines();
        let mut holdback = Holdback::default();
        let (mut text, mut session, mut result) = (String::new(), None, None);
        while let Ok(Some(line)) = lines.next_line().await {
            match route::parse_line(&line) {
                CliEvent::Delta(d) => {
                    text.push_str(&d);
                    let visible = if hold { holdback.feed(&d) } else { Some(d) };
                    if let Some(v) = visible {
                        self.store.append(id, &v);
                    }
                }
                CliEvent::Session(s) => session = Some(s),
                CliEvent::Result { text, is_error, session: s } => {
                    session = s.or(session.take());
                    result = Some((text, is_error));
                    // É a última linha. Esperar o EOF travaria a fila se
                    // algum subprocesso ainda segurasse o pipe.
                    break;
                }
                CliEvent::Other => {}
            }
        }
        if let Some(rest) = holdback.finish() {
            self.store.append(id, &rest);
        }
        let status = tokio::time::timeout(GRACE, child.wait()).await;
        let status = status.unwrap_or(Err(std::io::ErrorKind::TimedOut.into()));
        let pid = self.running.lock().unwrap().remove(id);
        if let Some(pid) = pid {
            signal_group(pid, libc::SIGKILL);
        }
        let stderr = tokio::time::timeout(GRACE, err_task)
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or_default();

        match result {
            Some((msg, true)) => Err(tail(if msg.is_empty() { &stderr } else { &msg })),
            Some((msg, false)) => Ok(RunOut {
                text: if text.is_empty() { msg } else { text },
                session,
            }),
            None if status.is_ok_and(|s| s.success()) => Ok(RunOut { text, session }),
            None => Err(tail(if stderr.is_empty() { "O claude terminou com erro." } else { &stderr })),
        }
    }

    /// Responde na hora com o que tem; a atualização chega depois por evento.
    pub fn usage(self: &Arc<Self>, fresh: bool) -> Usage {
        let current = self.usage.lock().unwrap().clone();
        let now = usage::now();
        let local = now.saturating_sub(current.updated_at) >= if fresh { 20 } else { 60 };
        let limits = now.saturating_sub(current.limits_at) >= if fresh { 120 } else { 600 };
        if (local || limits) && !self.refreshing.swap(true, Ordering::SeqCst) {
            let me = self.clone();
            tokio::spawn(async move {
                me.refresh_usage(local, limits).await;
                me.refreshing.store(false, Ordering::SeqCst);
            });
        }
        current
    }

    async fn refresh_usage(&self, local: bool, limits: bool) {
        if local {
            let scanner = self.scanner.clone();
            let scanned = tokio::task::spawn_blocking(move || {
                let local = scanner.lock().unwrap().scan();
                release_memory();
                local
            })
            .await;
            if let Ok(scanned) = scanned {
                let mut u = self.usage.lock().unwrap();
                u.local = scanned;
                u.updated_at = usage::now();
            }
        }
        if limits {
            let (read, note) = self.read_limits().await;
            let mut u = self.usage.lock().unwrap();
            if let Some(read) = read {
                u.limits = read;
            } else if note.as_deref().is_some_and(|n| n.contains("login")) {
                u.limits.clear();
            }
            u.limits_note = note;
            u.limits_at = usage::now();
        }
        let usage = self.usage.lock().unwrap().clone();
        let _ = self.store.tx.send(Event::Usage { usage });
    }

    /// `/usage` é um comando local do CLI: não chama o modelo.
    async fn read_limits(&self) -> (Option<Vec<usage::Limit>>, Option<String>) {
        let mut cmd = claude_cmd(&self.claude);
        cmd.current_dir(self.paths.brain_dir())
            .args(["-p", "--output-format", "stream-json", "--verbose", "--strict-mcp-config"])
            .args(["--setting-sources", "", "--tools", "", "--no-session-persistence"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let Ok(mut child) = cmd.spawn() else {
            return (None, Some("Não consegui executar o claude.".into()));
        };
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(b"/usage").await;
        }
        let output = tokio::time::timeout(Duration::from_secs(20), child.wait_with_output()).await;
        let Ok(Ok(output)) = output else {
            return (None, Some("O claude não respondeu a tempo.".into()));
        };
        let text = String::from_utf8_lossy(&output.stdout);
        if let Some(limits) = text.lines().find_map(usage::parse_limits) {
            return (Some(limits), None);
        }
        let note = if self.logged_in().await {
            "Esta versão do Claude CLI não informou os limites."
        } else {
            "Rode claude auth login para ver os limites."
        };
        (None, Some(note.into()))
    }

    async fn logged_in(&self) -> bool {
        let mut cmd = claude_cmd(&self.claude);
        let out = cmd.args(["auth", "status"]).stdin(Stdio::null()).output().await;
        out.ok()
            .and_then(|o| serde_json::from_slice::<serde_json::Value>(&o.stdout).ok())
            .is_some_and(|v| v["loggedIn"] == true)
    }

    async fn peer_online(&self, peer: &Peer) -> bool {
        let url = format!("{}/v1/health", peer.url);
        peer::call(&url, "GET", None, None, Duration::from_millis(1500)).await.is_ok_and(|r| r.ok())
    }

    /// Consulta sob demanda: nenhum ciclo de verificação fica rodando parado.
    pub async fn machines(&self) -> Vec<Machine> {
        let mut out = vec![Machine {
            name: self.name.clone(),
            online: true,
            is_self: true,
        }];
        for p in &self.cfg.machines {
            out.push(Machine {
                name: p.name.clone(),
                online: self.peer_online(p).await,
                is_self: false,
            });
        }
        out
    }

    async fn pick(&self, requested: Option<&str>) -> Result<Where, String> {
        match requested {
            Some("local") => Ok(Where::Local),
            Some(name) if name == self.name => Ok(Where::Local),
            Some(name) => {
                let peer = self.cfg.machines.iter().find(|p| p.name == name);
                let Some(peer) = peer else {
                    return Err(format!("Não conheço a máquina \"{name}\"."));
                };
                if self.peer_online(peer).await {
                    Ok(Where::Remote(peer.clone()))
                } else {
                    Err(format!("A máquina \"{name}\" está offline."))
                }
            }
            None => {
                if self.cfg.execute_local {
                    return Ok(Where::Local);
                }
                for p in &self.cfg.machines {
                    if self.peer_online(p).await {
                        return Ok(Where::Remote(p.clone()));
                    }
                }
                Err("Nenhuma máquina online.".into())
            }
        }
    }

    /// Entrega a tarefa a outra máquina e acompanha até o fim.
    async fn forward(&self, id: &str, prompt: &str, peer: Peer) {
        if !self.start(id) {
            return;
        }
        self.store.update(id, |t| t.machine = Some(peer.name.clone()));
        let url = |path: String| format!("{}/v1/{path}", peer.url);
        let wait = Duration::from_secs(10);
        let body = serde_json::to_vec(&serde_json::json!({"text": prompt, "target": "machine", "machine": "local"})).unwrap_or_default();
        let sent = peer::call(&url("messages".into()), "POST", Some(&peer.token), Some(&body), wait).await;
        let remote: Task = match sent {
            Ok(r) if r.ok() => match serde_json::from_slice(&r.body) {
                Ok(t) => t,
                Err(e) => return self.finish(id, Err(format!("Resposta inválida de {}: {e}", peer.name))),
            },
            Ok(r) => return self.finish(id, Err(format!("{} recusou a tarefa (HTTP {}).", peer.name, r.status))),
            Err(e) => return self.finish(id, Err(format!("Falha ao falar com {}: {e}", peer.name))),
        };

        let task_url = url(format!("tasks/{}", remote.id));
        let mut seen = 0;
        let mut failures = 0;
        loop {
            tokio::time::sleep(Duration::from_secs(1)).await;
            if self.store.get(id).is_some_and(|t| t.status == Status::Cancelled) {
                let _ = peer::call(&format!("{task_url}/cancel"), "POST", Some(&peer.token), None, wait).await;
                return;
            }
            let polled = peer::call(&task_url, "GET", Some(&peer.token), None, wait).await;
            let t: Option<Task> = polled.ok().filter(|r| r.ok()).and_then(|r| serde_json::from_slice(&r.body).ok());
            let Some(t) = t else {
                failures += 1;
                if failures >= 10 {
                    return self.finish(id, Err(format!("Perdi contato com {}.", peer.name)));
                }
                continue;
            };
            failures = 0;
            if let Some(new) = t.output.get(seen..).filter(|s| !s.is_empty()) {
                self.store.append(id, new);
                seen = t.output.len();
            }
            match t.status {
                Status::Done => return self.finish(id, Ok(None)),
                Status::Failed | Status::Cancelled => {
                    let e = t.error.unwrap_or_else(|| format!("Tarefa interrompida em {}.", peer.name));
                    return self.finish(id, Err(e));
                }
                _ => {}
            }
        }
    }
}

const CLOUD_SETUP: &str = "Falta configurar o Claude CLI para a nuvem. No terminal, entre em \
~/Library/Application Support/Oficina/workspace, rode claude, escolha o tema, confirme a pasta e saia com /exit.";

const GRACE: Duration = Duration::from_secs(2);

unsafe extern "C" {
    fn malloc_zone_pressure_relief(zone: *mut libc::c_void, goal: libc::size_t) -> libc::size_t;
}

/// Ler 1 GB de logs deixa buffers livres retidos pelo alocador; devolve ao sistema.
fn release_memory() {
    // SAFETY: zona nula = todas as zonas; objetivo 0 = liberar o que puder.
    unsafe { malloc_zone_pressure_relief(std::ptr::null_mut(), 0) };
}

fn signal_group(pid: i32, sig: i32) {
    // SAFETY: `pid` lidera um grupo criado por nós (`process_group(0)`).
    unsafe { libc::kill(-pid, sig) };
}

fn tail(text: &str) -> String {
    let start = text.len().saturating_sub(800);
    let start = (start..=text.len()).find(|i| text.is_char_boundary(*i)).unwrap_or(0);
    text[start..].to_string()
}
