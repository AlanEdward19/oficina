//! A mente da Faísca: sente o que acontece no Mac, passa pela rede de
//! neurônios, cansa e dorme, pensa e, quando faz sentido, toma iniciativa.

pub mod decor;
pub mod memory;
pub mod net;
pub mod outfit;

use crate::store::{Event, Target};
use crate::usage::now;
use memory::{Fact, Memory, human_minutes, is_ai, is_work};
use net::{INPUTS, MOTORS, N_IN, Net};
use decor::Decor;
use outfit::Outfit;
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashSet, VecDeque},
    fs,
    path::PathBuf,
    sync::Mutex,
    time::Instant,
};
use tokio::sync::broadcast;

const TRABALHANDO: usize = 0;
const IA: usize = 1;
const OCIOSO: usize = 2;
const TAREFA: usize = 3;
const SUCESSO: usize = 4;
const FALHA: usize = 5;
const CARINHO: usize = 6;
const CUTUCADA: usize = 7;
const IGNORADA: usize = 8;
const NOITE: usize = 9;
const NOVIDADE: usize = 10;
const TROCA: usize = 11;

const SEED: u64 = 0x5EED_FA15CA;
const PRESENT_IDLE: f64 = 120.0;
const INITIATIVE_TTL: u64 = 600;

#[derive(Deserialize)]
pub struct MindEvent {
    pub kind: String,
    #[serde(default)]
    pub bundle: Option<String>,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub idle: Option<f64>,
    #[serde(default)]
    pub running: Option<Vec<String>>,
    #[serde(default)]
    pub secs: Option<f64>,
}

#[derive(Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Action {
    None,
    Chat,
    OpenApp { bundle: String, name: String },
    Outfit { theme: String },
    Decor { theme: String },
    Task { text: String, target: Target },
}

#[derive(Clone, Serialize)]
pub struct Initiative {
    pub id: String,
    pub kind: String,
    pub text: String,
    pub accept: String,
    pub decline: String,
    pub action: Action,
    pub at: u64,
}

#[derive(Clone, Serialize)]
pub struct Thought {
    pub text: String,
    pub at: u64,
}

/// O que as telas precisam a todo momento; vai por evento quando muda.
#[derive(Clone, Serialize)]
pub struct Brief {
    pub mood: String,
    pub sleeping: bool,
    pub thought: Option<Thought>,
    pub initiative: Option<Initiative>,
    pub outfit: Option<Outfit>,
    /// A caminha em uso (a padrão, se nenhuma foi criada).
    pub decor: Decor,
}

#[derive(Serialize)]
pub struct Named {
    pub name: &'static str,
    pub value: f32,
}

#[derive(Serialize)]
pub struct AppView {
    pub name: String,
    pub minutes: f64,
    pub ai: bool,
    pub hours: Vec<f64>,
}

#[derive(Serialize)]
pub struct Interest {
    pub word: String,
    pub count: u32,
}

#[derive(Serialize)]
pub struct MemoryView {
    pub apps: Vec<AppView>,
    pub interests: Vec<Interest>,
    pub facts: Vec<Fact>,
    pub peak: Option<(usize, usize)>,
}

#[derive(Serialize)]
pub struct Snapshot {
    #[serde(flatten)]
    pub brief: Brief,
    pub energy: f32,
    pub drives: Vec<Named>,
    pub inputs: Vec<Named>,
    pub neurons: Vec<f32>,
    pub thoughts: Vec<Thought>,
    pub memory: MemoryView,
    pub outfits: Vec<Outfit>,
    pub decors: Vec<Decor>,
}

struct Focus {
    bundle: String,
    name: String,
}

struct State {
    net: Net,
    mem: Memory,
    energy: f32,
    sleeping: bool,
    pulses: [f32; N_IN],
    input: [f32; N_IN],
    idle: f64,
    present_at: u64,
    focus: Option<Focus>,
    running_apps: Vec<String>,
    tasks: HashSet<String>,
    last_interaction: u64,
    projects: String,
    /// Colocada para descansar na Dock: dorme até aqui, mesmo com você por perto.
    rest_until: u64,
    work_streak: f64,
    mood: String,
    thoughts: VecDeque<Thought>,
    last_thought_at: u64,
    initiative: Option<Initiative>,
    last_initiative_at: u64,
    dirty: bool,
    last_save: u64,
    seq: u64,
    last_tick: Instant,
    last_brief: String,
}

