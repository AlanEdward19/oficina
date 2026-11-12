//! Presença única: existe uma Faísca, e ela está em um lugar de cada vez.
//!
//! A mente fica aqui (a "casa", o Mac). Cada dispositivo é um corpo: a caixa de
//! som da sala, o celular. Quem tem a posse de presença fala e escuta; os outros
//! ficam quietos. Corpos falam com o core por uma porta separada, com um token
//! só deles, recebido no pareamento por código.

use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, VecDeque},
    fs,
    path::PathBuf,
    sync::Mutex,
};
use tokio::sync::Notify;

/// O Mac, onde mora a mente.
pub const HOME: &str = "casa";
/// Sem sinal por tanto tempo, o corpo conta como desligado.
const OFFLINE: u64 = 30;
/// Conversa parada por tanto tempo acaba e ela volta para casa.
const IDLE_RETURN: u64 = 90;
/// "Já volto": quanto ela espera a conversa terminar antes de vir.
const WILL_COME: u64 = 20;
const PAIRING_TTL: u64 = 600;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Body {
    pub id: String,
    pub name: String,
    pub room: String,
    /// caixa, celular…
    pub kind: String,
    pub token: String,
    /// A conversa em que a Faísca fala com quem está ali.
    pub conversation: String,
    pub created: u64,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct BodyView {
    pub id: String,
    pub name: String,
    pub room: String,
    pub kind: String,
    pub online: bool,
}

/// O que um corpo recebe para fazer.
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Command {
    /// A Faísca chegou: acende, fica atenta.
    Arrive,
    /// Ela foi embora: apaga.
    Leave,
    /// Falar. `audio` é o caminho do WAV, quando o Mac já sintetizou.
    Say { text: String, audio: Option<String> },
    /// Ouvir a resposta por até `secs` segundos.
    Listen { secs: u32 },
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct Talk {
    pub started: u64,
    pub last: u64,
    /// Última coisa que alguém disse ali, para contar a você.
    pub heard: Option<String>,
    /// Já avisou que vai embora assim que der.
    pub leaving_at: Option<u64>,
}

#[derive(Clone, Debug, Serialize)]
pub struct PresenceView {
    pub holder: String,
    pub name: String,
    pub room: String,
    pub since: u64,
    pub reason: String,
    pub importance: Option<String>,
    pub bodies: Vec<BodyView>,
    pub network: bool,
    pub pairing: Option<String>,
}

/// O resultado de você chamar enquanto ela está em outro lugar.
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(tag = "outcome", rename_all = "snake_case")]
pub enum CallOutcome {
    AlreadyHere,
    /// Despediu-se e veio.
    Came { farewell: String },
    /// Avisou que você chamou e vem quando a conversa acabar.
    WillCome { notice: String, message: String },
    /// A conversa é importante: fica e te avisa.
    Staying { message: String },
}

#[derive(Default, Serialize, Deserialize)]
#[serde(default)]
struct Saved {
    bodies: Vec<Body>,
    network: bool,
}

struct Live {
    holder: String,
    since: u64,
    reason: String,
    talk: Option<Talk>,
    seen: HashMap<String, u64>,
    queues: HashMap<String, VecDeque<Command>>,
    pairing: Option<(String, u64)>,
    /// Última vez que você falou com ela no Mac.
    home_active: u64,
}

pub struct Presences {
    path: PathBuf,
    saved: Mutex<Saved>,
    live: Mutex<Live>,
    pub notify: Notify,
}

/// Despedida no jeito da personalidade escolhida em Personalizar.
pub fn farewell(personality: &str, assistant: &str) -> String {
    let p = personality.to_lowercase();
    let _ = assistant;
    if ["engraçad", "humor", "piada", "brincalh"].iter().any(|k| p.contains(k)) {
        "Opa, o chefe chamou! Fui, mas depois a gente continua esse papo.".into()
    } else if ["formal", "séri", "seri", "objetiv"].iter().any(|k| p.contains(k)) {
        "Preciso atender um chamado agora. Com licença.".into()
    } else if ["mentor", "paciente", "explica"].iter().any(|k| p.contains(k)) {
        "Preciso ir agora. Pensa no que conversamos, que depois a gente continua.".into()
    } else if ["carinhos", "fofa", "doce"].iter().any(|k| p.contains(k)) {
        "Ai, estão me chamando! Já já eu volto, tá?".into()
    } else {
        "Estão me chamando. Até já!".into()
    }
}

fn clean(s: &str, max: usize) -> String {
    s.trim().chars().filter(|c| !c.is_control()).take(max).collect()
}

impl Presences {
    pub fn open(path: PathBuf, now: u64) -> Self {
        let saved: Saved = fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        Self {
            path,
            saved: Mutex::new(saved),
            live: Mutex::new(Live {
                holder: HOME.into(),
                since: now,
                reason: String::new(),
                talk: None,
                seen: HashMap::new(),
                queues: HashMap::new(),
                pairing: None,
                home_active: 0,
            }),
            notify: Notify::new(),
        }
    }

    fn save(&self, s: &Saved) {
        let tmp = self.path.with_extension("tmp");
        if fs::write(&tmp, serde_json::to_vec_pretty(s).unwrap_or_default()).is_ok() {
            let _ = fs::rename(tmp, &self.path);
        }
    }

    // MARK: Corpos

    pub fn network(&self) -> bool {
        self.saved.lock().unwrap().network
    }

    pub fn set_network(&self, on: bool) {
        let mut s = self.saved.lock().unwrap();
        s.network = on;
        self.save(&s);
    }

    /// Código de 6 dígitos, vale 10 minutos e uma vez.
    pub fn start_pairing(&self, now: u64) -> String {
        let hex = crate::config::random_hex(4).unwrap_or_else(|_| format!("{now:08x}"));
        let n = u32::from_str_radix(&hex[..8], 16).unwrap_or(now as u32) % 1_000_000;
        let code = format!("{n:06}");
        self.live.lock().unwrap().pairing = Some((code.clone(), now + PAIRING_TTL));
        code
    }

    pub fn pair(&self, code: &str, name: &str, room: &str, kind: &str, conversation: String, now: u64) -> Result<Body, String> {
        {
            let mut l = self.live.lock().unwrap();
            match &l.pairing {
                Some((c, until)) if c == code.trim() && now <= *until => l.pairing = None,
                _ => return Err("Código inválido ou vencido. Gere outro em Dispositivos.".into()),
            }
        }
        let room = clean(room, 40);
        let body = Body {
            id: format!("b{:x}", crate::conv::next_id()),
            name: { let n = clean(name, 40); if n.is_empty() { format!("Caixa da {}", if room.is_empty() { "casa" } else { &room }) } else { n } },
            room: if room.is_empty() { "sala".into() } else { room },
            kind: if kind.trim().is_empty() { "caixa".into() } else { clean(kind, 20) },
            token: crate::config::random_hex(32).map_err(|e| e.to_string())?,
            conversation,
            created: now,
        };
        let mut s = self.saved.lock().unwrap();
        s.bodies.push(body.clone());
        self.save(&s);
        self.live.lock().unwrap().seen.insert(body.id.clone(), now);
        Ok(body)
    }

    pub fn forget(&self, id: &str) -> Option<Body> {
        let mut s = self.saved.lock().unwrap();
        let i = s.bodies.iter().position(|b| b.id == id)?;
        let b = s.bodies.remove(i);
        self.save(&s);
        drop(s);
        let mut l = self.live.lock().unwrap();
        l.queues.remove(id);
        if l.holder == id {
            l.holder = HOME.into();
            l.talk = None;
        }
        Some(b)
    }

    /// Token de corpo → corpo. Comparação em tempo constante.
    pub fn auth(&self, token: &str) -> Option<Body> {
        let s = self.saved.lock().unwrap();
        s.bodies.iter().find(|b| crate::token_eq(token, &b.token)).cloned()
    }

    pub fn body(&self, id: &str) -> Option<Body> {
        self.saved.lock().unwrap().bodies.iter().find(|b| b.id == id).cloned()
    }

    pub fn body_for_conversation(&self, conv: &str) -> Option<Body> {
        self.saved.lock().unwrap().bodies.iter().find(|b| b.conversation == conv).cloned()
    }

    /// Por cômodo ou nome, sem acento e sem caixa.
    pub fn find(&self, place: &str) -> Option<Body> {
        let want = fold(place);
        let s = self.saved.lock().unwrap();
        s.bodies.iter().find(|b| fold(&b.room) == want || fold(&b.name) == want)
            .or_else(|| s.bodies.iter().find(|b| want.contains(&fold(&b.room)) || fold(&b.name).contains(&want)))
            .cloned()
    }

    pub fn heartbeat(&self, id: &str, now: u64) {
        self.live.lock().unwrap().seen.insert(id.to_string(), now);
    }

    fn online(l: &Live, id: &str, now: u64) -> bool {
        id == HOME || l.seen.get(id).is_some_and(|t| now.saturating_sub(*t) <= OFFLINE)
    }

    // MARK: Posse

    pub fn holder(&self) -> String {
        self.live.lock().unwrap().holder.clone()
    }

    fn push(l: &mut Live, id: &str, c: Command) {
        if id == HOME {
            return;
        }
        let q = l.queues.entry(id.to_string()).or_default();
        q.push_back(c);
        while q.len() > 32 {
            q.pop_front();
        }
    }

    /// Leva a Faísca até um corpo. Só um lugar por vez: o anterior recebe "saiu".
    pub fn move_to(&self, id: &str, reason: &str, now: u64) -> Result<(), String> {
        let known = id == HOME || self.body(id).is_some();
        if !known {
            return Err("Esse dispositivo não existe.".into());
        }
        let mut l = self.live.lock().unwrap();
        if !Self::online(&l, id, now) {
            return Err("Esse dispositivo está desligado ou fora da rede.".into());
        }
        if l.holder == id {
            return Ok(());
        }
        let old = std::mem::replace(&mut l.holder, id.to_string());
        Self::push(&mut l, &old, Command::Leave);
        Self::push(&mut l, id, Command::Arrive);
        l.since = now;
        l.reason = clean(reason, 200);
        l.talk = (id != HOME).then(|| Talk { started: now, last: now, ..Default::default() });
        drop(l);
        self.notify.notify_waiters();
        Ok(())
    }

    /// Falar onde ela está. Fora de casa, a conversa fica viva.
    pub fn say(&self, id: &str, text: String, audio: Option<String>, listen: bool, now: u64) -> bool {
        let mut l = self.live.lock().unwrap();
        if l.holder != id || id == HOME {
            return false;
        }
        Self::push(&mut l, id, Command::Say { text, audio });
        if listen {
            Self::push(&mut l, id, Command::Listen { secs: 8 });
        }
        if let Some(t) = l.talk.as_mut() {
            t.last = now;
        }
        drop(l);
        self.notify.notify_waiters();
        true
    }

    /// Alguém falou com ela num corpo.
    pub fn heard(&self, id: &str, text: &str, now: u64) {
        let mut l = self.live.lock().unwrap();
        if l.holder == id {
            let t = l.talk.get_or_insert_with(|| Talk { started: now, ..Default::default() });
            t.last = now;
            t.heard = Some(clean(text, 300));
        }
    }

    /// Você falou com ela no Mac.
    pub fn home_activity(&self, now: u64) {
        self.live.lock().unwrap().home_active = now;
    }

    pub fn home_busy(&self, now: u64) -> bool {
        let l = self.live.lock().unwrap();
        l.holder == HOME && now.saturating_sub(l.home_active) < 60
    }

    /// Comandos pendentes de um corpo (o corpo espera por eles).
    pub fn take(&self, id: &str) -> Vec<Command> {
        let mut l = self.live.lock().unwrap();
        l.queues.get_mut(id).map(|q| q.drain(..).collect()).unwrap_or_default()
    }

    /// alta: ela está fazendo algo que pediram ali; media: falaram há pouco; baixa: papo parado.
    pub fn importance(&self, task_running: bool, now: u64) -> Option<&'static str> {
        let l = self.live.lock().unwrap();
        let t = l.talk.as_ref().filter(|_| l.holder != HOME)?;
        Some(if task_running {
            "alta"
        } else if now.saturating_sub(t.last) < 30 {
            "media"
        } else {
            "baixa"
        })
    }

    /// Você chamou de casa. Pesa a conversa; `force` sempre traz ela.
    pub fn call(&self, force: bool, task_running: bool, personality: &str, assistant: &str, now: u64) -> CallOutcome {
        let holder = self.holder();
        if holder == HOME {
            return CallOutcome::AlreadyHere;
        }
        let room = self.body(&holder).map(|b| b.room).unwrap_or_else(|| "outro lugar".into());
        let importance = self.importance(task_running, now).unwrap_or("baixa");
        if force || importance == "baixa" {
            let bye = farewell(personality, assistant);
            self.say(&holder, bye.clone(), None, false, now);
            let _ = self.move_to(HOME, "você chamou", now);
            return CallOutcome::Came { farewell: bye };
        }
        if importance == "media" {
            let notice = "Estão me chamando no computador. Já já eu vou.".to_string();
            self.say(&holder, notice.clone(), None, false, now);
            if let Some(t) = self.live.lock().unwrap().talk.as_mut() {
                t.leaving_at = Some(now + WILL_COME);
            }
            return CallOutcome::WillCome { notice, message: format!("Tô terminando uma conversa na {room}. Já vou!") };
        }
        CallOutcome::Staying { message: format!("Tô na {room} ajudando com um pedido. Assim que terminar, eu vou. Se for urgente, me chame com \"vem agora\".") }
    }

    /// Volta para casa quando o corpo some, a conversa esfria ou o "já volto" vence.
    /// Devolve o que ela ouviu por lá, para contar a você.
    pub fn tick(&self, task_running: bool, now: u64) -> Option<(String, Option<String>)> {
        let (holder, back, heard) = {
            let l = self.live.lock().unwrap();
            if l.holder == HOME {
                return None;
            }
            let t = l.talk.clone().unwrap_or_default();
            let offline = !Self::online(&l, &l.holder, now);
            let idle = now.saturating_sub(t.last) >= IDLE_RETURN && !task_running;
            let due = t.leaving_at.is_some_and(|at| now >= at) && !task_running;
            (l.holder.clone(), offline || idle || due, t.heard)
        };
        if !back {
            return None;
        }
        let room = self.body(&holder).map(|b| b.room).unwrap_or_default();
        let _ = self.move_to(HOME, "voltou", now);
        Some((room, heard))
    }

    pub fn view(&self, task_running: bool, now: u64) -> PresenceView {
        let s = self.saved.lock().unwrap();
        let l = self.live.lock().unwrap();
        let b = s.bodies.iter().find(|b| b.id == l.holder);
        let importance = l.talk.as_ref().filter(|_| l.holder != HOME).map(|t| {
            if task_running { "alta" } else if now.saturating_sub(t.last) < 30 { "media" } else { "baixa" }
        });
        PresenceView {
            holder: l.holder.clone(),
            name: b.map(|b| b.name.clone()).unwrap_or_else(|| "Mac".into()),
            room: b.map(|b| b.room.clone()).unwrap_or_else(|| "computador".into()),
            since: l.since,
            reason: l.reason.clone(),
            importance: importance.map(String::from),
            bodies: s.bodies.iter().map(|b| BodyView {
                id: b.id.clone(),
                name: b.name.clone(),
                room: b.room.clone(),
                kind: b.kind.clone(),
                online: Self::online(&l, &b.id, now),
            }).collect(),
            network: s.network,
            pairing: l.pairing.as_ref().filter(|(_, until)| now <= *until).map(|(c, _)| c.clone()),
        }
    }
}

