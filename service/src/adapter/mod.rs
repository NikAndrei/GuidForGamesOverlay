//! Адаптеры игр: из сейва / файлов мода → общая модель состояния.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Result, bail};
use serde::Serialize;

use crate::config::GameConfig;
use crate::content::Content;
use crate::state::GameState;
use crate::steam;

pub mod dd2;
pub mod re4;

pub trait Adapter: Send + Sync {
    /// Папки, за изменениями в которых следит наблюдатель.
    fn watch_paths(&self) -> Vec<PathBuf>;
    /// Прочитать текущее состояние. `None` — данных пока нет (игра не запускалась, сейва нет).
    /// Может быть медленным (запуск внешней утилиты): вызывается вне async-потоков.
    fn read(&self) -> Result<Option<GameState>>;
}

/// Где что лежит у конкретной игры: из настроек или найдено в Steam.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Paths {
    pub game_dir: Option<PathBuf>,
    pub mod_dir: Option<PathBuf>,
    pub save_dir: Option<PathBuf>,
    pub save_tool: Option<PathBuf>,
    pub steam_id: Option<String>,
    /// Своя рабочая папка (копии сейвов).
    pub work_dir: PathBuf,
}

impl Paths {
    /// Настройки игры поверх найденного в Steam. `save_sub` — путь сейвов внутри userdata/<аккаунт>/<AppID>.
    pub fn resolve(
        content: &Content,
        cfg: &GameConfig,
        steam_roots: &[PathBuf],
        save_sub: Option<&str>,
        work_dir: PathBuf,
    ) -> Self {
        let app = content.steam_app_id;
        let game_dir = cfg
            .game_dir
            .clone()
            .or_else(|| app.and_then(|a| steam::game_dir(steam_roots, a)));
        let mod_dir = cfg.mod_dir.clone().or_else(|| {
            game_dir
                .as_ref()
                .map(|g| g.join("reframework").join("data"))
        });
        let save_dir = cfg.save_dir.clone().or_else(|| {
            let (a, sub) = (app?, save_sub?);
            steam::userdata_dirs(steam_roots, a, sub).into_iter().next()
        });
        Self {
            game_dir,
            mod_dir,
            save_dir,
            save_tool: cfg.save_tool.clone(),
            steam_id: cfg.steam_id.clone(),
            work_dir,
        }
    }
}

/// Утилита рядом с программой (`dd2-save.exe` возле `gfg-service.exe`).
pub fn sibling_tool(name: &str) -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let file = format!("{name}{}", std::env::consts::EXE_SUFFIX);
    let p = exe.parent()?.join(file);
    p.is_file().then_some(p)
}

/// Имя адаптера и подпапка сейвов в userdata.
pub fn save_sub(adapter: &str) -> Option<&'static str> {
    match adapter {
        "dd2" => Some(dd2::SAVE_SUB),
        _ => None,
    }
}

pub fn create(name: &str, content: Arc<Content>, paths: Paths) -> Result<Arc<dyn Adapter>> {
    match name {
        "dd2" => Ok(Arc::new(dd2::Dd2::new(content, paths))),
        "re4" => Ok(Arc::new(re4::Re4::new(content, paths))),
        other => bail!("неизвестный адаптер {other}"),
    }
}

pub(crate) fn mtime(p: &Path) -> Option<std::time::SystemTime> {
    std::fs::metadata(p).ok()?.modified().ok()
}
