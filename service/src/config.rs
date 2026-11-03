//! Настройки сервиса (`config.toml`). Относительные пути считаются от папки файла настроек.

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
    /// Куда сохранять своё (раскрытые подсказки, копии сейвов).
    #[serde(default = "default_state_dir")]
    pub state_dir: PathBuf,
    #[serde(default, rename = "game")]
    pub games: Vec<GameConfig>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GameConfig {
    /// Какой адаптер разбирает сейвы: пока только `dd2`.
    pub adapter: String,
    /// Папка `data/<game-id>` GuidForGames или файл пакета.
    pub content: PathBuf,
    /// Файл или папка с правилами (`hints/<game>/`).
    pub rules: PathBuf,
    /// save-map.json, если content — пакет.
    pub save_map: Option<PathBuf>,
    /// Папка сохранений игры.
    pub save_dir: Option<PathBuf>,
    /// Папка, куда пишет мод-мост (`<игра>/reframework/data`).
    pub mod_dir: Option<PathBuf>,
    /// Утилита разбора сейва (DD2: dd2-save.exe из GuidForGames).
    pub save_tool: Option<PathBuf>,
    /// SteamID64 или номер аккаунта; нет — берётся из пути `userdata/<номер>/…`.
    pub steam_id: Option<String>,
}

fn default_http() -> SocketAddr {
    "127.0.0.1:7870".parse().unwrap()
}

fn default_overlay() -> SocketAddr {
    "127.0.0.1:7871".parse().unwrap()
}

fn default_state_dir() -> PathBuf {
    PathBuf::from("state")
}

impl Config {
    pub fn load(path: &Path) -> Result<Self> {
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("не читается {}", path.display()))?;
        let mut cfg: Config =
            toml::from_str(&text).with_context(|| format!("ошибка в {}", path.display()))?;
        let base = path.parent().unwrap_or(Path::new("."));
        cfg.state_dir = resolve(base, &cfg.state_dir);
        for g in &mut cfg.games {
            g.content = resolve(base, &g.content);
            g.rules = resolve(base, &g.rules);
            for p in [
                &mut g.save_map,
                &mut g.save_dir,
                &mut g.mod_dir,
                &mut g.save_tool,
            ]
            .into_iter()
            .flatten()
            {
                *p = resolve(base, p);
            }
        }
        Ok(cfg)
    }
}

fn resolve(base: &Path, p: &Path) -> PathBuf {
    if p.is_absolute() {
        p.to_path_buf()
    } else {
        base.join(p)
    }
}