fn fold(s: &str) -> String {
    s.to_lowercase()
        .chars()
        .map(|c| match c {
            'á' | 'à' | 'â' | 'ã' => 'a',
            'é' | 'ê' => 'e',
            'í' => 'i',
            'ó' | 'ô' | 'õ' => 'o',
            'ú' => 'u',
            'ç' => 'c',
            c => c,
        })
        .filter(|c| c.is_alphanumeric() || *c == ' ')
        .collect::<String>()
        .trim()
        .trim_start_matches("a ")
        .trim_start_matches("o ")
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn presences() -> Presences {
        let dir = std::env::temp_dir().join(format!("oficina-presenca-{}-{:?}", std::process::id(), std::thread::current().id()));
        let _ = fs::create_dir_all(&dir);
        let _ = fs::remove_file(dir.join("presenca.json"));
        Presences::open(dir.join("presenca.json"), 0)
    }

    fn caixa(p: &Presences, room: &str, now: u64) -> Body {
        let code = p.start_pairing(now);
        p.pair(&code, "", room, "caixa", format!("c{room}"), now).unwrap()
    }

    #[test]
    fn pareamento_vale_uma_vez_e_vence() {
        let p = presences();
        let code = p.start_pairing(100);
        assert_eq!(code.len(), 6);
        assert!(p.pair("000000x", "x", "sala", "", "c".into(), 100).is_err());
        let b = p.pair(&code, "", "Sala", "", "c".into(), 100).unwrap();
        assert_eq!((b.name.as_str(), b.room.as_str(), b.kind.as_str()), ("Caixa da Sala", "Sala", "caixa"));
        assert!(p.pair(&code, "", "sala", "", "c".into(), 100).is_err(), "código vale uma vez");
        let late = p.start_pairing(100);
        assert!(p.pair(&late, "", "x", "", "c".into(), 100 + PAIRING_TTL + 1).is_err());
        assert_eq!(p.auth(&b.token).unwrap().id, b.id);
        assert!(p.auth("errado").is_none());
        assert_eq!(p.find("a sala").unwrap().id, b.id);
        assert_eq!(p.find("SALA").unwrap().id, b.id);
    }

    #[test]
    fn uma_faisca_so() {
        let p = presences();
        let sala = caixa(&p, "sala", 10);
        let quarto = caixa(&p, "quarto", 10);
        p.move_to(&sala.id, "chamar a Ana", 11).unwrap();
        assert_eq!(p.take(&sala.id), vec![Command::Arrive]);
        p.move_to(&quarto.id, "outra coisa", 12).unwrap();
        assert_eq!(p.take(&sala.id), vec![Command::Leave]);
        assert_eq!(p.holder(), quarto.id);
        assert!(!p.say(&sala.id, "oi".into(), None, false, 13), "só quem tem a posse fala");
        assert!(p.say(&quarto.id, "oi".into(), None, true, 13));
        assert_eq!(p.take(&quarto.id), vec![Command::Arrive, Command::Say { text: "oi".into(), audio: None }, Command::Listen { secs: 8 }]);
        assert!(p.move_to(&sala.id, "", 10 + OFFLINE + 5).is_err(), "desligado não recebe");
    }

    #[test]
    fn chamado_pesa_a_conversa_e_forcar_sempre_traz() {
        let p = presences();
        let sala = caixa(&p, "sala", 0);
        p.move_to(&sala.id, "", 0).unwrap();
        p.heard(&sala.id, "me ajuda com a lição?", 1);
        // Pedido em andamento: fica.
        assert!(matches!(p.call(false, true, "", "Faísca", 2), CallOutcome::Staying { .. }));
        assert_eq!(p.holder(), sala.id);
        // Conversa viva: avisa e vem depois.
        assert!(matches!(p.call(false, false, "", "Faísca", 3), CallOutcome::WillCome { .. }));
        assert!(p.tick(false, 10).is_none());
        let (room, heard) = p.tick(false, 3 + WILL_COME).unwrap();
        assert_eq!((room.as_str(), heard.as_deref()), ("sala", Some("me ajuda com a lição?")));
        assert_eq!(p.holder(), HOME);
        // Forçar: mesmo com pedido em andamento, despede-se e vem.
        p.heartbeat(&sala.id, 50);
        p.move_to(&sala.id, "", 50).unwrap();
        p.take(&sala.id);
        match p.call(true, true, "Bem-humorada, faz piadas leves.", "Faísca", 51) {
            CallOutcome::Came { farewell } => assert!(farewell.contains("chefe chamou")),
            o => panic!("{o:?}"),
        }
        assert_eq!(p.holder(), HOME);
        let cmds = p.take(&sala.id);
        assert!(matches!(&cmds[0], Command::Say { .. }));
        assert_eq!(cmds.last(), Some(&Command::Leave));
        assert_eq!(p.call(false, false, "", "", 52), CallOutcome::AlreadyHere);
    }

    #[test]
    fn volta_quando_esfria_ou_some() {
        let p = presences();
        let sala = caixa(&p, "sala", 0);
        p.move_to(&sala.id, "", 0).unwrap();
        p.heartbeat(&sala.id, IDLE_RETURN - 5);
        assert!(p.tick(false, IDLE_RETURN - 5).is_none());
        assert!(p.tick(true, IDLE_RETURN + 1).is_none(), "com pedido em andamento, espera");
        assert!(p.tick(false, IDLE_RETURN + 1).is_some());
        p.heartbeat(&sala.id, 200);
        p.move_to(&sala.id, "", 200).unwrap();
        assert!(p.tick(false, 200 + OFFLINE + 1).is_some(), "corpo sumiu: volta");
    }

    #[test]
    fn despedida_pela_personalidade() {
        assert!(farewell("Formal, objetiva e sem brincadeiras.", "F").contains("Com licença"));
        assert!(farewell("Curta, direta e carinhosa.", "F").contains("tá?"));
        assert!(farewell("Paciente, explica o porquê das coisas", "F").contains("Pensa no que"));
        assert_eq!(farewell("pirata", "F"), "Estão me chamando. Até já!");
    }
}
