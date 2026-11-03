//! Протокол для оверлея (аддон ReShade, прозрачное окно): TCP на localhost, по одному JSON в строке (UTF-8).
//!
//! Сервис → клиент:
//!   `{"type":"hello","protocol":1}` — сразу после подключения;
//!   `{"type":"ui","ui":{…}}` — модель UI, сразу и при каждом изменении.
//! Клиент → сервис:
//!   `{"cmd":"reveal","item":"<id>"}` — раскрыть следующий уровень;
//!   `{"cmd":"hide","item":"<id>"}` — скрыть все уровни;
//!   `{"cmd":"refresh"}` — перечитать сейвы;
//!   `{"cmd":"game","exe":"DD2.exe"}` — в какой игре запущен оверлей (подсказки — по ней).
//! Ответ на команду — `{"type":"error","message":"…"}` при ошибке; успех виден по новой модели UI.

use std::net::SocketAddr;

use anyhow::Result;
use serde::Deserialize;
use serde_json::json;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};

use crate::app::App;

pub const PROTOCOL: u32 = 1;

#[derive(Debug, Deserialize)]
#[serde(tag = "cmd", rename_all = "lowercase")]
pub enum Command {
    Reveal { item: String },
    Hide { item: String },
    Refresh,
    Game { exe: String },
}

pub async fn serve(app: App, addr: SocketAddr) -> Result<()> {
    let listener = TcpListener::bind(addr).await?;
    eprintln!("оверлей: tcp://{addr}");
    loop {
        let (stream, _) = listener.accept().await?;
        let app = app.clone();
        tokio::spawn(async move {
            if let Err(e) = client(app, stream).await {
                eprintln!("оверлей отключился: {e}");
            }
        });
    }
}

async fn client(app: App, stream: TcpStream) -> Result<()> {
    let (read, mut write) = stream.into_split();
    let mut lines = BufReader::new(read).lines();
    let mut ui = app.subscribe();
    send(
        &mut write,
        &json!({ "type": "hello", "protocol": PROTOCOL }),
    )
    .await?;
    let first = ui.borrow_and_update().clone();
    send(&mut write, &json!({ "type": "ui", "ui": first })).await?;
    loop {
        tokio::select! {
            changed = ui.changed() => {
                if changed.is_err() { return Ok(()) }
                let model = ui.borrow_and_update().clone();
                send(&mut write, &json!({ "type": "ui", "ui": model })).await?;
            }
            line = lines.next_line() => {
                let Some(line) = line? else { return Ok(()) };
                if line.trim().is_empty() { continue }
                if let Err(msg) = handle(&app, &line).await {
                    send(&mut write, &json!({ "type": "error", "message": msg })).await?;
                }
            }
        }
    }
}

pub async fn handle(app: &App, line: &str) -> Result<(), String> {
    let cmd: Command =
        serde_json::from_str(line).map_err(|e| format!("непонятная команда: {e}"))?;
    match cmd {
        Command::Reveal { item } => app
            .reveal(&item)
            .then_some(())
            .ok_or(format!("нет подсказки {item}")),
        Command::Hide { item } => app
            .hide(&item)
            .then_some(())
            .ok_or(format!("нет подсказки {item}")),
        Command::Refresh => {
            app.refresh_all().await;
            Ok(())
        }
        Command::Game { exe } => app
            .set_game_by_exe(&exe)
            .map(|_| ())
            .ok_or(format!("игра {exe} не поддерживается")),
    }
}

async fn send(w: &mut (impl AsyncWriteExt + Unpin), v: &serde_json::Value) -> Result<()> {
    let mut s = serde_json::to_string(v)?;
    s.push('\n');
    w.write_all(s.as_bytes()).await?;
    Ok(())
}
