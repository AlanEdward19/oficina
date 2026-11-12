mod clean;
mod body;
mod config;
mod conv;
mod engine;
mod factory;
mod hardware;
mod meeting;
mod mind;
mod peer;
mod presence;
mod route;
mod router;
mod store;
mod usage;

use axum::{
    Json, Router,
    extract::{Path, Request, State},
    http::{StatusCode, header},
    middleware::{self, Next},
    response::{
        IntoResponse, Response,
        sse::{Event, KeepAlive, Sse},
    },
    routing::{delete, get, post},
};
use engine::Engine;
use futures_util::stream::{self, Stream};
use serde::Deserialize;
use std::{convert::Infallible, sync::Arc};
use store::Target;
use tokio::{
    signal::unix::{SignalKind, signal},
    sync::broadcast::error::RecvError,
};

#[derive(Clone)]
struct App {
    engine: Arc<Engine>,
    token: Arc<str>,
    /// A porta dos dispositivos, quando ligada.
    bodies: Arc<std::sync::Mutex<Option<tokio::task::JoinHandle<()>>>>,
}

#[derive(Deserialize)]
struct Message {
    text: String,
    #[serde(default = "auto")]
    target: Target,
    machine: Option<String>,
    conversation: Option<String>,
}

fn auto() -> Target {
    Target::Auto
}

/// Para os outros módulos: mesma comparação em tempo constante.
pub(crate) fn token_eq(given: &str, expected: &str) -> bool {
    token_matches(given, expected)
}

/// Compara sem encerrar no primeiro byte diferente.
fn token_matches(given: &str, expected: &str) -> bool {
    given.len() == expected.len()
        && given
            .bytes()
            .zip(expected.bytes())
            .fold(0u8, |acc, (a, b)| acc | (a ^ b))
            == 0
}

async fn auth(State(app): State<App>, req: Request, next: Next) -> Response {
    let ok = req
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .is_some_and(|t| token_matches(t, &app.token));
    if ok {
        next.run(req).await
    } else {
        StatusCode::UNAUTHORIZED.into_response()
    }
}

async fn health(State(app): State<App>) -> impl IntoResponse {
    Json(serde_json::json!({
        "ok": true,
        "name": app.engine.name,
        "version": env!("CARGO_PKG_VERSION"),
    }))
}

async fn machines(State(app): State<App>) -> impl IntoResponse {
    Json(app.engine.machines().await)
}

async fn create(State(app): State<App>, Json(m): Json<Message>) -> Response {
    match app.engine.submit(&m.text, m.target, m.machine, m.conversation) {
        Ok(task) => (StatusCode::CREATED, Json(task)).into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, e).into_response(),
    }
}

async fn tasks(State(app): State<App>) -> impl IntoResponse {
    Json(app.engine.store.list())
}

