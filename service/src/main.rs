use std::path::PathBuf;

use anyhow::{Result, bail};
use gfg_service::{app::App, config::Config, http, install, overlay, watcher};

const USAGE: &str = "\
gfg-service [--config <config.toml>]                 запустить сервис
gfg-service install-mods [--config <config.toml>]    поставить моды-мосты REFramework в найденные игры";

#[tokio::main]
async fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let mut command = None;
    let mut config = None;
    while let Some(a) = args.next() {
        match a.as_str() {
            "--config" | "-c" => config = args.next().map(PathBuf::from),
            "-h" | "--help" => {
                println!("{USAGE}");
                return Ok(());
            }
            // Старый вызов: путь к настройкам первым аргументом.
            s if s.ends_with(".toml") => config = Some(PathBuf::from(s)),
            s if command.is_none() => command = Some(s.to_string()),
            s => bail!("непонятный аргумент {s}\n{USAGE}"),
        }
    }
    let cfg = Config::load(config.as_deref())?;
    match command.as_deref() {
        None => {}
        Some("install-mods") => return install::install_mods(&cfg),
        Some(other) => bail!("неизвестная команда {other}\n{USAGE}"),
    }
    let app = App::new(&cfg)?;
    app.refresh_all().await;
    watcher::spawn(app.clone());
    tokio::try_join!(
        http::serve(app.clone(), cfg.http),
        overlay::serve(app, cfg.overlay)
    )?;
    Ok(())
}
