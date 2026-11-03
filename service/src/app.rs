//! Ядро сервиса: игры, их состояние, раскрытые подсказки и рассылка модели UI.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use serde::Serialize;
use tokio::sync::watch;

use crate::adapter::{self, Adapter, Paths};
use crate::config::{Config, GameConfig};
use crate::content::{self, Content};
use crate::rules::{self, Rule};
use crate::state::{GameState, now_rfc3339};
use crate::steam;
use crate::ui::{self, Reveals, UiModel};

pub struct Game {
    pub id: String,
    pub content: Arc<Content>,
    pub rules: Vec<Rule>,
    pub adapter: Arc<dyn Adapter>,
    pub paths: Paths,
    pub problems: Vec<String>,
    pub state: Option<GameState>,
    pub error: Option<String>,
    pub checked_at: Option<String>,
}

pub struct Inner {
    pub games: Vec<Game>,
    pub reveals: Reveals,
}

#[derive(Clone)]
pub struct App {
    inner: Arc<Mutex<Inner>>,
    ui: watch::Sender<UiModel>,
    reveals_file: PathBuf,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GameStatus {
    pub id: String,
    pub title: String,
    pub paths: Paths,
    pub watch: Vec<PathBuf>,
    pub rules: usize,
    pub problems: Vec<String>,
    pub state: Option<GameState>,
    pub error: Option<String>,
    pub checked_at: Option<String>,
}

impl App {
    pub fn new(cfg: &Config) -> Result<Self> {
        let steam_roots = steam::roots(cfg.steam_dir.as_deref());
        let mut games = Vec::new();
        for dir in content::discover(cfg.games_dir())? {
            games.extend(load_game(&dir, cfg, &steam_roots)?);
        }
        if games.is_empty() {
            anyhow::bail!("нет игр в {}", cfg.games_dir().display());
        }
        let reveals_file = cfg.state_dir().join("reveals.json");
        let reveals = std::fs::read_to_string(&reveals_file)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default();
        let (ui, _) = watch::channel(UiModel::default());
        Ok(Self {
            inner: Arc::new(Mutex::new(Inner { games, reveals })),
            ui,
            reveals_file,
        })
    }

    pub fn subscribe(&self) -> watch::Receiver<UiModel> {
        self.ui.subscribe()
    }

    pub fn ui(&self) -> UiModel {
        self.ui.borrow().clone()
    }

    pub fn game_count(&self) -> usize {
        self.inner.lock().unwrap().games.len()
    }

    pub fn watch_paths(&self) -> Vec<(usize, PathBuf)> {
        let inner = self.inner.lock().unwrap();
        inner
            .games
            .iter()
            .enumerate()
            .flat_map(|(i, g)| g.adapter.watch_paths().into_iter().map(move |p| (i, p)))
            .collect()
    }

    pub fn status(&self) -> Vec<GameStatus> {
        let inner = self.inner.lock().unwrap();
        inner
            .games
            .iter()
            .map(|g| GameStatus {
                id: g.id.clone(),
                title: g.content.title.ru.clone(),
                paths: g.paths.clone(),
                watch: g.adapter.watch_paths(),
                rules: g.rules.len(),
                problems: g.problems.clone(),
                state: g.state.clone(),
                error: g.error.clone(),
                checked_at: g.checked_at.clone(),
            })
            .collect()
    }

    /// Перечитать состояние игры (адаптер может запускать внешнюю утилиту — вне async-потоков).
    pub async fn refresh(&self, idx: usize) {
        let adapter = {
            let inner = self.inner.lock().unwrap();
            match inner.games.get(idx) {
                Some(g) => g.adapter.clone(),
                None => return,
            }
        };
        let result = tokio::task::spawn_blocking(move || adapter.read())
            .await
            .unwrap_or_else(|e| Err(anyhow::anyhow!("адаптер упал: {e}")));
        {
            let mut inner = self.inner.lock().unwrap();
            let g = &mut inner.games[idx];
            g.checked_at = Some(now_rfc3339());
            match result {
                Ok(state) => {
                    if state.is_some() {
                        g.state = state;
                    }
                    g.error = None;
                }
                Err(e) => {
                    let msg = format!("{e:#}");
                    if g.error.as_deref() != Some(msg.as_str()) {
                        eprintln!("[{}] {msg}", g.id);
                    }
                    g.error = Some(msg);
                }
            }
        }
        self.publish();
    }