fn found(task: Option<store::Task>) -> Response {
    match task {
        Some(t) => Json(t).into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

async fn task(State(app): State<App>, Path(id): Path<String>) -> Response {
    found(app.engine.store.get(&id))
}

async fn approve(State(app): State<App>, Path(id): Path<String>) -> Response {
    match app.engine.approve(&id) {
        Some(t) => Json(t).into_response(),
        None => StatusCode::CONFLICT.into_response(),
    }
}

async fn cancel(State(app): State<App>, Path(id): Path<String>) -> Response {
    found(app.engine.cancel(&id))
}

async fn usage(State(app): State<App>) -> impl IntoResponse {
    Json(app.engine.usage(false))
}

async fn usage_refresh(State(app): State<App>) -> impl IntoResponse {
    Json(app.engine.usage(true))
}

async fn mind(State(app): State<App>) -> impl IntoResponse {
    Json(app.engine.mind.snapshot())
}

async fn mind_events(State(app): State<App>, Json(events): Json<Vec<mind::MindEvent>>) -> StatusCode {
    app.engine.mind.events(events);
    StatusCode::NO_CONTENT
}

async fn mind_suggest(State(app): State<App>) -> Response {
    match app.engine.mind.suggest() {
        Some(i) => Json(i).into_response(),
        None => StatusCode::NO_CONTENT.into_response(),
    }
}

async fn initiative_accept(State(app): State<App>, Path(id): Path<String>) -> Response {
    match app.engine.accept_initiative(&id) {
        Some(i) => Json(i).into_response(),
        None => StatusCode::CONFLICT.into_response(),
    }
}

async fn initiative_decline(State(app): State<App>, Path(id): Path<String>) -> StatusCode {
    if app.engine.mind.decline(&id) { StatusCode::NO_CONTENT } else { StatusCode::CONFLICT }
}

async fn initiative_never(State(app): State<App>, Path(id): Path<String>) -> StatusCode {
    if app.engine.mind.never(&id) { StatusCode::NO_CONTENT } else { StatusCode::CONFLICT }
}

async fn mind_forget(State(app): State<App>) -> StatusCode {
    app.engine.mind.forget();
    app.engine.meetings.forget();
    StatusCode::NO_CONTENT
}

// MARK: Reuniões

async fn meetings(State(app): State<App>) -> impl IntoResponse {
    Json(app.engine.meetings.list())
}

#[derive(Deserialize)]
struct NewMeeting {
    app: String,
    #[serde(default)]
    title: String,
}

async fn meeting_create(State(app): State<App>, Json(m): Json<NewMeeting>) -> Response {
    (StatusCode::CREATED, Json(app.engine.meetings.start(&m.app, &m.title, usage::now()))).into_response()
}

async fn meeting_get(State(app): State<App>, Path(id): Path<String>) -> Response {
    match app.engine.meetings.get(&id) {
        Some(m) => Json(m).into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

async fn meeting_delete(State(app): State<App>, Path(id): Path<String>) -> StatusCode {
    if app.engine.meetings.delete(&id) { StatusCode::NO_CONTENT } else { StatusCode::NOT_FOUND }
}

async fn meeting_segments(State(app): State<App>, Path(id): Path<String>, Json(s): Json<Vec<meeting::Segment>>) -> StatusCode {
    if app.engine.meetings.append(&id, s) { StatusCode::NO_CONTENT } else { StatusCode::CONFLICT }
}

async fn meeting_end(State(app): State<App>, Path(id): Path<String>) -> StatusCode {
    if app.engine.end_meeting(&id) { StatusCode::NO_CONTENT } else { StatusCode::NOT_FOUND }
}

async fn meeting_summarize(State(app): State<App>, Path(id): Path<String>) -> Response {
    match app.engine.summarize_meeting(&id) {
        Ok(task) => (StatusCode::CREATED, Json(task)).into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, e).into_response(),
    }
}

// MARK: Oficina de hardware

async fn hardware_list(State(app): State<App>) -> impl IntoResponse {
    Json(app.engine.hardware_overview())
}

#[derive(Deserialize)]
struct NewHardware {
    name: String,
    idea: String,
}

async fn hardware_create(State(app): State<App>, Json(h): Json<NewHardware>) -> Response {
    match app.engine.create_hardware(&h.name, &h.idea) {
        Ok(v) => (StatusCode::CREATED, Json(v)).into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, e).into_response(),
    }
}

async fn hardware_get(State(app): State<App>, Path(id): Path<String>) -> Response {
    match app.engine.hardware.get(&id) {
        Some(p) => Json(app.engine.hardware_view(p)).into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

async fn hardware_diagram(State(app): State<App>, Path(id): Path<String>) -> Response {
    let Some(p) = app.engine.hardware.get(&id) else { return StatusCode::NOT_FOUND.into_response() };
    match hardware::diagram_of(&app.engine.hardware.root.join(&p.id)) {
        Some(d) => Json(d).into_response(),
        None => StatusCode::NO_CONTENT.into_response(),
    }
}

async fn hardware_delete(State(app): State<App>, Path(id): Path<String>) -> StatusCode {
    if app.engine.delete_hardware(&id) { StatusCode::NO_CONTENT } else { StatusCode::NOT_FOUND }
}

/// Instala o ambiente de CAD em segundo plano (ocupa disco, não tokens).
async fn hardware_setup(State(app): State<App>) -> StatusCode {
    if app.engine.hardware.setup_state() == "instalando" {
        return StatusCode::CONFLICT;
    }
    let engine = app.engine.clone();
    tokio::task::spawn_blocking(move || engine.hardware.setup());
    StatusCode::ACCEPTED
}

/// Roda as simulações ou o modelo agora, sem agente e sem tokens.
async fn hardware_run(State(app): State<App>, Path((id, what)): Path<(String, String)>) -> Response {
    let Some(p) = app.engine.hardware.get(&id) else { return StatusCode::NOT_FOUND.into_response() };
    let root = app.engine.hardware.root.clone();
    let dir = root.join(&p.id);
    let result = tokio::task::spawn_blocking(move || match what.as_str() {
        "sim" => hardware::simulate(&dir).map(|(_, md)| md),
        "build" => hardware::build(&root, &dir),
        "erc" => hardware::erc(&root, &dir),
        "firmware" => hardware::firmware(&root, &dir),
        _ => Err("ação desconhecida".into()),
    })
    .await
    .unwrap_or_else(|e| Err(e.to_string()));
    match result {
        Ok(text) => Json(serde_json::json!({"ok": true, "output": text})).into_response(),
        Err(e) => Json(serde_json::json!({"ok": false, "output": e})).into_response(),
    }
}

#[derive(Deserialize)]
struct RequestBody {
    kind: String,
    text: String,
    #[serde(default)]
    agent: bool,
}

async fn create_request(State(app): State<App>, Json(r): Json<RequestBody>) -> Response {
    match app.engine.request(&r.kind, &r.text, r.agent) {
        Ok(task) => (StatusCode::CREATED, Json(task)).into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, e).into_response(),
    }
}

#[derive(Deserialize)]
struct DecorWish {
    suggestion: Option<String>,
}

async fn mind_decor(State(app): State<App>, Json(w): Json<DecorWish>) -> Response {
    let wish = w.suggestion.map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
    let theme = app.engine.mind.decor_theme();
    (StatusCode::CREATED, Json(app.engine.create_decor(&theme, wish))).into_response()
}

async fn mind_decor_use(State(app): State<App>, Json(w): Json<Wear>) -> StatusCode {
    if app.engine.mind.use_decor(w.id.as_deref()) { StatusCode::NO_CONTENT } else { StatusCode::NOT_FOUND }
}

#[derive(Deserialize)]
struct Wear {
    id: Option<String>,
}

async fn mind_wear(State(app): State<App>, Json(w): Json<Wear>) -> StatusCode {
    if app.engine.mind.wear(w.id.as_deref()) { StatusCode::NO_CONTENT } else { StatusCode::NOT_FOUND }
}

async fn conversations(State(app): State<App>) -> impl IntoResponse {
    Json(app.engine.convs.list())
}

#[derive(Deserialize)]
struct NewConversation {
    title: Option<String>,
}

async fn conversation_create(State(app): State<App>, Json(n): Json<NewConversation>) -> Response {
    (StatusCode::CREATED, Json(app.engine.convs.create(n.title.as_deref(), None))).into_response()
}

async fn conversation(State(app): State<App>, Path(id): Path<String>) -> Response {
    match app.engine.convs.get(&id) {
        Some(c) if conv::valid_id(&id) => {
            Json(serde_json::json!({ "conversation": c, "tasks": app.engine.store.history(&id) })).into_response()
        }
        _ => StatusCode::NOT_FOUND.into_response(),
    }
}

#[derive(Deserialize)]
struct Rename {
    title: String,
}

async fn conversation_rename(State(app): State<App>, Path(id): Path<String>, Json(r): Json<Rename>) -> StatusCode {
    if app.engine.convs.rename(&id, &r.title) { StatusCode::NO_CONTENT } else { StatusCode::NOT_FOUND }
}

async fn conversation_delete(State(app): State<App>, Path(id): Path<String>) -> StatusCode {
    if !conv::valid_id(&id) || !app.engine.convs.delete(&id) {
        return StatusCode::NOT_FOUND;
    }
    app.engine.store.forget_conversation(&id);
    StatusCode::NO_CONTENT
}

async fn settings_get(State(app): State<App>) -> impl IntoResponse {
    Json(app.engine.factory.settings())
}

async fn settings_set(State(app): State<App>, Json(s): Json<factory::Settings>) -> impl IntoResponse {
    Json(app.engine.factory.set_settings(s))
}

// MARK: Limpeza. O trabalho de disco roda fora da fila principal.

#[derive(serde::Deserialize)]
struct CleanScan {
    mode: clean::Mode,
    app: Option<String>,
}

#[derive(serde::Deserialize)]
struct CleanRun {
    mode: clean::Mode,
    ids: Vec<u32>,
}

#[derive(serde::Deserialize)]
struct CleanMap {
    path: Option<String>,
}

async fn on_disk<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> Option<T> {
    tokio::task::spawn_blocking(f).await.ok()
}

async fn clean_scan(State(app): State<App>, Json(q): Json<CleanScan>) -> Response {
    let e = app.engine.clone();
    match on_disk(move || e.clean.scan(q.mode, q.app.as_deref())).await {
        Some(Ok(scan)) => Json(scan).into_response(),
        Some(Err(m)) => (StatusCode::BAD_REQUEST, m).into_response(),
        None => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

async fn clean_run(State(app): State<App>, Json(q): Json<CleanRun>) -> Response {
    let e = app.engine.clone();
    match on_disk(move || e.clean.run(q.mode, &q.ids)).await {
        Some(out) => Json(out).into_response(),
        None => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

async fn clean_apps(State(app): State<App>) -> Response {
    let e = app.engine.clone();
    on_disk(move || e.clean.apps()).await.map_or(StatusCode::INTERNAL_SERVER_ERROR.into_response(), |v| Json(v).into_response())
}

async fn clean_startup(State(app): State<App>) -> Response {
    let e = app.engine.clone();
    on_disk(move || e.clean.startup()).await.map_or(StatusCode::INTERNAL_SERVER_ERROR.into_response(), |v| Json(v).into_response())
}

async fn clean_trash(State(app): State<App>) -> Response {
    let e = app.engine.clone();
    let bytes = on_disk(move || e.clean.trash_bytes()).await.flatten();
    Json(serde_json::json!({ "bytes": bytes })).into_response()
}

async fn clean_map(State(app): State<App>, Json(q): Json<CleanMap>) -> Response {
    let e = app.engine.clone();
    match on_disk(move || e.clean.map(q.path.as_deref())).await {
        Some(Ok(v)) => Json(v).into_response(),
        Some(Err(m)) => (StatusCode::BAD_REQUEST, m).into_response(),
        None => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

/// Tudo o que o painel da fábrica mostra.
async fn factory_state(State(app): State<App>) -> impl IntoResponse {
    let e = &app.engine;
    let agents: Vec<serde_json::Value> = e.factory.agents().iter().map(|a| {
        let mut v = serde_json::to_value(a).unwrap_or_default();
        v["status"] = e.agent_status(a).into();
        v
    }).collect();
    Json(serde_json::json!({ "agents": agents, "teams": e.factory.teams(), "router": e.router.stats() }))
}

async fn agent_create(State(app): State<App>, Json(s): Json<factory::AgentSpec>) -> Response {
    match app.engine.create_agent(s) {
        Ok(a) => (StatusCode::CREATED, Json(a)).into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, e).into_response(),
    }
}

async fn agent_delete(State(app): State<App>, Path(id): Path<String>) -> StatusCode {
    if app.engine.delete_agent(&id) { StatusCode::NO_CONTENT } else { StatusCode::NOT_FOUND }
}

#[derive(Deserialize)]
struct MissionBody {
    goal: String,
}

async fn mission_start(State(app): State<App>, Path(id): Path<String>, Json(m): Json<MissionBody>) -> Response {
    match app.engine.start_mission(&id, &m.goal) {
        Ok(a) => Json(a).into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, e).into_response(),
    }
}

#[derive(Deserialize)]
struct TeamBody {
    name: String,
    #[serde(default)]
    members: Vec<String>,
}

async fn team_create(State(app): State<App>, Json(t): Json<TeamBody>) -> Response {
    match app.engine.create_team(&t.name, &t.members) {
        Ok(team) => (StatusCode::CREATED, Json(team)).into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, e).into_response(),
    }
}

async fn team_delete(State(app): State<App>, Path(id): Path<String>) -> StatusCode {
    if app.engine.delete_team(&id) { StatusCode::NO_CONTENT } else { StatusCode::NOT_FOUND }
}

#[derive(Deserialize)]
struct Member {
    team: Option<String>,
}

async fn agent_team(State(app): State<App>, Path(id): Path<String>, Json(m): Json<Member>) -> StatusCode {
    if app.engine.set_member(&id, m.team) { StatusCode::NO_CONTENT } else { StatusCode::NOT_FOUND }
}

async fn brain_reset(State(app): State<App>) -> StatusCode {
    app.engine.reset_brain().await;
    StatusCode::NO_CONTENT
}

// MARK: Presença (as suas rotas)

async fn presence_get(State(app): State<App>) -> impl IntoResponse {
    Json(app.engine.presence_view())
}

#[derive(Deserialize)]
struct MoveBody {
    to: String,
    #[serde(default)]
    text: String,
}

async fn presence_move(State(app): State<App>, Json(m): Json<MoveBody>) -> Response {
    match app.engine.go(&m.to, &m.text) {
        Ok(_) => Json(app.engine.presence_view()).into_response(),
        Err(e) if m.to == presence::HOME => { let _ = e; Json(app.engine.presence_view()).into_response() }
        Err(e) => (StatusCode::BAD_REQUEST, e).into_response(),
    }
}

#[derive(Deserialize)]
struct CallBody {
    #[serde(default)]
    force: bool,
}

async fn presence_call(State(app): State<App>, Json(c): Json<CallBody>) -> impl IntoResponse {
    Json(app.engine.owner_call(c.force))
}

/// Liga ou desliga a porta dos dispositivos na rede.
fn set_body_network(app: &App, on: bool) -> Result<(), String> {
    let mut slot = app.bodies.lock().unwrap();
    if let Some(h) = slot.take() {
        h.abort();
    }
    app.engine.presence.set_network(on);
    if on {
        let addr = app.engine.cfg.body_listen.clone();
        let std_listener = std::net::TcpListener::bind(&addr).map_err(|e| format!("não consegui abrir {addr}: {e}"))?;
        std_listener.set_nonblocking(true).map_err(|e| e.to_string())?;
        let listener = tokio::net::TcpListener::from_std(std_listener).map_err(|e| e.to_string())?;
        let router = body_router(app.engine.clone());
        *slot = Some(tokio::spawn(async move {
            let _ = axum::serve(listener, router).await;
        }));
        eprintln!("oficinad: dispositivos em {addr}");
    }
    app.engine.publish_presence();
    Ok(())
}

#[derive(Deserialize)]
struct NetworkBody {
    on: bool,
}

async fn bodies_network(State(app): State<App>, Json(n): Json<NetworkBody>) -> Response {
    match set_body_network(&app, n.on) {
        Ok(()) => Json(app.engine.presence_view()).into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, e).into_response(),
    }
}

/// Um código para parear uma caixa de som. Liga a porta dos dispositivos.
async fn bodies_pairing(State(app): State<App>) -> Response {
    if !app.engine.presence.network() || app.bodies.lock().unwrap().is_none() {
        if let Err(e) = set_body_network(&app, true) {
            return (StatusCode::BAD_REQUEST, e).into_response();
        }
    }
    let code = app.engine.presence.start_pairing(usage::now());
    app.engine.publish_presence();
    Json(serde_json::json!({"code": code, "port": app.engine.cfg.body_listen})).into_response()
}

async fn bodies_forget(State(app): State<App>, Path(id): Path<String>) -> StatusCode {
    match app.engine.presence.forget(&id) {
        Some(b) => {
            app.engine.convs.delete(&b.conversation);
            app.engine.publish_presence();
            StatusCode::NO_CONTENT
        }
        None => StatusCode::NOT_FOUND,
    }
}

async fn voice_get(State(app): State<App>, Path(id): Path<String>) -> Response {
    match app.engine.voice_clip(&id) {
        Some(bytes) => ([(header::CONTENT_TYPE, "audio/wav")], bytes).into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

async fn voice_put(State(app): State<App>, Path(id): Path<String>, bytes: axum::body::Bytes) -> StatusCode {
    if app.engine.voice_rendered(&id, bytes.to_vec()) { StatusCode::NO_CONTENT } else { StatusCode::BAD_REQUEST }
}

#[derive(Deserialize)]
struct VoiceText {
    text: String,
}

async fn voice_text(State(app): State<App>, Path(id): Path<String>, Json(t): Json<VoiceText>) -> Response {
    match app.engine.voice_text(&id, &t.text) {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => (StatusCode::CONFLICT, e).into_response(),
    }
}

// MARK: Presença (as rotas dos dispositivos, na porta deles)

#[derive(Clone)]
struct BodyApp {
    engine: Arc<Engine>,
}

/// Só tokens de dispositivo entram; cada pedido conta como sinal de vida.
async fn body_auth(State(app): State<BodyApp>, mut req: Request, next: Next) -> Response {
    let token = req.headers().get(header::AUTHORIZATION).and_then(|h| h.to_str().ok()).and_then(|h| h.strip_prefix("Bearer "));
    match token.and_then(|t| app.engine.presence.auth(t)) {
        Some(b) => {
            app.engine.presence.heartbeat(&b.id, usage::now());
            req.extensions_mut().insert(b);
            next.run(req).await
        }
        None => StatusCode::UNAUTHORIZED.into_response(),
    }
}

#[derive(Deserialize)]
struct PairBody {
    code: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    room: String,
    #[serde(default)]
    kind: String,
}

async fn body_pair(State(app): State<BodyApp>, Json(p): Json<PairBody>) -> Response {
    let conv = app.engine.convs.create(Some(&format!("Voz · {}", if p.room.trim().is_empty() { "sala" } else { p.room.trim() })), None);
    match app.engine.presence.pair(&p.code, &p.name, &p.room, &p.kind, conv.id.clone(), usage::now()) {
        Ok(b) => {
            app.engine.publish_presence();
            Json(serde_json::json!({"id": b.id, "token": b.token, "name": b.name, "room": b.room})).into_response()
        }
        Err(e) => {
            app.engine.convs.delete(&conv.id);
            (StatusCode::FORBIDDEN, e).into_response()
        }
    }
}

async fn body_heartbeat(State(app): State<BodyApp>) -> impl IntoResponse {
    let v = app.engine.presence_view();
    Json(serde_json::json!({"holder": v.holder}))
}

/// Espera até 25 s por comandos: é assim que a caixa recebe o que fazer.
async fn body_next(
    State(app): State<BodyApp>,
    axum::Extension(b): axum::Extension<presence::Body>,
    uri: axum::http::Uri,
) -> impl IntoResponse {
    // `?wait=20` sem puxar o extrator de query só por isso.
    let wait = uri.query().unwrap_or("").split('&').find_map(|kv| kv.strip_prefix("wait=")).and_then(|v| v.parse::<u64>().ok());
    let until = tokio::time::Instant::now() + std::time::Duration::from_secs(wait.unwrap_or(20).min(25));
    loop {
        let notified = app.engine.presence.notify.notified();
        tokio::pin!(notified);
        notified.as_mut().enable();
        let commands = app.engine.presence.take(&b.id);
        let here = app.engine.presence.holder() == b.id;
        if !commands.is_empty() || tokio::time::Instant::now() >= until {
            return Json(serde_json::json!({"commands": commands, "here": here}));
        }
        tokio::select! {
            _ = notified => {}
            _ = tokio::time::sleep_until(until) => {}
        }
    }
}

#[derive(Deserialize)]
struct Heard {
    text: String,
}

async fn body_heard(State(app): State<BodyApp>, axum::Extension(b): axum::Extension<presence::Body>, Json(h): Json<Heard>) -> Response {
    match app.engine.heard(&b, &h.text) {
        Ok(_) => StatusCode::ACCEPTED.into_response(),
        Err(e) => (StatusCode::CONFLICT, e).into_response(),
    }
}

async fn body_audio_in(State(app): State<BodyApp>, axum::Extension(b): axum::Extension<presence::Body>, bytes: axum::body::Bytes) -> Response {
    match app.engine.body_audio(&b, bytes.to_vec()) {
        Ok(id) => (StatusCode::ACCEPTED, Json(serde_json::json!({"id": id}))).into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, e).into_response(),
    }
}

async fn body_audio_out(State(app): State<BodyApp>, Path(id): Path<String>) -> Response {
    match app.engine.voice_clip(&id) {
        Some(bytes) => ([(header::CONTENT_TYPE, "audio/wav")], bytes).into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

async fn body_call(State(app): State<BodyApp>, axum::Extension(b): axum::Extension<presence::Body>) -> impl IntoResponse {
    Json(serde_json::json!({"result": app.engine.body_call(&b)}))
}

fn body_router(engine: Arc<Engine>) -> Router {
    let app = BodyApp { engine };
    let private = Router::new()
        .route("/v1/body/heartbeat", post(body_heartbeat))
        .route("/v1/body/next", get(body_next))
        .route("/v1/body/heard", post(body_heard))
        .route("/v1/body/audio", post(body_audio_in))
        .route("/v1/body/audio/{id}", get(body_audio_out))
        .route("/v1/body/call", post(body_call))
        .route_layer(middleware::from_fn_with_state(app.clone(), body_auth));
    Router::new()
        .route("/v1/body/pair", post(body_pair))
        .merge(private)
        .layer(axum::extract::DefaultBodyLimit::max(body::MAX_AUDIO + 1024))
        .with_state(app)
}

async fn events(
    State(app): State<App>,
) -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    let rx = app.engine.store.tx.subscribe();
    let s = stream::unfold(rx, |mut rx| async move {
        let data = match rx.recv().await {
            Ok(ev) => serde_json::to_string(&ev).ok()?,
            Err(RecvError::Lagged(_)) => r#"{"kind":"resync"}"#.to_string(),
            Err(RecvError::Closed) => return None,
        };
        Some((Ok(Event::default().data(data)), rx))
    });
    Sse::new(s).keep_alive(KeepAlive::default())
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let paths = config::Paths::resolve();
    // `oficinad hw …`: as ferramentas da Oficina de hardware, sem servidor.
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("hw") {
        std::process::exit(hardware::cli(&paths.home, &args[1..]));
    }
    let (cfg, token) = config::load(&paths).expect("não consegui carregar a configuração");
    let listen = cfg.listen.clone();
    let store = store::Store::open(paths.state(), paths.home.join("conversas"));
    tokio::spawn(store.clone().persist_loop());
    let engine = Engine::new(store.clone(), cfg, paths);
    let mind_ref = engine.mind.clone();
    let ticking = engine.mind.clone();
    tokio::spawn(async move {
        // 1 s acordada; 3 s dormindo ou com você longe. A rede avança pelo
        // tempo real, então o ritmo não muda o comportamento.
        loop {
            let pause = if ticking.calm() { 3000 } else { 1000 };
            tokio::time::sleep(std::time::Duration::from_millis(pause)).await;
            ticking.tick();
        }
    });
    // O que você está fazendo: projeto, git e PR, a cada 2 minutos.
    let watching = engine.clone();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        loop {
            watching.refresh_context().await;
            tokio::time::sleep(std::time::Duration::from_secs(120)).await;
        }
    });
    // A presença: falar as respostas nos corpos e voltar para casa na hora certa.
    let present = engine.clone();
    let started = usage::now();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            present.presence_tick(started).await;
        }
    });
    let app = App {
        engine,
        token: token.into(),
        bodies: Default::default(),
    };
    if app.engine.presence.network() {
        if let Err(e) = set_body_network(&app, true) {
            eprintln!("oficinad: {e}");
        }
    }

    let private = Router::new()
        .route("/v1/machines", get(machines))
        .route("/v1/messages", post(create))
        .route("/v1/tasks", get(tasks))
        .route("/v1/tasks/{id}", get(task))
        .route("/v1/tasks/{id}/approve", post(approve))
        .route("/v1/tasks/{id}/cancel", post(cancel))
        .route("/v1/events", get(events))
        .route("/v1/brain/reset", post(brain_reset))
        .route("/v1/settings", get(settings_get).post(settings_set))
        .route("/v1/factory", get(factory_state))
        .route("/v1/clean/scan", post(clean_scan))
        .route("/v1/clean/run", post(clean_run))
        .route("/v1/clean/apps", get(clean_apps))
        .route("/v1/clean/startup", get(clean_startup))
        .route("/v1/clean/trash", get(clean_trash))
        .route("/v1/clean/map", post(clean_map))
        .route("/v1/agents", post(agent_create))
        .route("/v1/agents/{id}", delete(agent_delete))
        .route("/v1/agents/{id}/missions", post(mission_start))
        .route("/v1/agents/{id}/team", post(agent_team))
        .route("/v1/teams", post(team_create))
        .route("/v1/teams/{id}", delete(team_delete))
        .route("/v1/conversations", get(conversations).post(conversation_create))
        .route("/v1/conversations/{id}", get(conversation).delete(conversation_delete))
        .route("/v1/conversations/{id}/rename", post(conversation_rename))
        .route("/v1/requests", post(create_request))
        .route("/v1/mind", get(mind))
        .route("/v1/mind/events", post(mind_events))
        .route("/v1/mind/suggest", post(mind_suggest))
        .route("/v1/mind/forget", post(mind_forget))
        .route("/v1/mind/outfit", post(mind_wear))
        .route("/v1/mind/decor", post(mind_decor))
        .route("/v1/mind/decor/use", post(mind_decor_use))
        .route("/v1/mind/initiatives/{id}/accept", post(initiative_accept))
        .route("/v1/mind/initiatives/{id}/decline", post(initiative_decline))
        .route("/v1/mind/initiatives/{id}/never", post(initiative_never))
        .route("/v1/meetings", get(meetings).post(meeting_create))
        .route("/v1/meetings/{id}", get(meeting_get).delete(meeting_delete))
        .route("/v1/meetings/{id}/segments", post(meeting_segments))
        .route("/v1/meetings/{id}/end", post(meeting_end))
        .route("/v1/meetings/{id}/summarize", post(meeting_summarize))
        .route("/v1/hardware", get(hardware_list).post(hardware_create))
        .route("/v1/hardware/setup", post(hardware_setup))
        .route("/v1/hardware/{id}", get(hardware_get).delete(hardware_delete))
        .route("/v1/hardware/{id}/run/{what}", post(hardware_run))
        .route("/v1/hardware/{id}/diagram", get(hardware_diagram))
        .route("/v1/presence", get(presence_get))
        .route("/v1/presence/move", post(presence_move))
        .route("/v1/presence/call", post(presence_call))
        .route("/v1/bodies/pairing", post(bodies_pairing))
        .route("/v1/bodies/network", post(bodies_network))
        .route("/v1/bodies/{id}", delete(bodies_forget))
        .route("/v1/voice/{id}", get(voice_get).post(voice_put))
        .route("/v1/voice/{id}/text", post(voice_text))
        .route("/v1/usage", get(usage))
        .route("/v1/usage/refresh", post(usage_refresh))
        .route_layer(middleware::from_fn_with_state(app.clone(), auth));
    let router = Router::new()
        .route("/v1/health", get(health))
        .merge(private)
        .with_state(app);

    let listener = tokio::net::TcpListener::bind(&listen)
        .await
        .unwrap_or_else(|e| panic!("não consegui abrir {listen}: {e}"));
    eprintln!("oficinad ouvindo em {listen}");

    let mut term = signal(SignalKind::terminate()).expect("sinal");
    let mut int = signal(SignalKind::interrupt()).expect("sinal");
    tokio::select! {
        r = axum::serve(listener, router).into_future() => {
            if let Err(e) = r { eprintln!("oficinad: {e}"); }
        }
        _ = term.recv() => {}
        _ = int.recv() => {}
    }
    let _ = store.flush();
    mind_ref.flush();
}

#[cfg(test)]
mod tests {
    use super::token_matches;

    #[test]
    fn token_exato() {
        assert!(token_matches("abc", "abc"));
        assert!(!token_matches("abd", "abc"));
        assert!(!token_matches("ab", "abc"));
    }
}
