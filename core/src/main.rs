mod config;
mod engine;
mod route;
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
    routing::{get, post},
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
    match app.engine.submit(&m.text, m.target, m.machine) {
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
    let store = store::Store::open(paths.state());
    tokio::spawn(store.clone().persist_loop());
    let engine = Engine::new(store.clone(), cfg, paths);
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
