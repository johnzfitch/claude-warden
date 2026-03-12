use axum::{
    extract::State,
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::sync::{Notify, RwLock};

use crate::{config, db, observability, router, security, types};

pub struct AppState {
    pub config: config::Config,
    pub db: db::Database,
    pub validator: security::bash_validator::BashValidator,
    pub events_path: PathBuf,
    pub last_request: RwLock<std::time::Instant>,
    pub shutdown_notify: Notify,
    pub active_sessions: RwLock<u32>,
    pub request_count: AtomicU64,
}

impl AppState {
    pub fn new(
        config: config::Config,
        db: db::Database,
        validator: security::bash_validator::BashValidator,
        events_path: PathBuf,
    ) -> Arc<Self> {
        Arc::new(Self {
            config,
            db,
            validator,
            events_path,
            last_request: RwLock::new(std::time::Instant::now()),
            shutdown_notify: Notify::new(),
            active_sessions: RwLock::new(0),
            request_count: AtomicU64::new(0),
        })
    }

    pub async fn touch(&self) {
        *self.last_request.write().await = std::time::Instant::now();
        self.request_count.fetch_add(1, Ordering::Relaxed);
    }

    pub async fn wait_for_idle(&self, timeout_secs: u64) {
        if timeout_secs == 0 {
            std::future::pending::<()>().await;
            return;
        }
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(10)).await;
            let elapsed = self.last_request.read().await.elapsed();
            if elapsed.as_secs() >= timeout_secs {
                return;
            }
        }
    }

    pub async fn wait_for_shutdown_signal(&self) {
        self.shutdown_notify.notified().await;
    }
}

pub fn build_router(state: Arc<AppState>) -> Router {
    Router::new()
        // Primary hook endpoint — all HTTP hooks hit this
        .route("/hook", post(handle_hook))
        // Session lifecycle — called by command shims
        .route("/session/start", post(handle_session_start))
        .route("/session/end", post(handle_session_end))
        // Daemon management
        .route("/health", get(health))
        .route("/metrics", get(metrics))
        .route("/budget", get(budget))
        .route("/statusline", post(handle_statusline))
        .route("/sessions/active", get(sessions_active))
        .route("/shutdown", post(shutdown))
        .with_state(state)
}

async fn handle_hook(
    State(state): State<Arc<AppState>>,
    Json(input): Json<types::HookInput>,
) -> impl IntoResponse {
    state.touch().await;

    let output = router::dispatch(&state, &input);

    Json(output.to_http_response())
}

async fn handle_session_start(
    State(state): State<Arc<AppState>>,
    Json(input): Json<types::HookInput>,
) -> impl IntoResponse {
    state.touch().await;
    *state.active_sessions.write().await += 1;

    let output = crate::handlers::session::handle_start(&state, &input);
    Json(output.to_http_response())
}

async fn handle_session_end(
    State(state): State<Arc<AppState>>,
    Json(input): Json<types::HookInput>,
) -> impl IntoResponse {
    state.touch().await;
    let mut count = state.active_sessions.write().await;
    if *count > 0 {
        *count -= 1;
    }

    let output = crate::handlers::session::handle_end(&state, &input);
    Json(output.to_http_response())
}

async fn handle_statusline(
    State(state): State<Arc<AppState>>,
    body: String,
) -> impl IntoResponse {
    state.touch().await;
    crate::handlers::statusline::render(&state, &body)
}

async fn health() -> impl IntoResponse {
    (StatusCode::OK, "ok")
}

async fn metrics(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let metrics = observability::prometheus_metrics(&state);
    (StatusCode::OK, metrics)
}

async fn budget(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let budget = state.db.get_budget().unwrap_or_default();
    Json(budget)
}

async fn sessions_active(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let count = *state.active_sessions.read().await;
    count.to_string()
}

async fn shutdown(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    state.shutdown_notify.notify_one();
    (StatusCode::OK, "shutting down")
}