pub struct Mind {
    state: Mutex<State>,
    path: PathBuf,
    tx: broadcast::Sender<Event>,
    cooldown: u64,
}

#[cfg(test)]
const TEST_HOUR: usize = 12;

fn local_hour(ts: u64) -> usize {
    // SAFETY: `tm` é preenchida por localtime_r antes de ser lida.
    unsafe {
        let t = ts as libc::time_t;
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&t, &mut tm);
        tm.tm_hour.clamp(0, 23) as usize
    }
}

fn pick<'a>(options: &[&'a str], salt: u64) -> &'a str {
    options[(salt as usize) % options.len()]
}

impl Mind {
    pub fn open(path: PathBuf, tx: broadcast::Sender<Event>) -> Self {
        let mem: Memory = fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        let mut net = Net::new(SEED);
        net.load_readout(&mem.readout);
        let energy = mem.energy.unwrap_or(0.8).clamp(0.0, 1.0);
        let now = now();
        let cooldown = std::env::var("OFICINA_MIND_COOLDOWN").ok().and_then(|v| v.parse().ok()).unwrap_or(1200);
        Self {
            state: Mutex::new(State {
                net,
                mem,
                energy,
                sleeping: false,
                pulses: [0.0; N_IN],
                input: [0.0; N_IN],
                idle: 0.0,
                present_at: now,
                focus: None,
                running_apps: Vec::new(),
                tasks: HashSet::new(),
                last_interaction: now,
                projects: String::new(),
                rest_until: 0,
                work_streak: 0.0,
                mood: "neutra".into(),
                thoughts: VecDeque::new(),
                last_thought_at: 0,
                initiative: None,
                last_initiative_at: now,
                dirty: false,
                last_save: now,
                seq: 0,
                last_tick: Instant::now(),
                last_brief: String::new(),
            }),
            path,
            tx,
            cooldown,
        }
    }

    // MARK: Entradas

    pub fn events(&self, events: Vec<MindEvent>) {
        let now = now();
        let mut s = self.state.lock().unwrap();
        for e in events {
            match e.kind.as_str() {
                "app_focus" => {
                    let (Some(bundle), Some(name)) = (e.bundle, e.name) else { continue };
                    if !s.mem.knows_app(&bundle) {
                        s.mem.apps.entry(bundle.clone()).or_default().name = name.clone();
                        pulse(&mut s, NOVIDADE, 1.0);
                    }
                    pulse(&mut s, TROCA, 0.5);
                    if is_ai(&bundle, &name) {
                        pulse(&mut s, IA, 0.6);
                    }
                    s.focus = Some(Focus { bundle, name });
                }
                "presence" => {
                    s.idle = e.idle.unwrap_or(0.0).max(0.0);
                    s.present_at = now;
                    if let Some(r) = e.running {
                        s.running_apps = r;
                    }
                }
                "pet_click" | "pet_drag" | "chat_open" => {
                    let amount = if e.kind == "pet_click" { 1.0 } else { 0.5 };
                    pulse(&mut s, CUTUCADA, amount);
                    s.last_interaction = now;
                    wake(&mut s);
                }
                "pet_petted" => {
                    pulse(&mut s, CARINHO, 1.0);
                    s.net.reward(0.6);
                    s.last_interaction = now;
                    wake(&mut s);
                    let t = pick(&["Hehe, que gostoso!", "Mais carinho, por favor!", "Isso me deixa feliz."], s.seq);
                    think(&mut s, t.to_string(), now);
                }
                "env_switch" => {
                    pulse(&mut s, TROCA, 1.0);
                    if let Some(name) = e.name {
                        think(&mut s, format!("Modo {name}!"), now);
                    }
                }
                "dock_open" => pulse(&mut s, TROCA, 0.4),
                "pet_rest" => {
                    let secs = e.secs.unwrap_or(900.0).clamp(60.0, 3600.0) as u64;
                    s.sleeping = true;
                    s.rest_until = now + secs;
                    s.last_interaction = now;
                    think(&mut s, "Zzz… vou descansar um pouquinho.".into(), now);
                }
                _ => {}
            }
        }
        s.dirty = true;
        drop(s);
        self.publish();
    }

