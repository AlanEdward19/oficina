mod clean;
mod config;
mod conv;
mod engine;
mod factory;
mod mind;
mod peer;
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

async fn mind_forget(State(app): State<App>) -> StatusCode {
    app.engine.mind.forget();
    StatusCode::NO_CONTENT
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
    let app = App {
        engine,
        token: token.into(),
    };

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
