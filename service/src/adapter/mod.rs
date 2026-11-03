//! Адаптеры игр: из сейва / файлов мода → общая модель состояния.

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Result, bail};

use crate::config::GameConfig;
use crate::content::Content;
use crate::state::GameState;

pub mod dd2;

pub trait Adapter: Send + Sync {
    /// Папки, за изменениями в которых следит наблюдатель.
    fn watch_paths(&self) -> Vec<PathBuf>;
    /// Прочитать текущее состояние. `None` — данных пока нет (игра не запускалась, сейва нет).
    /// Может быть медленным (запуск внешней утилиты): вызывается вне async-потоков.
    fn read(&self) -> Result<Option<GameState>>;
}

pub fn create(
    cfg: &GameConfig,
    content: Arc<Content>,
    work_dir: PathBuf,
) -> Result<Arc<dyn Adapter>> {
    match cfg.adapter.as_str() {
        "dd2" => Ok(Arc::new(dd2::Dd2::new(cfg, content, work_dir))),
        other => bail!("неизвестный адаптер {other}"),
    }
}