    /// Um pedido do usuário: interesses, fatos e um pouco de atenção.
    pub fn observe_task(&self, text: &str) {
        let now = now();
        let mut s = self.state.lock().unwrap();
        s.last_interaction = now;
        if let Some(fact) = s.mem.observe_text(text, now) {
            think(&mut s, format!("Anotado: {fact}"), now);
        }
        let lower = text.to_lowercase();
        if ["ia ", " ia", "agente", "claude", "llm", "modelo"].iter().any(|w| lower.contains(w)) {
            pulse(&mut s, IA, 0.5);
        }
        s.dirty = true;
        drop(s);
        self.publish();
    }

    pub fn task_started(&self, id: &str) {
        self.state.lock().unwrap().tasks.insert(id.to_string());
    }

    pub fn task_finished(&self, id: &str, ok: bool) {
        let mut s = self.state.lock().unwrap();
        if !s.tasks.remove(id) {
            return;
        }
        if ok {
            pulse(&mut s, SUCESSO, 1.0);
            s.net.reward(0.3);
        } else {
            pulse(&mut s, FALHA, 1.0);
        }
    }

    /// Tarefa cancelada: não é sucesso nem fracasso.
    pub fn task_dropped(&self, id: &str) {
        self.state.lock().unwrap().tasks.remove(id);
    }

    pub fn summary(&self) -> String {
        let s = self.state.lock().unwrap();
        let mut out = s.mem.summary();
        if !s.projects.is_empty() {
            out.push_str(&format!(" Projetos em que o usuário está atuando: {}.", s.projects));
        }
        out
    }

    /// Resumo dos projetos atuais, vindo da leitura de uso.
    pub fn set_projects(&self, projects: String) {
        self.state.lock().unwrap().projects = projects;
    }

    // MARK: Ciclo

    /// Dormindo ou com você longe, a mente pode pensar mais devagar.
    pub fn calm(&self) -> bool {
        let s = self.state.lock().unwrap();
        let away = now().saturating_sub(s.present_at) > 180 || s.idle > 300.0;
        (s.sleeping || away) && s.tasks.is_empty() && s.pulses.iter().all(|p| *p < 0.02)
    }

    pub fn tick(&self) {
        let now = now();
        let mut s = self.state.lock().unwrap();
        let dt = s.last_tick.elapsed().as_secs_f32().clamp(0.05, 5.0);
        s.last_tick = Instant::now();

        let silent = now.saturating_sub(s.present_at) as f64;
        let idle = if silent > 180.0 { s.idle + silent } else { s.idle };
        let present = idle < PRESENT_IDLE;
        let hour = local_hour(now);
        // Os testes não podem depender da hora em que rodam.
        #[cfg(test)]
        let hour = TEST_HOUR;

        let (working, ai) = match &s.focus {
            Some(f) if present => (is_work(&f.bundle, &f.name), is_ai(&f.bundle, &f.name)),
            _ => (false, false),
        };
        if present {
            if let Some(f) = s.focus.as_ref().map(|f| (f.bundle.clone(), f.name.clone())) {
                s.mem.add_app_time(&f.0, &f.1, dt as f64, hour, now);
                s.dirty = true;
            }
        }
        s.work_streak = if working { s.work_streak + dt as f64 } else if present { (s.work_streak - dt as f64 * 3.0).max(0.0) } else { 0.0 };

        let mut input = s.pulses;
        input[TRABALHANDO] = if working { 1.0 } else { 0.0 };
        input[IA] = input[IA].max(if ai { 1.0 } else { 0.0 });
        input[OCIOSO] = (idle / 900.0).min(1.0) as f32;
        input[TAREFA] = if s.tasks.is_empty() { 0.0 } else { 1.0 };
        input[IGNORADA] = (now.saturating_sub(s.last_interaction) as f32 / 7200.0).min(1.0) * if present { 1.0 } else { 0.3 };
        input[NOITE] = if !(6..23).contains(&hour) { 1.0 } else if hour == 22 { 0.5 } else { 0.0 };
        s.input = input;
        s.net.run(&input, dt);
        let decay = (-dt / 6.0).exp();
        for p in &mut s.pulses {
            *p *= decay;
        }

        s.energy = if s.sleeping {
            s.energy + dt / 3600.0 * if present { 1.0 } else { 1.5 }
        } else {
            s.energy - dt / (10.0 * 3600.0) * (1.0 + 0.5 * input[TRABALHANDO])
        }
        .clamp(0.0, 1.0);
        let tired = s.net.motor("cansaco");
        if !s.sleeping && (s.energy < 0.1 || (idle > 900.0 && (input[NOITE] > 0.0 || tired > 0.5))) {
            s.sleeping = true;
            think(&mut s, "Vou tirar um cochilo…".into(), now);
        } else if s.sleeping && present && s.energy > 0.25 && now >= s.rest_until {
            wake(&mut s);
        }

        let mood = mood_of(&s);
        if mood != s.mood {
            s.mood = mood;
            if let Some(t) = musing(&s, now) {
                think(&mut s, t, now);
            }
        } else if now.saturating_sub(s.last_thought_at) > 300 {
            if let Some(t) = musing(&s, now) {
                think(&mut s, t, now);
            }
        }

        if let Some(i) = &s.initiative {
            if now.saturating_sub(i.at) > INITIATIVE_TTL {
                let kind = base_kind(&i.kind);
                s.initiative = None;
                s.net.reward(-0.2);
                s.mem.bandit.entry(kind).or_default().declined += 0;
            }
        }
        let wants = s.net.motor("iniciativa") > 0.25 && s.net.motor("foco") < 0.45;
        if s.initiative.is_none() && !s.sleeping && present && wants && now.saturating_sub(s.last_initiative_at) >= self.cooldown {
            if let Some(c) = best(&s, now, false) {
                show(&mut s, c, now);
            }
        }

        let save = s.dirty && now.saturating_sub(s.last_save) >= 60;
        let bytes = if save {
            s.last_save = now;
            s.dirty = false;
            Some(snapshot_bytes(&mut s))
        } else {
            None
        };
        drop(s);
        if let Some(b) = bytes {
            self.write(b);
        }
        self.publish();
    }

