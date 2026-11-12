//! A Faísca nos corpos: ir até um cômodo, falar e ouvir por lá, responder ao
//! seu chamado e voltar. A voz (texto em fala e fala em texto) é feita pelo app
//! no Mac; o core só guarda os áudios por pouco tempo e os entrega.

use crate::{
    engine::Engine,
    presence::{Body, CallOutcome, HOME, PresenceView},
    store::{Event, Status, Target, Task},
    usage::now,
};
use serde::Serialize;
use std::{
    collections::{HashSet, VecDeque},
    sync::{Arc, Mutex},
    time::Duration,
};

/// Pedido de voz para o app do Mac.
#[derive(Clone, Debug, Serialize)]
pub struct VoiceJob {
    pub id: String,
    /// render: texto → WAV; transcribe: WAV → texto
    pub kind: String,
    pub text: Option<String>,
}

struct Clip {
    id: String,
    bytes: Vec<u8>,
    /// Para qual corpo (render) ou de qual corpo (transcribe).
    body: String,
    kind: &'static str,
}

#[derive(Default)]
pub struct Voice {
    clips: Mutex<VecDeque<Clip>>,
    /// Pedidos de síntese ainda sem áudio.
    pending: Mutex<HashSet<String>>,
    /// Respostas das conversas dos corpos que ela já falou.
    spoken: Mutex<HashSet<String>>,
}

/// Áudios vivem pouco: no máximo 30 ou 24 MB.
const MAX_CLIPS: usize = 30;
const MAX_BYTES: usize = 24 * 1024 * 1024;
pub const MAX_AUDIO: usize = 4 * 1024 * 1024;

impl Voice {
    fn put(&self, id: String, bytes: Vec<u8>, body: String, kind: &'static str) {
        let mut c = self.clips.lock().unwrap();
        c.retain(|x| x.id != id);
        c.push_back(Clip { id, bytes, body, kind });
        while c.len() > MAX_CLIPS || c.iter().map(|x| x.bytes.len()).sum::<usize>() > MAX_BYTES {
            c.pop_front();
        }
    }

    pub fn get(&self, id: &str) -> Option<(Vec<u8>, String)> {
        self.clips.lock().unwrap().iter().find(|c| c.id == id).map(|c| (c.bytes.clone(), c.body.clone()))
    }

    fn has(&self, id: &str, kind: &str) -> bool {
        self.clips.lock().unwrap().iter().any(|c| c.id == id && c.kind == kind)
    }
}

fn clip_id() -> String {
    format!("v{:x}", crate::conv::next_id())
}

/// WAV não pode ser qualquer coisa: cabeçalho RIFF/WAVE e tamanho limitado.
pub fn is_wav(bytes: &[u8]) -> bool {
    bytes.len() > 44 && bytes.len() <= MAX_AUDIO && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WAVE"
}

const VOICE_RULE: &str = " Agora você está falando por voz, numa caixa de som, com quem estiver no cômodo (pode não ser o \
usuário). Responda curto, como fala, sem Markdown, listas ou emojis.";

impl Engine {
    fn room_task_running(&self) -> bool {
        let holder = self.presence.holder();
        let Some(b) = self.presence.body(&holder) else { return false };
        self.store.list().iter().any(|t| {
            t.conversation.as_deref() == Some(b.conversation.as_str())
                && matches!(t.status, Status::Running | Status::Queued | Status::AwaitingApproval)
        })
    }

    pub fn presence_view(&self) -> PresenceView {
        self.presence.view(self.room_task_running(), now())
    }

    pub fn publish_presence(&self) {
        let _ = self.store.tx.send(Event::Presence { presence: self.presence_view() });
    }

    /// O que o cérebro precisa saber sobre corpos, numa frase.
    pub fn presence_prompt(&self, conversation: &str) -> String {
        let v = self.presence_view();
        let mut out = String::new();
        if let Some(b) = self.presence.body_for_conversation(conversation) {
            out.push_str(&format!("{VOICE_RULE} O cômodo é: {}.", b.room));
        }
        let places: Vec<String> = v.bodies.iter().filter(|b| b.online).map(|b| b.room.clone()).collect();
        if !places.is_empty() {
            out.push_str(&format!(
                " Você existe em um lugar de cada vez e agora está em: {}. Dispositivos onde você pode ir: {}. \
Para ir até um deles falar com alguém, responda SOMENTE com `@@delegar presenca: <cômodo>: <o que dizer lá>`.",
                v.room,
                places.join(", ")
            ));
        }
        out
    }

    /// Vai até o cômodo e, se houver o que dizer, fala e espera a resposta.
    pub fn go(self: &Arc<Self>, place: &str, text: &str) -> Result<Body, String> {
        let body = if place == HOME {
            None
        } else {
            Some(self.presence.find(place).or_else(|| self.presence.body(place)).ok_or_else(|| format!("Não conheço nenhum dispositivo em \"{place}\".")))
        }
        .transpose()?;
        let id = body.as_ref().map(|b| b.id.clone()).unwrap_or_else(|| HOME.into());
        self.presence.move_to(&id, text, now())?;
        self.publish_presence();
        if let Some(b) = &body {
            if !text.trim().is_empty() {
                let (me, bid, text) = (self.clone(), b.id.clone(), text.to_string());
                tokio::spawn(async move { me.speak(&bid, &text, true).await });
            }
        }
        body.ok_or_else(|| "Voltei para o computador.".to_string())
    }

