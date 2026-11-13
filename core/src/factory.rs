//! A fábrica de agentes: ajustes da assistente, agentes com papel, modelo e
//! esforço, equipes em canais com @menção e missões em etapas. Inspirada nos
//! playbooks do Waymark: etapas, aprovação humana e vereditos com evidência.

use crate::engine::{Engine, STREAM_ARGS, claude_cmd};
use crate::router::{self, AUTO, Need, OPUS};
use crate::store::{Status, Target, Task};
use crate::usage::now;
use serde::{Deserialize, Serialize};
use std::{
    collections::VecDeque,
    fs,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};

pub const MODELS: &[&str] = &["haiku", "sonnet", "opus", "fable"];
pub const EFFORTS: &[&str] = &["low", "medium", "high", "xhigh", "max"];

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub name: String,
    pub personality: String,
    pub brain_model: String,
    pub brain_effort: String,
    pub body_color: String,
    pub spark_color: String,
    pub eyes: String,
    pub antenna: bool,
    pub size: f64,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            name: "Faísca".into(),
            personality: "Curta, direta e carinhosa.".into(),
            brain_model: "haiku".into(),
            brain_effort: String::new(),
            body_color: "#FF9E29".into(),
            spark_color: "#FFD60A".into(),
            eyes: "tall".into(),
            antenna: true,
            size: 1.0,
        }
    }
}

fn hex_ok(s: &str) -> bool {
    s.len() == 7 && s.starts_with('#') && s[1..].chars().all(|c| c.is_ascii_hexdigit())
}

