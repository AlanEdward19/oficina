// A Faísca fora do Mac: o pet e a conversa, em páginas que o app de desktop
// (Windows e Linux) abre em janelas nativas. Dois jeitos de existir:
//   casa  — este computador tem o core e a mente dela;
//   corpo — a mente está em outro computador (o Mac) e este é um corpo dela.
// O app injeta window.OFICINA = {mode, token, home}.
"use strict";

const C = window.OFICINA || { mode: "casa", token: "" };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const ipc = m => window.ipc && window.ipc.postMessage(m);
const $ = id => document.getElementById(id);

async function api(path, json, method) {
  const headers = { Authorization: "Bearer " + C.token };
  if (json !== undefined) headers["Content-Type"] = "application/json";
  return fetch(path, { method: method || (json !== undefined ? "POST" : "GET"), headers, body: json !== undefined ? JSON.stringify(json) : undefined });
}

async function get(path) {
  const r = await api(path);
  if (!r.ok) throw new Error(await r.text());
  const t = await r.text();
  return t ? JSON.parse(t) : null;
}

/// Fala em voz alta com a voz do sistema (no Windows, as vozes em português do Windows).
function speak(text) {
  if (!("speechSynthesis" in window) || !text) return;
  const u = new SpeechSynthesisUtterance(text.replace(/[*_#`>]/g, ""));
  u.lang = "pt-BR";
  const v = speechSynthesis.getVoices().find(v => v.lang && v.lang.toLowerCase().startsWith("pt"));
  if (v) u.voice = v;
  speechSynthesis.speak(u);
}

/// Eventos do core (SSE com token, por fetch).
async function events(onEvent) {
  for (;;) {
    try {
      const r = await api("/v1/events");
      const reader = r.body.getReader();
      const dec = new TextDecoder();
      let buf = "";
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        let i;
        while ((i = buf.indexOf("\n\n")) >= 0) {
          const block = buf.slice(0, i);
          buf = buf.slice(i + 2);
          const data = block.split("\n").filter(l => l.startsWith("data:")).map(l => l.slice(5).trim()).join("\n");
          if (data) { try { onEvent(JSON.parse(data)); } catch (_) {} }
        }
      }
    } catch (_) {}
    await sleep(2000);
  }
}

async function applyLook() {
  if (C.mode !== "casa") return;
  try {
    const s = await get("/v1/settings");
    document.documentElement.style.setProperty("--tint", s.body_color);
    document.documentElement.style.setProperty("--spark", s.spark_color);
    if ($("name")) $("name").textContent = s.name;
    document.title = s.name;
  } catch (_) {}
}

// MARK: Pet

const Pet = {
  hideTimer: null,

  show(on) {
    $("faisca").classList.toggle("gone", !on);
    ipc(on ? "show" : "hide");
  },

  say(text, actions) {
    const b = $("balloon");
    $("say").textContent = text;
    const a = $("actions");
    a.innerHTML = "";
    for (const [label, fn, solid] of actions || []) {
      const btn = document.createElement("button");
      btn.textContent = label;
      if (solid) btn.className = "solid";
      btn.onclick = () => { b.classList.remove("on"); fn(); };
      a.appendChild(btn);
    }
    b.classList.add("on");
    clearTimeout(this.hideTimer);
    if (!actions || !actions.length) this.hideTimer = setTimeout(() => b.classList.remove("on"), 7000);
  },

  mood(m, sleeping) {
    const f = $("faisca");
    f.classList.toggle("sleeping", !!sleeping);
    const mouth = $("mouth");
    const shapes = { feliz: "M40 86 Q48 95 56 86", cansada: "M42 90 L54 90", carente: "M41 91 Q48 86 55 91", entediada: "M42 90 L54 89" };
    mouth.setAttribute("d", shapes[m] || "M41 88 Q48 93 55 88");
  },

  wire() {
    const f = $("faisca");
    let down = null;
    f.addEventListener("mousedown", e => { down = { x: e.screenX, y: e.screenY }; });
    f.addEventListener("mousemove", e => {
      if (down && (Math.abs(e.screenX - down.x) > 3 || Math.abs(e.screenY - down.y) > 3)) { down = null; ipc("drag"); }
    });
    f.addEventListener("mouseup", () => { if (down) ipc("chat"); down = null; });
  },
};

async function petCasa() {
  let last = null;
  const brief = b => {
    if (!b) return;
    Pet.mood(b.mood, b.sleeping);
    if (b.thought && (!last || !last.thought || b.thought.at !== last.thought.at) && last) Pet.say(b.thought.text);
    const i = b.initiative;
    if (i && (!last || !last.initiative || last.initiative.id !== i.id)) {
      const answer = async ok => {
        const r = await api(`/v1/mind/initiatives/${i.id}/${ok ? "accept" : "decline"}`, {});
        if (ok && r.ok && i.action.type === "chat") ipc("chat");
      };
      const acts = [[i.accept, () => answer(true), true], [i.decline, () => answer(false)]];
      if (i.never) acts.push([i.never, () => api(`/v1/mind/initiatives/${i.id}/never`, {})]);
      Pet.say(i.text, acts);
    }
    last = b;
  };
  try { brief(await get("/v1/mind")); } catch (_) {}
  try { const p = await get("/v1/presence"); Pet.show(p.holder === "casa"); } catch (_) { Pet.show(true); }
  events(ev => {
    if (ev.kind === "mind") brief(ev.mind);
    if (ev.kind === "presence") Pet.show(ev.presence.holder === "casa");
  });
}

/// Corpo: este computador recebe a Faísca quando ela vem para cá.
async function petCorpo() {
  Pet.show(false);
  for (;;) {
    let r;
    try { r = await api("/v1/body/next?wait=20"); } catch (_) { await sleep(3000); continue; }
    if (r.status === 401) { ipc("forgotten"); await sleep(10000); continue; }
    if (!r.ok) { await sleep(3000); continue; }
    const res = await r.json();
    Pet.show(res.here);
    for (const c of res.commands || []) {
      ipc("relay:" + JSON.stringify(c));
      if (c.kind === "arrive") Pet.say("Cheguei!");
      if (c.kind === "say") { Pet.say(c.text); speak(c.text); }
      if (c.kind === "listen") ipc("listen");
    }
  }
}

// MARK: Conversa

const Chat = {
  add(kind, text, id) {
    let el = id && document.querySelector(`[data-id="${id}"]`);
    if (!el) {
      el = document.createElement("div");
      el.className = "msg " + kind;
      if (id) el.dataset.id = id;
      $("thread").appendChild(el);
    }
    el.textContent = text;
    $("thread").scrollTop = $("thread").scrollHeight;
  },
};

async function chatCasa() {
  let conv = localStorage.getItem("conversa") || null;
  const render = t => {
    if (conv && t.conversation !== conv) return;
    if (t.text) Chat.add("me", t.text, t.id + "u");
    const out = t.error || t.output || (t.status === "awaiting_approval" ? "Precisa da sua aprovação no Mac." : "…");
    Chat.add("her", out, t.id);
  };
  try { for (const t of await get("/v1/tasks")) render(t); } catch (_) {}
  const where = p => { $("where").textContent = p.holder === "casa" ? "neste computador" : "na " + p.room; };
  try { where(await get("/v1/presence")); } catch (_) {}
  events(ev => {
    if (ev.kind === "task") render(ev.task);
    if (ev.kind === "delta") { const el = document.querySelector(`[data-id="${ev.id}"]`); if (el) el.textContent = (el.textContent === "…" ? "" : el.textContent) + ev.text; }
    if (ev.kind === "presence") where(ev.presence);
  });
  const send = async text => {
    const r = await api("/v1/messages", { text, conversation: conv });
    if (!r.ok) { Chat.add("note", "Não consegui enviar."); return; }
    const t = await r.json();
    conv = t.conversation;
    localStorage.setItem("conversa", conv);
    render(t);
  };
  return send;
}

async function chatCorpo() {
  $("where").textContent = "com a Faísca do " + (C.home || "Mac");
  window.Oficina.receive = c => {
    if (c.kind === "say") Chat.add("her", c.text);
    if (c.kind === "arrive") Chat.add("note", "Ela chegou aqui.");
    if (c.kind === "leave") Chat.add("note", "Ela voltou para o " + (C.home || "Mac") + ".");
  };
  return async text => {
    for (let attempt = 0; attempt < 4; attempt++) {
      const r = await api("/v1/body/heard", { text });
      if (r.ok) return;
      if (r.status !== 409) break;
      // Ela está em outro lugar: chama para cá e tenta de novo.
      if (attempt === 0) {
        const c = await (await api("/v1/body/call", {})).json().catch(() => ({}));
        Chat.add("note", c.result === "ocupada" ? "Ela está ocupada com alguém no " + (C.home || "Mac") + ". Já avisei." : "Chamando a Faísca…");
        if (c.result === "ocupada") return;
      }
      await sleep(1500);
    }
    Chat.add("note", "Ela não veio. Tente de novo daqui a pouco.");
  };
}

window.Oficina = {
  async pet() {
    Pet.wire();
    await applyLook();
    if (C.mode === "corpo") petCorpo(); else petCasa();
  },

  async chat() {
    await applyLook();
    const send = C.mode === "corpo" ? await chatCorpo() : await chatCasa();
    const input = $("input");
    const go = () => {
      const text = input.value.trim();
      if (!text) return;
      input.value = "";
      Chat.add("me", text);
      send(text);
    };
    $("send").onclick = go;
    input.addEventListener("keydown", e => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); go(); } });
    input.focus();
  },

  /// O app chama isto para trazer comandos que o pet recebeu.
  receive(_) {},
  focus() { $("input") && $("input").focus(); },
};