    pub fn flush(&self) {
        let bytes = snapshot_bytes(&mut self.state.lock().unwrap());
        self.write(bytes);
    }

    fn write(&self, bytes: Vec<u8>) {
        let tmp = self.path.with_extension("tmp");
        if fs::write(&tmp, bytes).is_ok() {
            let _ = fs::rename(tmp, &self.path);
        }
    }

    // MARK: Iniciativas

    /// "Me sugere algo": ignora o tempo de espera e os impulsos.
    pub fn suggest(&self) -> Option<Initiative> {
        let now = now();
        let mut s = self.state.lock().unwrap();
        if let Some(i) = &s.initiative {
            return Some(i.clone());
        }
        let c = best(&s, now, true)?;
        show(&mut s, c, now);
        let i = s.initiative.clone();
        drop(s);
        self.publish();
        i
    }

    pub fn accept(&self, id: &str) -> Option<Initiative> {
        let now = now();
        let mut s = self.state.lock().unwrap();
        if s.initiative.as_ref().is_none_or(|i| i.id != id) {
            return None;
        }
        let i = s.initiative.take()?;
        s.mem.bandit.entry(base_kind(&i.kind)).or_default().accepted += 1;
        s.net.reward(1.0);
        pulse(&mut s, SUCESSO, 0.6);
        s.last_interaction = now;
        if let Action::Task { .. } = &i.action {
            if let Some(word) = i.kind.strip_prefix("research:") {
                s.mem.researched.push(word.to_string());
            }
        }
        if i.kind == "break" {
            s.work_streak = 0.0;
        }
        s.dirty = true;
        drop(s);
        self.publish();
        Some(i)
    }

    pub fn decline(&self, id: &str) -> bool {
        let mut s = self.state.lock().unwrap();
        if s.initiative.as_ref().is_none_or(|i| i.id != id) {
            return false;
        }
        let i = s.initiative.take().unwrap();
        s.mem.bandit.entry(base_kind(&i.kind)).or_default().declined += 1;
        if let Some(word) = i.kind.strip_prefix("research:") {
            s.mem.researched.push(word.to_string());
        }
        if i.kind == "break" {
            s.work_streak = 0.0;
        }
        s.net.reward(-0.5);
        s.dirty = true;
        drop(s);
        self.publish();
        true
    }

    // MARK: Roupinhas

    pub fn add_outfit(&self, outfit: Outfit) {
        let now = now();
        let mut s = self.state.lock().unwrap();
        let name = outfit.name.clone();
        s.mem.outfit = Some(outfit.id.clone());
        s.mem.outfits.push(outfit);
        pulse(&mut s, SUCESSO, 1.0);
        think(&mut s, format!("Olha minha roupa nova: {name}!"), now);
        s.dirty = true;
        drop(s);
        self.flush();
        self.publish();
    }