    pub async fn refresh_all(&self) {
        for i in 0..self.game_count() {
            self.refresh(i).await;
        }
    }

    /// Раскрыть следующий уровень подсказки в текущей игре.
    pub fn reveal(&self, item: &str) -> bool {
        self.change_reveal(item, |n, levels| (n + 1).min(levels))
    }

    /// Скрыть все уровни подсказки.
    pub fn hide(&self, item: &str) -> bool {
        self.change_reveal(item, |_, _| 0)
    }

    fn change_reveal(&self, item: &str, f: impl Fn(usize, usize) -> usize) -> bool {
        let ui = self.ui();
        let (Some(game), Some(it)) = (ui.game.as_deref(), ui.items.iter().find(|i| i.id == item))
        else {
            return false;
        };
        {
            let mut inner = self.inner.lock().unwrap();
            let n = f(inner.reveals.get(game, item), it.levels);
            inner.reveals.set(game, item, n);
            if let Err(e) = save_reveals(&self.reveals_file, &inner.reveals) {
                eprintln!("не сохранить {}: {e:#}", self.reveals_file.display());
            }
        }
        self.publish();
        true
    }

    /// Пересобрать модель UI. Текущая игра — та, чьё состояние обновлялось последним.
    fn publish(&self) {
        let model = {
            let inner = self.inner.lock().unwrap();
            inner
                .games
                .iter()
                .filter_map(|g| g.state.as_ref().map(|s| (g, s)))
                .max_by(|(_, a), (_, b)| a.updated_at.cmp(&b.updated_at))
                .map(|(g, s)| ui::build(s, &g.content, &g.rules, &inner.reveals))
                .unwrap_or_default()
        };
        self.ui.send_if_modified(|cur| {
            if *cur == model {
                false
            } else {
                *cur = model;
                true
            }
        });
    }
}

fn load_game(dir: &std::path::Path, cfg: &Config, steam_roots: &[PathBuf]) -> Result<Option<Game>> {
    let content = Arc::new(Content::load(dir).with_context(|| format!("игра {}", dir.display()))?);
    let game_cfg = cfg
        .games
        .get(&content.game_id)
        .cloned()
        .unwrap_or_else(|| GameConfig {
            enabled: true,
            ..Default::default()
        });
    if !game_cfg.enabled {
        return Ok(None);
    }
    let rules_path = content.rules_path();
    let rules = if rules_path.exists() {
        rules::load(&rules_path, &content.game_id)?
    } else {
        Vec::new()
    };
    let mut problems = rules::check(&rules, &content);
    if rules.is_empty() {
        problems.push("нет правил (rules.json)".into());
    }
    let adapter_name = content.adapter.clone().unwrap_or_default();
    let paths = Paths::resolve(
        &content,
        &game_cfg,
        steam_roots,
        adapter::save_sub(&adapter_name),
        cfg.state_dir().join("work").join(&content.game_id),
    );
    let adapter = adapter::create(&adapter_name, content.clone(), paths.clone())
        .with_context(|| format!("игра {}", content.game_id))?;
    for p in &problems {
        eprintln!("[{}] {p}", content.game_id);
    }
    eprintln!(
        "[{}] игра: {}, мод: {}, сейвы: {}",
        content.game_id,
        show(&paths.game_dir),
        show(&paths.mod_dir),
        show(&paths.save_dir)
    );
    Ok(Some(Game {
        id: content.game_id.clone(),
        content,
        rules,
        adapter,
        paths,
        problems,
        state: None,
        error: None,
        checked_at: None,
    }))
}

fn show(p: &Option<PathBuf>) -> String {
    p.as_ref()
        .map_or("не найдено".into(), |p| p.display().to_string())
}

fn save_reveals(path: &std::path::Path, reveals: &Reveals) -> Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    std::fs::write(path, serde_json::to_string_pretty(reveals)?)?;
    Ok(())
}
