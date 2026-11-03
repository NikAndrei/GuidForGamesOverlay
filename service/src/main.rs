use std::path::PathBuf;

use anyhow::Result;
use gfg_service::{app::App, config::Config, http, overlay, watcher};

#[tokio::main]
async fn main() -> Result<()> {
    let path = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("config.toml"));
    let cfg = Config::load(&path)?;
    let app = App::new(&cfg)?;
    app.refresh_all().await;
    watcher::spawn(app.clone());
    tokio::try_join!(
        http::serve(app.clone(), cfg.http),
        overlay::serve(app, cfg.overlay)
    )?;
    Ok(())
}