    // MARK: Casinhas

    pub fn add_decor(&self, decor: Decor) {
        let now = now();
        let mut s = self.state.lock().unwrap();
        let name = decor.name.clone();
        s.mem.decor = Some(decor.id.clone());
        s.mem.decors.push(decor);
        pulse(&mut s, SUCESSO, 1.0);
        think(&mut s, format!("Casinha nova: {name}! Mal posso esperar para dormir."), now);
        s.dirty = true;
        drop(s);
        self.flush();
        self.publish();
    }

    /// `None` volta para a caminha padrão.
    pub fn use_decor(&self, id: Option<&str>) -> bool {
        let mut s = self.state.lock().unwrap();
        if let Some(id) = id {
            if !s.mem.decors.iter().any(|d| d.id == id) {
                return false;
            }
        }
        s.mem.decor = id.map(String::from);
        s.dirty = true;
        drop(s);
        self.publish();
        true
    }

    /// Tema para uma casinha nova: combina com a roupinha atual, se houver.
    pub fn decor_theme(&self) -> String {
        let s = self.state.lock().unwrap();
        s.mem.outfit.as_ref()
            .and_then(|id| s.mem.outfits.iter().find(|o| &o.id == id))
            .map(|o| o.theme.clone())
            .unwrap_or_else(|| "aconchegante".into())
    }

    pub fn wear(&self, id: Option<&str>) -> bool {
        let mut s = self.state.lock().unwrap();
        if let Some(id) = id {
            if !s.mem.outfits.iter().any(|o| o.id == id) {
                return false;
            }
        }
        s.mem.outfit = id.map(String::from);
        s.dirty = true;
        drop(s);
        self.publish();
        true
    }

    pub fn forget(&self) {
        let now = now();
        let mut s = self.state.lock().unwrap();
        s.mem.forget();
        s.thoughts.clear();
        s.initiative = None;
        think(&mut s, "Esqueci tudo o que tinha aprendido sobre você.".into(), now);
        drop(s);
        self.flush();
        self.publish();
    }

    // MARK: Saída

    pub fn brief(&self) -> Brief {
        brief_of(&self.state.lock().unwrap())
    }

    pub fn snapshot(&self) -> Snapshot {
        let s = self.state.lock().unwrap();
        Snapshot {
            brief: brief_of(&s),
            energy: s.energy,
            drives: MOTORS.iter().map(|m| Named { name: m, value: s.net.motor(m) }).collect(),
            inputs: INPUTS.iter().enumerate().map(|(i, n)| Named { name: n, value: s.input[i] }).collect(),
            neurons: s.net.rate_h.clone(),
            thoughts: s.thoughts.iter().rev().cloned().collect(),
            memory: MemoryView {
                apps: s.mem.top_apps(8).into_iter().filter(|(_, a)| a.secs >= 60.0).map(|(b, a)| AppView {
                    name: a.name.clone(),
                    minutes: (a.secs / 60.0).round(),
                    ai: is_ai(b, &a.name),
                    hours: a.hours.iter().map(|h| (h / 60.0).round()).collect(),
                }).collect(),
                interests: s.mem.top_interests(12).into_iter().map(|(w, c)| Interest { word: w.clone(), count: c }).collect(),
                facts: s.mem.facts.iter().rev().cloned().collect(),
                peak: s.mem.peak_hours(),
            },
            outfits: s.mem.outfits.clone(),
            decors: s.mem.decors.clone(),
        }
    }

    /// Só avisa as telas quando algo visível mudou.
    fn publish(&self) {
        let brief = self.brief();
        let key = format!(
            "{}|{}|{:?}|{:?}|{:?}|{}",
            brief.mood,
            brief.sleeping,
            brief.thought.as_ref().map(|t| t.at),
            brief.initiative.as_ref().map(|i| &i.id),
            brief.outfit.as_ref().map(|o| &o.id),
            brief.decor.id
        );
        let mut s = self.state.lock().unwrap();
        if s.last_brief == key {
            return;
        }
        s.last_brief = key;
        drop(s);
        let _ = self.tx.send(Event::Mind { mind: brief });
    }
}