    /// Pede ao Mac a voz e entrega ao corpo. Sem o Mac por perto, vai só o texto.
    pub async fn speak(self: &Arc<Self>, body: &str, text: &str, listen: bool) {
        let id = clip_id();
        self.voice.pending.lock().unwrap().insert(id.clone());
        let _ = self.store.tx.send(Event::Voice { voice: VoiceJob { id: id.clone(), kind: "render".into(), text: Some(text.to_string()) } });
        // Sem o app do Mac para sintetizar, não adianta esperar (os testes usam 0).
        let wait = std::env::var("OFICINA_VOICE_WAIT_MS").ok().and_then(|v| v.parse::<u64>().ok()).unwrap_or(6000);
        for _ in 0..wait / 100 {
            if self.voice.has(&id, "tts") {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        self.voice.pending.lock().unwrap().remove(&id);
        let audio = self.voice.has(&id, "tts").then(|| format!("/v1/body/audio/{id}"));
        self.presence.say(body, text.to_string(), audio, listen, now());
    }

    /// O app do Mac devolveu a voz sintetizada.
    pub fn voice_rendered(&self, id: &str, bytes: Vec<u8>) -> bool {
        if !self.voice.pending.lock().unwrap().contains(id) || !is_wav(&bytes) {
            return false;
        }
        self.voice.put(id.to_string(), bytes, String::new(), "tts");
        true
    }

    /// O corpo mandou o que ouviu; o Mac transcreve.
    pub fn body_audio(&self, body: &Body, bytes: Vec<u8>) -> Result<String, String> {
        if !is_wav(&bytes) {
            return Err("Mande WAV de até 4 MB.".into());
        }
        let id = clip_id();
        self.voice.put(id.clone(), bytes, body.id.clone(), "mic");
        let _ = self.store.tx.send(Event::Voice { voice: VoiceJob { id: id.clone(), kind: "transcribe".into(), text: None } });
        Ok(id)
    }

    pub fn voice_clip(&self, id: &str) -> Option<Vec<u8>> {
        self.voice.get(id).map(|(b, _)| b)
    }

    /// O Mac transcreveu um áudio de corpo.
    pub fn voice_text(self: &Arc<Self>, id: &str, text: &str) -> Result<(), String> {
        let (_, body) = self.voice.get(id).ok_or("Esse áudio não existe mais.")?;
        let body = self.presence.body(&body).ok_or("Esse dispositivo não existe mais.")?;
        if text.trim().is_empty() {
            return Ok(());
        }
        self.heard(&body, text).map(|_| ())
    }

    /// Alguém falou com ela no cômodo: vira uma mensagem na conversa daquele corpo.
    pub fn heard(self: &Arc<Self>, body: &Body, text: &str) -> Result<Task, String> {
        if self.presence.holder() != body.id {
            return Err("A Faísca não está aqui agora.".into());
        }
        self.presence.heard(&body.id, text, now());
        self.submit(text, Target::Auto, None, Some(body.conversation.clone()))
    }

    /// O botão da caixa: alguém chama a Faísca para lá.
    pub fn body_call(self: &Arc<Self>, body: &Body) -> String {
        let n = now();
        if self.presence.holder() == body.id {
            self.presence.say(&body.id, "Tô aqui, pode falar.".into(), None, true, n);
            return "aqui".into();
        }
        if self.presence.home_busy(n) {
            self.mind.note(format!("Alguém na {} está me chamando.", body.room));
            return "ocupada".into();
        }
        match self.go(&body.id, "Oi! Pode falar.") {
            Ok(_) => "chegando".into(),
            Err(e) => e,
        }
    }

    /// Você chamou de casa. Pesa a conversa; `force` sempre traz ela.
    pub fn owner_call(self: &Arc<Self>, force: bool) -> CallOutcome {
        let s = self.factory.settings();
        let outcome = self.presence.call(force, self.room_task_running(), &s.personality, &s.name, now());
        match &outcome {
            CallOutcome::Came { .. } => self.mind.note("Voltei! Pode falar.".into()),
            CallOutcome::WillCome { message, .. } | CallOutcome::Staying { message } => self.mind.note(message.clone()),
            CallOutcome::AlreadyHere => {}
        }
        self.publish_presence();
        outcome
    }

    /// A cada segundo: fala as respostas das conversas dos corpos e volta para
    /// casa quando é hora.
    pub async fn presence_tick(self: &Arc<Self>, started: u64) {
        let holder = self.presence.holder();
        if let Some(b) = self.presence.body(&holder) {
            let done: Vec<Task> = self.store.list().into_iter().filter(|t| {
                t.conversation.as_deref() == Some(b.conversation.as_str())
                    && t.status == Status::Done
                    && t.created_at / 1000 >= started
                    && !t.output.trim().is_empty()
            }).collect();
            for t in done {
                if self.voice.spoken.lock().unwrap().insert(t.id.clone()) {
                    let (me, bid, text) = (self.clone(), b.id.clone(), t.output.clone());
                    tokio::spawn(async move { me.speak(&bid, &text, true).await });
                }
            }
        }
        if let Some((room, heard)) = self.presence.tick(self.room_task_running(), now()) {
            let said = heard.map(|h| format!(" Por lá disseram: \"{h}\"")).unwrap_or_default();
            self.mind.note(format!("Voltei da {room}.{said}"));
            self.publish_presence();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn so_aceita_wav() {
        let mut wav = b"RIFF\0\0\0\0WAVEfmt ".to_vec();
        wav.resize(100, 0);
        assert!(is_wav(&wav));
        assert!(!is_wav(b"RIFF\0\0\0\0WAVE"));
        assert!(!is_wav(&[0u8; 100]));
    }

    #[test]
    fn audios_tem_limite() {
        let v = Voice::default();
        for i in 0..40 {
            v.put(format!("v{i}"), vec![0; 10], "b".into(), "mic");
        }
        assert!(v.get("v0").is_none());
        assert!(v.get("v39").is_some());
        assert_eq!(v.clips.lock().unwrap().len(), MAX_CLIPS);
    }
}