impl Settings {
    /// Corrige o que veio fora do esperado, sem recusar o resto.
    pub fn sanitized(mut self) -> Self {
        let d = Settings::default();
        self.name = self.name.trim().chars().take(24).collect();
        if self.name.is_empty() {
            self.name = d.name;
        }
        self.personality = self.personality.trim().chars().take(600).collect();
        if self.brain_model != AUTO && !MODELS.contains(&self.brain_model.as_str()) {
            self.brain_model = d.brain_model;
        }
        if !self.brain_effort.is_empty() && !EFFORTS.contains(&self.brain_effort.as_str()) {
            self.brain_effort = String::new();
        }
        if !hex_ok(&self.body_color) {
            self.body_color = d.body_color;
        }
        if !hex_ok(&self.spark_color) {
            self.spark_color = d.spark_color;
        }
        if !["tall", "round", "dots"].contains(&self.eyes.as_str()) {
            self.eyes = d.eyes;
        }
        self.size = self.size.clamp(0.7, 1.4);
        self
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct StageLog {
    pub stage: String,
    pub verdict: String,
    pub evidence: Vec<String>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Mission {
    pub goal: String,
    pub stage: usize,
    /// rodando, aguardando, concluida, bloqueada, falhou, cancelada
    pub status: String,
    pub approved: bool,
    pub log: Vec<StageLog>,
    /// Depois que um degrau falha, a missão não volta para ele.
    #[serde(default)]
    pub floor: u8,
    #[serde(default)]
    pub retrying: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Agent {
    pub id: String,
    pub name: String,
    pub role: String,
    pub model: String,
    pub effort: String,
    /// "mac" ou "nuvem".
    pub place: String,
    pub project: Option<String>,
    pub team: Option<String>,
    pub conversation: String,
    pub session: Option<String>,
    pub mission: Option<Mission>,
    pub created_at: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Team {
    pub id: String,
    pub name: String,
    pub conversation: String,
}

#[derive(Default, Serialize, Deserialize)]
#[serde(default)]
struct Saved {
    settings: Settings,
    agents: Vec<Agent>,
    teams: Vec<Team>,
}

pub struct Factory {
    state: Mutex<Saved>,
    path: PathBuf,
}

/// Pedido para criar um agente (do painel ou do cérebro).
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
pub struct AgentSpec {
    pub name: String,
    pub role: String,
    pub model: String,
    pub effort: String,
    pub place: String,
    pub project: Option<String>,
    pub team: Option<String>,
}

impl AgentSpec {
    /// `nome | papel | modelo | esforço | lugar`, como o cérebro escreve.
    pub fn parse_line(line: &str) -> Option<AgentSpec> {
        let mut f = line.split('|').map(str::trim);
        let name = f.next()?.to_string();
        let role = f.next()?.to_string();
        if name.is_empty() || role.is_empty() {
            return None;
        }
        Some(AgentSpec {
            name,
            role,
            model: f.next().unwrap_or("").to_string(),
            effort: f.next().unwrap_or("").to_string(),
            place: f.next().unwrap_or("").to_string(),
            ..Default::default()
        })
    }
}

impl Factory {
    pub fn open(path: PathBuf) -> Self {
        let mut saved: Saved = fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        saved.settings = saved.settings.sanitized();
        Self { state: Mutex::new(saved), path }
    }

    fn save(&self, s: &Saved) {
        if let Ok(bytes) = serde_json::to_vec(s) {
            let tmp = self.path.with_extension("tmp");
            if fs::write(&tmp, bytes).is_ok() {
                let _ = fs::rename(tmp, &self.path);
            }
        }
    }

    pub fn settings(&self) -> Settings {
        self.state.lock().unwrap().settings.clone()
    }

    pub fn set_settings(&self, new: Settings) -> Settings {
        let mut s = self.state.lock().unwrap();
        s.settings = new.sanitized();
        self.save(&s);
        s.settings.clone()
    }

    pub fn agents(&self) -> Vec<Agent> {
        self.state.lock().unwrap().agents.clone()
    }

    pub fn teams(&self) -> Vec<Team> {
        self.state.lock().unwrap().teams.clone()
    }

    pub fn agent(&self, id: &str) -> Option<Agent> {
        self.state.lock().unwrap().agents.iter().find(|a| a.id == id).cloned()
    }

    pub fn agent_by_name(&self, name: &str) -> Option<Agent> {
        let name = name.trim().trim_start_matches('@').to_lowercase();
        self.state.lock().unwrap().agents.iter().find(|a| a.name.to_lowercase() == name).cloned()
    }

    pub fn team(&self, id: &str) -> Option<Team> {
        self.state.lock().unwrap().teams.iter().find(|t| t.id == id).cloned()
    }

    fn update(&self, id: &str, f: impl FnOnce(&mut Agent)) -> Option<Agent> {
        let mut s = self.state.lock().unwrap();
        let a = s.agents.iter_mut().find(|a| a.id == id)?;
        f(a);
        let out = a.clone();
        self.save(&s);
        Some(out)
    }

    fn insert_agent(&self, a: Agent) {
        let mut s = self.state.lock().unwrap();
        s.agents.push(a);
        self.save(&s);
    }

    fn insert_team(&self, t: Team) {
        let mut s = self.state.lock().unwrap();
        s.teams.push(t);
        self.save(&s);
    }

    fn remove_agent(&self, id: &str) -> Option<Agent> {
        let mut s = self.state.lock().unwrap();
        let i = s.agents.iter().position(|a| a.id == id)?;
        let a = s.agents.remove(i);
        self.save(&s);
        Some(a)
    }

    fn remove_team(&self, id: &str) -> Option<Team> {
        let mut s = self.state.lock().unwrap();
        let i = s.teams.iter().position(|t| t.id == id)?;
        let t = s.teams.remove(i);
        for a in s.agents.iter_mut().filter(|a| a.team.as_deref() == Some(id)) {
            a.team = None;
        }
        self.save(&s);
        Some(t)
    }

    /// Lista curta para o cérebro saber a quem pode delegar.
    pub fn roster(&self) -> String {
        self.state
            .lock()
            .unwrap()
            .agents
            .iter()
            .map(|a| format!("{} ({})", a.name, a.role.chars().take(60).collect::<String>()))
            .collect::<Vec<_>>()
            .join("; ")
    }
}

// MARK: Missões

struct Stage {
    name: &'static str,
    instruction: &'static str,
    /// Só leitura: nada muda antes da aprovação.
    read_only: bool,
    approval: bool,
    /// Quanto a etapa pesa na escolha do modelo.
    bias: f32,
    /// Quem confere não pode ser mais fraco que Sonnet: aprovar errado não dá para detectar depois.
    floor: u8,
}

const STAGES: [Stage; 4] = [
    Stage { name: "Investigar", instruction: "Investigue o objetivo no projeto. Não altere nada.", read_only: true, approval: false, bias: -0.5, floor: 0 },
    Stage { name: "Propor", instruction: "Proponha um plano curto e concreto para o objetivo. Não altere nada.", read_only: true, approval: false, bias: 0.0, floor: 0 },
    Stage { name: "Executar", instruction: "Execute o plano aprovado.", read_only: false, approval: true, bias: 1.0, floor: 0 },
    Stage { name: "Verificar", instruction: "Verifique se o objetivo foi cumprido, conferindo o resultado de verdade. Não altere nada.", read_only: true, approval: false, bias: 0.0, floor: 1 },
];

const VERDICT_RULE: &str = "Termine com uma linha `VEREDITO: concluido`, `VEREDITO: bloqueado` ou `VEREDITO: falhou`, \
seguida do motivo, e pelo menos uma linha `EVIDENCIA: <arquivo:linha, comando ou link>` que comprove o que disse.";

/// Lê o veredito no fim da resposta. Sem evidência, não vale como concluído.
pub fn parse_verdict(text: &str) -> (String, Vec<String>) {
    let mut verdict = String::new();
    let mut evidence = Vec::new();
    for line in text.lines() {
        let l = line.trim().trim_matches('`').trim();
        let upper = l.to_uppercase();
        if let Some(rest) = upper.strip_prefix("VEREDITO:") {
            verdict = rest.split_whitespace().next().unwrap_or("").to_lowercase();
        } else if upper.starts_with("EVIDENCIA:") || upper.starts_with("EVIDÊNCIA:") {
            if let Some((_, v)) = l.split_once(':') {
                let v = v.trim();
                if !v.is_empty() {
                    evidence.push(v.chars().take(200).collect());
                }
            }
        }
    }
    let verdict = verdict.replace(['í', 'Í'], "i");
    let verdict = match verdict.as_str() {
        "concluido" | "bloqueado" | "falhou" => verdict,
        _ => "falhou".to_string(),
    };
    if verdict == "concluido" && evidence.is_empty() {
        return ("sem-evidencia".into(), evidence);
    }
    (verdict, evidence)
}

/// Quem foi @mencionado, sem repetir e sem contar quem falou.
pub fn mentions(text: &str, names: &[String], except: Option<&str>) -> Vec<String> {
    let lower = text.to_lowercase();
    names
        .iter()
        .filter(|n| Some(n.as_str()) != except)
        .filter(|n| {
            let needle = format!("@{}", n.to_lowercase());
            lower.match_indices(&needle).any(|(i, m)| {
                !lower[i + m.len()..].chars().next().is_some_and(|c| c.is_alphanumeric())
            })
        })
        .cloned()
        .collect()
}

/// Id da sessão a partir do link do `--cloud`.
fn cloud_session(url: &str) -> Option<String> {
    let tail = url.rsplit('/').next()?.split('?').next()?;
    (!tail.is_empty()).then(|| tail.to_string())
}

const MAX_RELAYS: usize = 6;
const READ_ONLY_TOOLS: [&str; 6] = ["Read", "Grep", "Glob", "Bash(ls *)", "Bash(git log *)", "Bash(git diff *)"];

fn valid_model(m: &str) -> String {
    if MODELS.contains(&m) { m.to_string() } else { AUTO.to_string() }
}

fn valid_effort(e: &str) -> String {
    if EFFORTS.contains(&e) { e.to_string() } else { AUTO.to_string() }
}

impl Engine {
    pub fn create_agent(&self, spec: AgentSpec) -> Result<Agent, String> {
        let name: String = spec.name.trim().trim_start_matches('@').chars().filter(|c| c.is_alphanumeric() || *c == '-' || *c == '_').take(24).collect();
        if name.is_empty() {
            return Err("O agente precisa de um nome (letras e números).".into());
        }
        if self.factory.agent_by_name(&name).is_some() {
            return Err(format!("Já existe um agente chamado {name}."));
        }
        let role: String = spec.role.trim().chars().take(1500).collect();
        if role.is_empty() {
            return Err("Descreva o papel do agente.".into());
        }
        let conv = self.convs.create(Some(&name), None);
        let id = format!("a{:x}", crate::conv::next_id());
        self.convs.set_owner(&conv.id, Some(id.clone()), None);
        let agent = Agent {
            id,
            name,
            role,
            model: valid_model(&spec.model),
            effort: valid_effort(&spec.effort),
            place: if spec.place == "nuvem" { "nuvem".into() } else { "mac".into() },
            project: spec.project.filter(|p| !p.trim().is_empty()),
            team: spec.team.filter(|t| self.factory.team(t).is_some()),
            conversation: conv.id,
            session: None,
            mission: None,
            created_at: now(),
        };
        self.factory.insert_agent(agent.clone());
        Ok(agent)
    }

    pub fn delete_agent(&self, id: &str) -> bool {
        let Some(a) = self.factory.remove_agent(id) else { return false };
        self.convs.delete(&a.conversation);
        self.store.forget_conversation(&a.conversation);
        true
    }

    pub fn create_team(&self, name: &str, members: &[String]) -> Result<Team, String> {
        let name: String = name.trim().chars().take(30).collect();
        if name.is_empty() {
            return Err("A equipe precisa de um nome.".into());
        }
        let conv = self.convs.create(Some(&format!("# {name}")), None);
        let id = format!("e{:x}", crate::conv::next_id());
        self.convs.set_owner(&conv.id, None, Some(id.clone()));
        let team = Team { id: id.clone(), name, conversation: conv.id };
        self.factory.insert_team(team.clone());
        for m in members {
            self.factory.update(m, |a| a.team = Some(id.clone()));
        }
        Ok(team)
    }

    pub fn delete_team(&self, id: &str) -> bool {
        let Some(t) = self.factory.remove_team(id) else { return false };
        self.convs.delete(&t.conversation);
        self.store.forget_conversation(&t.conversation);
        true
    }

    pub fn set_member(&self, agent: &str, team: Option<String>) -> bool {
        let team = team.filter(|t| self.factory.team(t).is_some());
        self.factory.update(agent, |a| a.team = team).is_some()
    }

    /// Estado de cada agente, calculado das tarefas (nada fica verificando).
    pub fn agent_status(&self, a: &Agent) -> &'static str {
        let tasks = self.store.list();
        let mine: Vec<&Task> = tasks.iter().filter(|t| t.agent.as_deref() == Some(a.id.as_str())).collect();
        if mine.iter().any(|t| t.status == Status::AwaitingApproval) {
            "aguardando"
        } else if mine.iter().any(|t| matches!(t.status, Status::Running | Status::Queued)) {
            "trabalhando"
        } else if mine.last().is_some_and(|t| t.status == Status::Failed) {
            "erro"
        } else {
            "livre"
        }
    }

    /// Roda um turno do agente: no Mac por `--resume`, na nuvem por `--cloud`.
    pub(crate) async fn run_agent(self: &Arc<Self>, task: &str, agent: &str, prompt: &str, need: Need<'_>, read_only: bool) -> Option<String> {
        let Some(a) = self.factory.agent(agent) else {
            self.finish(task, Err("Esse agente não existe mais.".into()));
            return None;
        };
        let lane = self.brains.lock().unwrap().entry(a.id.clone()).or_default().clone();
        let _turn = lane.lock().await;
        if !self.start(task) {
            return None;
        }
        let a = self.factory.agent(agent)?;
        if a.place == "nuvem" {
            return self.run_agent_cloud(task, &a, prompt).await;
        }
        let dir = a.project.clone().map(PathBuf::from).filter(|p| p.is_dir()).unwrap_or_else(|| self.paths.workspace());
        let mut tools: Vec<String> = if read_only { READ_ONLY_TOOLS.map(String::from).to_vec() } else { self.cfg.allowed_tools.clone() };
        // Projetos da Oficina de hardware ganham só o comando `oficinad hw`.
        if self.is_hardware_dir(&dir) {
            tools.extend(crate::hardware::tools(read_only));
        }
        let role = format!("Você é o agente {}. Seu papel: {}", a.name, a.role);
        let choice = (a.model == AUTO || a.effort == AUTO).then(|| self.router.choose(&a.id, need));
        let model = choice.filter(|_| a.model == AUTO).map_or(a.model.as_str(), |c| c.model);
        // Haiku responde bem sem ajuste de esforço; só os maiores recebem o nível.
        let effort = if a.effort != AUTO { Some(a.effort.as_str()) } else { choice.map(|c| c.effort).filter(|_| model != "haiku") };
        self.store.update(task, |t| t.model = Some(model.to_string()));
        let mut cmd = claude_cmd(&self.claude);
        cmd.current_dir(dir).args(STREAM_ARGS).args(["--model", model]);
        if let Some(effort) = effort {
            cmd.args(["--effort", effort]);
        }
        cmd.args(["--append-system-prompt", &role])
            .args(["--permission-mode", if read_only { "dontAsk" } else { "acceptEdits" }, "--allowedTools"])
            .args(&tools);
        if let Some(s) = &a.session {
            cmd.args(["--resume", s]);
        }
        match self.stream(task, cmd, prompt, false).await {
            Ok(out) => {
                self.factory.update(&a.id, |x| x.session = out.session.clone());
                self.finish(task, Ok(Some(out.text.clone())));
                Some(out.text)
            }
            Err(e) => {
                // Sessão que não retoma não pode travar o agente.
                self.factory.update(&a.id, |x| x.session = None);
                self.finish(task, Err(e));
                None
            }
        }
    }

    async fn run_agent_cloud(self: &Arc<Self>, task: &str, a: &Agent, prompt: &str) -> Option<String> {
        let result = match &a.session {
            None => {
                let full = format!("Você é o agente {}. Seu papel: {}\n\n{prompt}", a.name, a.role);
                if let Err(e) = self.ensure_repo().await {
                    self.finish(task, Err(e));
                    return None;
                }
                match self.open_cloud(task, &full).await {
                    Ok(url) => {
                        self.factory.update(&a.id, |x| x.session = cloud_session(&url));
                        self.store.update(task, |t| t.url = Some(url));
                        Ok(Some("Agente iniciado na nuvem. Acompanhe pelo link.".to_string()))
                    }
                    Err(e) => Err(e),
                }
            }
            Some(s) => {
                let mut cmd = claude_cmd(&self.claude);
                cmd.current_dir(self.paths.workspace())
                    .args(["-p", prompt, "--cloud", s, "--output-format", "json"])
                    .stdin(std::process::Stdio::null());
                match tokio::time::timeout(Duration::from_secs(90), cmd.output()).await {
                    Ok(Ok(o)) => {
                        let v: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap_or_default();
                        if v["ok"] == true {
                            if let Some(u) = v["url"].as_str() {
                                let u = u.to_string();
                                self.store.update(task, |t| t.url = Some(u));
                            }
                            Ok(Some("Mensagem entregue ao agente na nuvem.".to_string()))
                        } else {
                            Err(v["error"].as_str().unwrap_or("A nuvem recusou a mensagem.").to_string())
                        }
                    }
                    Ok(Err(e)) => Err(e.to_string()),
                    Err(_) => Err("A nuvem demorou demais para responder.".to_string()),
                }
            }
        };
        let text = result.as_ref().ok().and_then(|o| o.clone());
        self.finish(task, result);
        text
    }

    /// Conversa num canal: quem foi @mencionado responde (ou o primeiro da
    /// equipe). Se a resposta menciona um colega, ele responde em seguida.
    pub(crate) async fn run_team(self: &Arc<Self>, task: &str, team: &Team, text: &str) {
        let members: Vec<Agent> = self.factory.agents().into_iter().filter(|a| a.team.as_deref() == Some(team.id.as_str())).collect();
        let Some(first) = members.first() else {
            self.finish(task, Err("Esta equipe ainda não tem agentes.".into()));
            return;
        };
        let names: Vec<String> = members.iter().map(|a| a.name.clone()).collect();
        let mut called = mentions(text, &names, None);
        if called.is_empty() {
            called.push(first.name.clone());
        }
        let mut queue: VecDeque<(String, String, Option<String>)> = VecDeque::new();
        for (i, n) in called.into_iter().enumerate() {
            queue.push_back((n, text.to_string(), (i == 0).then(|| task.to_string())));
        }
        let mut relays = 0;
        while let Some((name, message, existing)) = queue.pop_front() {
            let Some(a) = members.iter().find(|m| m.name == name) else { continue };
            let task_id = existing.unwrap_or_else(|| self.store.create(String::new(), Target::Agent, None, Some(team.conversation.clone())).id);
            self.store.update(&task_id, |t| t.agent = Some(a.id.clone()));
            let others = names.iter().filter(|n| **n != a.name).cloned().collect::<Vec<_>>().join(", ");
            let prompt = format!(
                "Você está no canal da equipe {}, com: {others}. Para pedir algo a um colega, escreva @Nome. \
Só mencione alguém se precisar dele.\n\nMensagens recentes:\n{}\n\nAgora: {message}",
                team.name,
                self.channel_log(&team.conversation, &task_id)
            );
            let Some(reply) = self.run_agent(&task_id, &a.id, &prompt, Need::plain(&message), false).await else { continue };
            for n in mentions(&reply, &names, Some(&a.name)) {
                if relays < MAX_RELAYS {
                    relays += 1;
                    queue.push_back((n, format!("{} disse: {reply}", a.name), None));
                }
            }
        }
    }

    fn channel_log(&self, conversation: &str, skip: &str) -> String {
        let history = self.store.history(conversation);
        let start = history.len().saturating_sub(10);
        let agents = self.factory.agents();
        history[start..]
            .iter()
            .filter(|t| t.id != skip)
            .flat_map(|t| {
                let who = t.agent.as_ref().and_then(|id| agents.iter().find(|a| &a.id == id)).map(|a| a.name.clone()).unwrap_or_else(|| "agente".into());
                let mut lines = Vec::new();
                if !t.text.is_empty() {
                    lines.push(format!("Usuário: {}", t.text));
                }
                if !t.output.is_empty() {
                    lines.push(format!("{who}: {}", t.output.chars().take(600).collect::<String>()));
                }
                lines
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    // MARK: Missões

    pub fn start_mission(self: &Arc<Self>, agent: &str, goal: &str) -> Result<Agent, String> {
        let goal = goal.trim();
        if goal.is_empty() {
            return Err("Descreva o objetivo da missão.".into());
        }
        let a = self.factory.agent(agent).ok_or("Esse agente não existe.")?;
        if a.mission.as_ref().is_some_and(|m| m.status == "rodando" || m.status == "aguardando") {
            return Err(format!("{} já está numa missão.", a.name));
        }
        let updated = self.factory.update(agent, |x| {
            x.mission = Some(Mission { goal: goal.to_string(), stage: 0, status: "rodando".into(), ..Default::default() });
        }).ok_or("Esse agente não existe.")?;
        let (me, id) = (self.clone(), agent.to_string());
        tokio::spawn(async move { me.advance_mission(&id).await });
        Ok(updated)
    }

    fn set_mission(&self, agent: &str, f: impl FnOnce(&mut Mission)) {
        self.factory.update(agent, |a| {
            if let Some(m) = a.mission.as_mut() {
                f(m);
            }
        });
    }

    async fn advance_mission(self: &Arc<Self>, agent: &str) {
        loop {
            let Some(a) = self.factory.agent(agent) else { return };
            let Some(m) = a.mission.clone() else { return };
            if m.status != "rodando" {
                return;
            }
            let Some(stage) = STAGES.get(m.stage) else {
                self.set_mission(agent, |m| m.status = "concluida".into());
                return;
            };
            let title = format!("Missão · {}: {}", stage.name, m.goal);
            let task = self.store.create(title, Target::Agent, None, Some(a.conversation.clone()));
            self.convs.touch(&a.conversation, None);
            self.store.update(&task.id, |t| t.agent = Some(a.id.clone()));
            if stage.approval && !m.approved {
                self.store.update(&task.id, |t| {
                    t.prompt = Some(format!("Executar o plano da missão: {}", m.goal));
                    t.status = Status::AwaitingApproval;
                });
                self.set_mission(agent, |m| m.status = "aguardando".into());
                return;
            }
            let previous = m.log.iter().map(|l| format!("{}: {}", l.stage, l.verdict)).collect::<Vec<_>>().join("; ");
            let retry = if m.retrying { "\nA tentativa anterior desta etapa não bastou. Refaça com mais cuidado." } else { "" };
            let prompt = format!("Missão: {}\nEtapa: {}. {}{retry}\nEtapas anteriores: {previous}\n\n{VERDICT_RULE}", m.goal, stage.name, stage.instruction);
            let need = Need { text: &m.goal, bias: stage.bias, floor: stage.floor.max(m.floor), ceiling: OPUS, probe: stage.read_only && stage.floor == 0, fresh: true };
            let Some(reply) = self.run_agent(&task.id, agent, &prompt, need, stage.read_only).await else {
                let cancelled = self.store.get(&task.id).is_some_and(|t| t.status == Status::Cancelled);
                self.set_mission(agent, |m| m.status = if cancelled { "cancelada".into() } else { "falhou".into() });
                return;
            };
            let (verdict, evidence) = parse_verdict(&reply);
            let done = verdict == "concluido";
            let tier = (a.model == AUTO).then(|| self.store.get(&task.id).and_then(|t| t.model).and_then(|m| router::tier_of(&m))).flatten();
            if let Some(tier) = tier.filter(|_| verdict != "bloqueado") {
                self.router.outcome(&m.goal, tier, done);
                // O modelo não deu conta: a mesma etapa, um degrau acima.
                if !done && tier < OPUS {
                    self.set_mission(agent, |m| {
                        m.floor = tier + 1;
                        m.retrying = true;
                    });
                    continue;
                }
            }
            let name = stage.name.to_string();
            self.set_mission(agent, |m| {
                m.log.push(StageLog { stage: name, verdict: verdict.clone(), evidence });
                m.retrying = false;
                if done {
                    m.stage += 1;
                } else {
                    m.status = if verdict == "bloqueado" { "bloqueada".into() } else { "falhou".into() };
                }
            });
            if !done {
                return;
            }
        }
    }

    /// Aprovação da etapa que altera coisas: libera e segue a missão.
    pub(crate) fn approve_mission(self: &Arc<Self>, task: &str, agent: &str) {
        self.finish(task, Ok(Some("Aprovado. Vou executar.".to_string())));
        self.set_mission(agent, |m| {
            m.approved = true;
            m.status = "rodando".into();
        });
        let (me, id) = (self.clone(), agent.to_string());
        tokio::spawn(async move { me.advance_mission(&id).await });
    }

    pub(crate) fn mission_cancelled(&self, agent: &str) {
        self.set_mission(agent, |m| {
            if m.status == "aguardando" {
                m.status = "cancelada".into();
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn veredito_exige_evidencia() {
        assert_eq!(parse_verdict("ok\nVEREDITO: concluido\nEVIDENCIA: src/a.rs:10").0, "concluido");
        assert_eq!(parse_verdict("VEREDITO: concluido").0, "sem-evidencia");
        assert_eq!(parse_verdict("`VEREDITO: bloqueado — falta acesso`").0, "bloqueado");
        assert_eq!(parse_verdict("sem linha nenhuma").0, "falhou");
        let (_, ev) = parse_verdict("VEREDITO: concluído\nEVIDÊNCIA: cargo test passou");
        assert_eq!(ev, vec!["cargo test passou".to_string()]);
    }

    #[test]
    fn mencoes_por_palavra_inteira() {
        let names = vec!["Ana".to_string(), "Bia".to_string(), "Anaconda".to_string()];
        assert_eq!(mentions("oi @ana e @Bia", &names, None), vec!["Ana", "Bia"]);
        assert_eq!(mentions("@Anaconda", &names, None), vec!["Anaconda"]);
        assert_eq!(mentions("@Ana", &names, Some("Ana")), Vec::<String>::new());
    }

    #[test]
    fn linha_do_cerebro_vira_agente() {
        let s = AgentSpec::parse_line("Revisora | revisa PRs | opus | high | nuvem").unwrap();
        assert_eq!((s.name.as_str(), s.model.as_str(), s.place.as_str()), ("Revisora", "opus", "nuvem"));
        assert!(AgentSpec::parse_line("sem papel").is_none());
    }

    #[test]
    fn ajustes_invalidos_sao_corrigidos() {
        let s = Settings { name: "  ".into(), brain_model: "gpt".into(), body_color: "azul".into(), size: 9.0, eyes: "x".into(), ..Default::default() }.sanitized();
        assert_eq!(s.name, "Faísca");
        assert_eq!(s.brain_model, "haiku");
        assert_eq!(s.body_color, "#FF9E29");
        assert_eq!(s.size, 1.4);
        assert_eq!(s.eyes, "tall");
    }

    #[test]
    fn sessao_vem_do_link() {
        assert_eq!(cloud_session("https://claude.ai/code/session_01H?from=cli").as_deref(), Some("session_01H"));
    }
}