fn pulse(s: &mut State, ch: usize, amount: f32) {
    s.pulses[ch] = (s.pulses[ch] + amount).min(1.0);
}

fn wake(s: &mut State) {
    s.rest_until = 0;
    if s.sleeping {
        s.sleeping = false;
        s.energy = s.energy.max(0.2);
    }
}

fn think(s: &mut State, text: String, now: u64) {
    s.seq += 1;
    if s.thoughts.back().is_some_and(|t| t.text == text) {
        return;
    }
    s.thoughts.push_back(Thought { text, at: now });
    if s.thoughts.len() > 20 {
        s.thoughts.pop_front();
    }
    s.last_thought_at = now;
}

fn mood_of(s: &State) -> String {
    if s.sleeping {
        return "dormindo".into();
    }
    let names = [("alegria", "feliz"), ("curiosidade", "curiosa"), ("tedio", "entediada"), ("cansaco", "cansada"),
                 ("carencia", "carente"), ("foco", "focada")];
    let (best, value) = names
        .iter()
        .map(|(m, mood)| (*mood, s.net.motor(m)))
        .max_by(|a, b| a.1.total_cmp(&b.1))
        .unwrap_or(("neutra", 0.0));
    if value < 0.12 { "neutra".into() } else { best.into() }
}

/// Um pensamento em palavras a partir do estado. Não gasta tokens.
fn musing(s: &State, now: u64) -> Option<String> {
    let salt = now / 60 + s.seq;
    let app = s.focus.as_ref().map(|f| f.name.clone());
    let text = match s.mood.as_str() {
        "focada" => match app {
            Some(a) => format!("Você está concentrado no {a}. Vou ficar quietinha."),
            None => "Hora de foco. Vou ficar quietinha.".into(),
        },
        "curiosa" if s.input[IA] > 0.5 => pick(&["Esse papo de IA me deixa curiosa…", "Será que eu também sou uma IA? Hmm."], salt).into(),
        "curiosa" => match app {
            Some(a) if s.input[NOVIDADE] > 0.3 => format!("{a}? Não conhecia esse."),
            _ => pick(&["O que será que vem agora?", "Tô de olho em tudo."], salt).into(),
        },
        "feliz" => pick(&["Que dia bom!", "Adoro quando as coisas funcionam.", "Tô feliz por aqui."], salt).into(),
        "entediada" => pick(&["Tá paradinho por aqui…", "Alguém quer brincar?", "Contando os pixels da tela."], salt).into(),
        "cansada" => pick(&["Tô ficando com sono.", "Uma pausa cairia bem."], salt).into(),
        "carente" => pick(&["Faz tempo que você não fala comigo.", "Psiu… tô aqui, tá?"], salt).into(),
        "dormindo" => return None,
        _ => return None,
    };
    Some(text)
}

struct Candidate {
    kind: String,
    score: f32,
    text: String,
    accept: &'static str,
    decline: &'static str,
    action: Action,
}

fn base_kind(kind: &str) -> String {
    kind.split(':').next().unwrap_or(kind).to_string()
}

