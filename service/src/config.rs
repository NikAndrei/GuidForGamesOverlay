//! Настройки сервиса (`config.toml`, необязательный). Без него игры берутся из папки `games/`,
//! а их папки в Steam находятся сами. Относительные пути — от папки файла настроек.

use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    /// Отладочная страница и HTTP API.
    #[serde(default = "default_http")]
    pub http: SocketAddr,
    /// Протокол для оверлея: JSON по строкам через TCP.
    #[serde(default = "default_overlay")]
    pub overlay: SocketAddr,
    /// Своё состояние: раскрытые подсказки, копии сейвов.
    #[serde(default)]
    pub state_dir: Option<PathBuf>,
    /// Папка с играми (game.json, entries, rules). Нет — ищется рядом с программой.
    #[serde(default)]
    pub games_dir: Option<PathBuf>,
    /// Папка Steam, если не находится сама.
    #[serde(default)]
    pub steam_dir: Option<PathBuf>,
    /// Настройки отдельных игр: `[games.<id>]`.
    #[serde(default)]
    pub games: BTreeMap<String, GameConfig>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GameConfig {
    #[serde(default = "yes")]
    pub enabled: bool,
    /// Папка установленной игры (по умолчанию — из Steam по steamAppId).
    pub game_dir: Option<PathBuf>,
    /// Куда пишет мод-мост (по умолчанию `<игра>/reframework/data`).
    pub mod_dir: Option<PathBuf>,
    /// Папка сохранений (по умолчанию — из userdata Steam).
    pub save_dir: Option<PathBuf>,
    /// Утилита разбора сейва (DD2: dd2-save рядом с программой).
    pub save_tool: Option<PathBuf>,
    /// SteamID64 или номер аккаунта; нет — берётся из пути `userdata/<номер>/…`.
    pub steam_id: Option<String>,
}

fn yes() -> bool {
    true
}

fn default_http() -> SocketAddr {
    "127.0.0.1:7870".parse().unwrap()
}

fn default_overlay() -> SocketAddr {
    "127.0.0.1:7871".parse().unwrap()
}

impl Default for Config {
    fn default() -> Self {
        toml::from_str("").unwrap()
    }
}

impl Config {
    /// `path` — явный файл настроек; нет — `config.toml` рядом с папкой игр, если есть.
    pub fn load(path: Option<&Path>) -> Result<Self> {
        let path = match path {
            Some(p) => Some(p.to_path_buf()),
            None => app_dir()
                .map(|d| d.join("config.toml"))
                .filter(|p| p.is_file()),
        };
        let Some(path) = path else {
            return Ok(Config::default().resolved(app_dir().as_deref()));
        };
        let text = std::fs::read_to_string(&path)
            .with_context(|| format!("не читается {}", path.display()))?;
        let cfg: Config =
            toml::from_str(&text).with_context(|| format!("ошибка в {}", path.display()))?;
        let base = path.parent().map(Path::to_path_buf);
        Ok(cfg.resolved(base.as_deref()))
    }

    fn resolved(mut self, base: Option<&Path>) -> Self {
        let base = base
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."));
        let r = |p: &Path| {
            if p.is_absolute() {
                p.to_path_buf()
            } else {
                base.join(p)
            }
        };
        // Папка игр по умолчанию — рядом с программой, где бы ни лежал файл настроек.
        self.games_dir = Some(match self.games_dir.as_deref() {
            Some(p) => r(p),
            None => app_dir().unwrap_or(base.clone()).join("games"),
        });
        self.state_dir = Some(r(self.state_dir.as_deref().unwrap_or(Path::new("state"))));
        self.steam_dir = self.steam_dir.as_deref().map(r);
        for g in self.games.values_mut() {
            for p in [
                &mut g.game_dir,
                &mut g.mod_dir,
                &mut g.save_dir,
                &mut g.save_tool,
            ]
            .into_iter()
            .flatten()
            {
                *p = r(p);
            }
        }
        self
    }

    pub fn games_dir(&self) -> &Path {
        self.games_dir.as_deref().unwrap()
    }

    pub fn state_dir(&self) -> &Path {
        self.state_dir.as_deref().unwrap()
    }
}

/// Папка приложения — та, где лежит `games/`: текущая, рядом с программой или корень репозитория
/// (при запуске из `target/<profile>/`).
pub fn app_dir() -> Option<PathBuf> {
    let mut candidates = vec![std::env::current_dir().ok()];
    if let Ok(exe) = std::env::current_exe() {
        let mut d = exe.parent().map(Path::to_path_buf);
        for _ in 0..3 {
            candidates.push(d.clone());
            d = d.and_then(|p| p.parent().map(Path::to_path_buf));
        }
    }
    candidates
        .into_iter()
        .flatten()
        .find(|d| d.join("games").is_dir())
}
