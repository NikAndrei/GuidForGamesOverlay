//! Отладочная страница и HTTP API (только localhost).

use std::net::SocketAddr;

use anyhow::Result;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{Html, IntoResponse};
use axum::routing::{get, post};
use axum::{Json, Router};

use crate::app::App;

pub fn router(app: App) -> Router {
    Router::new()
        .route("/", get(|| async { Html(PAGE) }))
        .route(
            "/api/status",
            get(|State(app): State<App>| async move { Json(app.status()) }),
        )
        .route(
            "/api/ui",
            get(|State(app): State<App>| async move { Json(app.ui()) }),
        )
        .route("/api/reveal/{item}", post(reveal))
        .route("/api/hide/{item}", post(hide))
        .route(
            "/api/refresh",
            post(|State(app): State<App>| async move {
                app.refresh_all().await;
                Json(app.ui())
            }),
        )
        .with_state(app)
}

async fn reveal(State(app): State<App>, Path(item): Path<String>) -> impl IntoResponse {
    if app.reveal(&item) {
        Ok(Json(app.ui()))
    } else {
        Err(StatusCode::NOT_FOUND)
    }
}

async fn hide(State(app): State<App>, Path(item): Path<String>) -> impl IntoResponse {
    if app.hide(&item) {
        Ok(Json(app.ui()))
    } else {
        Err(StatusCode::NOT_FOUND)
    }
}

pub async fn serve(app: App, addr: SocketAddr) -> Result<()> {
    let listener = tokio::net::TcpListener::bind(addr).await?;
    eprintln!("отладочная страница: http://{addr}/");
    axum::serve(listener, router(app)).await?;
    Ok(())
}

const PAGE: &str = r#"<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>GuidForGames Overlay — состояние</title>
<style>
  :root { color-scheme: light dark; --bg:#f6f6f4; --fg:#1d1d1b; --muted:#6b6b66; --card:#fff; --line:#ddd; --accent:#3b6fd8; --bad:#c0392b; }
  @media (prefers-color-scheme: dark) { :root { --bg:#17181a; --fg:#e8e8e6; --muted:#9a9a95; --card:#222326; --line:#34363a; --accent:#7aa2ff; --bad:#ff7a6b; } }
  body { margin:0; padding:16px; background:var(--bg); color:var(--fg); font:15px/1.45 system-ui, sans-serif; }
  main { max-width:960px; margin:0 auto; display:grid; gap:16px; }
  h1 { font-size:20px; margin:0; } h2 { font-size:16px; margin:0 0 8px; }
  section { background:var(--card); border:1px solid var(--line); border-radius:8px; padding:12px 14px; }
  .muted { color:var(--muted); } .bad { color:var(--bad); }
  .item { border-top:1px solid var(--line); padding:10px 0; } .item:first-child { border-top:0; }
  .item ol { margin:6px 0; padding-left:22px; }
  button { font:inherit; padding:4px 10px; border-radius:6px; border:1px solid var(--line); background:var(--bg); color:var(--fg); cursor:pointer; }
  button.primary { background:var(--accent); border-color:var(--accent); color:#fff; }
  pre { margin:0; overflow:auto; max-height:420px; font-size:12px; }
  .row { display:flex; gap:8px; align-items:center; flex-wrap:wrap; }
</style>
</head>
<body>
<main>
  <div class="row"><h1>GuidForGames Overlay</h1><button id="refresh">Перечитать сейвы</button><span class="muted" id="clock"></span></div>
  <section><h2>Актуально сейчас</h2><div id="items" class="muted">загрузка…</div></section>
  <section><h2>Игры</h2><div id="games"></div></section>
</main>
<script>
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
async function post(url) { await fetch(url, { method: 'POST' }); load(); }
async function load() {
  const [ui, status] = await Promise.all([fetch('/api/ui').then(r => r.json()), fetch('/api/status').then(r => r.json())]);
  document.getElementById('clock').textContent = ui.game ? `${ui.title?.ru ?? ui.game} · ${ui.source} · ${ui.updatedAt}` : 'нет данных ни по одной игре';
  const items = document.getElementById('items');
  items.className = ui.items.length ? '' : 'muted';
  items.innerHTML = ui.items.length ? ui.items.map(it => `
    <div class="item">
      <div class="row"><strong>${esc(it.title.ru)}</strong><span class="muted">${esc(it.title.en)}</span></div>
      ${it.location ? `<div class="muted">${esc(it.location.ru)}</div>` : ''}
      <ol>${it.hints.map(h => `<li>${esc(h)}</li>`).join('')}</ol>
      <div class="row">
        ${it.revealed < it.levels ? `<button class="primary" onclick="post('/api/reveal/${encodeURIComponent(it.id)}')">${['Намёк','Подробнее','Ответ'][it.revealed] ?? 'Дальше'}</button>` : ''}
        ${it.revealed ? `<button onclick="post('/api/hide/${encodeURIComponent(it.id)}')">Скрыть</button>` : ''}
        <span class="muted">${it.revealed} из ${it.levels}</span>
      </div>
    </div>`).join('') : 'Подходящих подсказок нет.';
  document.getElementById('games').innerHTML = status.map(g => `
    <div class="item">
      <div class="row"><strong>${esc(g.id)}</strong><span class="muted">правил: ${g.rules}, проверено: ${esc(g.checkedAt ?? '—')}</span></div>
      <div class="muted">слежу: ${g.watch.map(esc).join(', ') || 'ничего (не заданы save_dir / mod_dir)'}</div>
      ${g.error ? `<div class="bad">${esc(g.error)}</div>` : ''}
      ${g.problems.map(p => `<div class="bad">${esc(p)}</div>`).join('')}
      <details><summary>Модель состояния</summary><pre>${esc(JSON.stringify(g.state, null, 2))}</pre></details>
    </div>`).join('');
}
document.getElementById('refresh').onclick = () => post('/api/refresh');
load(); setInterval(load, 2000);
</script>
</body>
</html>
"#;