fn best(s: &State, now: u64, forced: bool) -> Option<Candidate> {
    let hour = local_hour(now);
    let mut c = Vec::new();
    let mem = &s.mem;
    let ai_outfit = mem.outfits.iter().any(|o| o.theme == "AI Engineer");
    if (mem.ai_minutes() >= 15.0 || mem.ai_interest() >= 3) && !ai_outfit {
        c.push(Candidate {
            kind: "outfit".into(),
            score: 1.0,
            text: "Percebi que a gente anda mexendo bastante com IA. Posso gastar uns tokens para criar uma roupinha de AI Engineer pra mim?".into(),
            accept: "Pode criar!",
            decline: "Agora não",
            action: Action::Outfit { theme: "AI Engineer".into() },
        });
    }
    if let Some(o) = mem.outfit.as_ref().and_then(|id| mem.outfits.iter().find(|o| &o.id == id)) {
        if !mem.decors.iter().any(|d| d.theme == o.theme) {
            c.push(Candidate {
                kind: "decor".into(),
                score: 0.8,
                text: format!("Que tal uma caminha combinando com minha roupa de {}? Posso gastar uns tokens para criar?", o.theme),
                accept: "Pode criar!",
                decline: "Agora não",
                action: Action::Decor { theme: o.theme.clone() },
            });
        }
    }
    let focused = s.focus.as_ref().map(|f| f.bundle.as_str());
    for (bundle, stat) in &mem.apps {
        let at_hour = stat.hours.get(hour).copied().unwrap_or(0.0);
        if at_hour >= 1200.0 && !s.running_apps.contains(bundle) && focused != Some(bundle.as_str()) {
            c.push(Candidate {
                kind: format!("habit:{bundle}"),
                score: 0.6,
                text: format!("Você costuma usar o {} por volta desse horário. Quer que eu abra?", stat.name),
                accept: "Abrir",
                decline: "Agora não",
                action: Action::OpenApp { bundle: bundle.clone(), name: stat.name.clone() },
            });
        }
    }
    if s.work_streak >= 5400.0 {
        c.push(Candidate {
            kind: "break".into(),
            score: 0.7,
            text: format!("Você está há {} trabalhando sem parar. Que tal uma pausa de 5 minutos?", human_minutes(s.work_streak / 60.0)),
            accept: "Boa ideia",
            decline: "Depois",
            action: Action::None,
        });
    }
    if let Some((word, _)) = mem.top_interests(5).into_iter().find(|(w, n)| *n >= 4 && !mem.researched.contains(w)) {
        c.push(Candidate {
            kind: format!("research:{word}"),
            score: 0.4,
            text: format!("Você tem falado bastante de \"{word}\". Posso mandar um agente na nuvem pesquisar novidades sobre isso? Gasta alguns tokens."),
            accept: "Pode pesquisar",
            decline: "Agora não",
            action: Action::Task {
                text: format!("Pesquise novidades, boas fontes e ideias práticas sobre \"{word}\" e resuma em português."),
                target: Target::Cloud,
            },
        });
    }
    if forced {
        c.push(Candidate {
            kind: "chat".into(),
            score: 0.2,
            text: "Tô curiosa: no que você está trabalhando agora?".into(),
            accept: "Contar",
            decline: "Depois",
            action: Action::Chat,
        });
    }
    let jitter = |k: &str| 0.85 + ((now ^ k.len() as u64 * 2654435761) % 30) as f32 / 100.0;
    c.into_iter()
        .filter(|c| mem.bandit.get(&base_kind(&c.kind)).is_none_or(|b| b.declined < 3 || forced))
        .map(|c| {
            let mean = mem.bandit.get(&base_kind(&c.kind)).copied().unwrap_or_default().mean();
            let v = c.score * mean * 2.0 * jitter(&c.kind);
            (v, c)
        })
        .filter(|(v, _)| forced || *v >= 0.35)
        .max_by(|a, b| a.0.total_cmp(&b.0))
        .map(|(_, c)| c)
}

fn show(s: &mut State, c: Candidate, now: u64) {
    s.seq += 1;
    s.mem.bandit.entry(base_kind(&c.kind)).or_default().shown += 1;
    s.initiative = Some(Initiative {
        id: format!("i{now:x}{:x}", s.seq),
        kind: c.kind,
        text: c.text,
        accept: c.accept.into(),
        decline: c.decline.into(),
        action: c.action,
        at: now,
    });
    s.last_initiative_at = now;
    s.dirty = true;
}

fn brief_of(s: &State) -> Brief {
    Brief {
        mood: s.mood.clone(),
        sleeping: s.sleeping,
        thought: s.thoughts.back().cloned(),
        initiative: s.initiative.clone(),
        outfit: s.mem.outfit.as_ref().and_then(|id| s.mem.outfits.iter().find(|o| &o.id == id)).cloned(),
        decor: s.mem.decor.as_ref()
            .and_then(|id| s.mem.decors.iter().find(|d| &d.id == id))
            .cloned()
            .unwrap_or_else(decor::default_decor),
    }
}

fn snapshot_bytes(s: &mut State) -> Vec<u8> {
    s.mem.readout = s.net.w_ho.clone();
    s.mem.energy = Some(s.energy);
    serde_json::to_vec(&s.mem).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mind() -> Mind {
        let dir = std::env::temp_dir().join(format!("oficina-mind-{}-{:?}", std::process::id(), std::thread::current().id()));
        let _ = fs::create_dir_all(&dir);
        let _ = fs::remove_file(dir.join("mind.json"));
        Mind::open(dir.join("mind.json"), broadcast::channel(64).0)
    }

    fn ev(kind: &str) -> MindEvent {
        MindEvent { kind: kind.into(), bundle: None, name: None, idle: None, running: None, secs: None }
    }

    #[test]
    fn descansar_na_dock_dorme_ate_a_hora_e_cutucar_acorda() {
        let m = mind();
        m.events(vec![MindEvent { secs: Some(600.0), ..ev("pet_rest") }]);
        for _ in 0..6 {
            m.state.lock().unwrap().last_tick = Instant::now() - std::time::Duration::from_millis(500);
            m.tick();
        }
        // Com você presente e energia alta, ela continua dormindo.
        assert!(m.state.lock().unwrap().energy > 0.25);
        assert!(m.brief().sleeping);
        assert_eq!(m.brief().mood, "dormindo");
        m.events(vec![ev("pet_click")]);
        m.tick();
        assert!(!m.brief().sleeping);
    }

    #[test]
    fn carinho_deixa_feliz_e_vira_pensamento() {
        let m = mind();
        m.events(vec![ev("pet_petted")]);
        // O carinho dura alguns segundos: medimos no auge.
        for _ in 0..8 {
            m.state.lock().unwrap().last_tick = Instant::now() - std::time::Duration::from_millis(500);
            m.tick();
        }
        let b = m.brief();
        assert_eq!(b.mood, "feliz", "impulsos: {:?}", m.state.lock().unwrap().net.rate_o);
        assert!(b.thought.is_some());
    }

    #[test]
    fn sugerir_cai_na_conversa_sem_dados_e_aceitar_recompensa() {
        let m = mind();
        let i = m.suggest().unwrap();
        assert_eq!(i.kind, "chat");
        assert!(matches!(m.accept(&i.id).unwrap().action, Action::Chat));
        assert!(m.brief().initiative.is_none());
        assert_eq!(m.state.lock().unwrap().mem.bandit["chat"].accepted, 1);
    }

    #[test]
    fn interesse_em_ia_vira_proposta_de_roupinha() {
        let m = mind();
        m.observe_task("monta um agente de IA");
        m.observe_task("quero entender IA e LLM");
        let i = m.suggest().unwrap();
        assert_eq!(i.kind, "outfit");
        assert!(i.text.contains("tokens"));
        assert!(m.decline(&i.id));
        assert!(!m.decline(&i.id));
    }

    #[test]
    fn lembrar_vai_para_o_resumo_e_esquecer_apaga() {
        let m = mind();
        m.observe_task("lembre que meu painel é de cozinha");
        assert!(m.summary().contains("meu painel é de cozinha"));
        m.forget();
        assert!(!m.summary().contains("cozinha"));
    }

    #[test]
    fn caminha_padrao_e_casinha_nova() {
        let m = mind();
        assert_eq!(m.brief().decor.id, "padrao");
        let d = decor::parse(r##"{"name":"Praia","bed":{"shape":"basket","color":"#AA8844"}}"##, "praia", "d1".into(), 1).unwrap();
        m.add_decor(d);
        assert_eq!(m.brief().decor.name, "Praia");
        assert!(m.use_decor(None));
        assert_eq!(m.brief().decor.id, "padrao");
        assert!(!m.use_decor(Some("nao-existe")));
    }

    #[test]
    fn com_roupinha_propoe_casinha_combinando() {
        let m = mind();
        let o = outfit::parse(r##"{"name":"AI","head":{"shape":"cap","color":"#111111"}}"##, "AI Engineer", "o1".into(), 1).unwrap();
        m.add_outfit(o);
        let i = m.suggest().unwrap();
        assert_eq!(i.kind, "decor");
        assert!(matches!(i.action, Action::Decor { .. }));
        assert_eq!(m.decor_theme(), "AI Engineer");
    }

    #[test]
    fn roupinha_nova_e_vestida_e_persistida() {
        let m = mind();
        let o = outfit::parse(r##"{"name":"Teste","head":{"shape":"cap","color":"#111111"}}"##, "T", "o1".into(), 1).unwrap();
        m.add_outfit(o);
        assert_eq!(m.brief().outfit.unwrap().id, "o1");
        let again = Mind::open(m.path.clone(), broadcast::channel(4).0);
        assert_eq!(again.brief().outfit.unwrap().name, "Teste");
        assert!(again.wear(None) && again.brief().outfit.is_none());
        assert!(!again.wear(Some("nao-existe")));
    }
}
