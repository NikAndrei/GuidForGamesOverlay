//! Контент подсказок из GuidForGames: папка `data/<game-id>/` или собранный пакет (`GamePack`).

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::Path;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Name {
    pub ru: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub en: Option<String>,
}

/// Запись GuidForGames — только поля, нужные оверлею.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub title: Name,
    #[serde(default)]
    pub location: Option<Name>,
    #[serde(default)]
    pub available_from: Option<String>,
    pub hints: Vec<String>,
    #[serde(default)]
    pub sources: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ProgressStep {
    pub id: String,
}

#[derive(Debug, Clone, Deserialize)]
struct GameFile {
    id: String,
    title: Name,
    progress: Vec<ProgressStep>,
}

#[derive(Debug, Deserialize)]
struct Pack {
    game: GameFile,
    entries: Vec<Entry>,
}

/// Сопоставление номеров квестов игры с записями и ступенями (`save-map.json`).
#[derive(Debug, Clone, Default, Deserialize)]
pub struct SaveMap {
    #[serde(default)]
    pub quests: BTreeMap<String, SaveMapQuest>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveMapQuest {
    #[serde(default)]
    pub entry: Option<String>,
    #[serde(default)]
    pub progress: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Content {
    pub game_id: String,
    pub title: Name,
    /// Ступени прогресса по порядку сюжета.
    pub progress: Vec<String>,
    pub entries: HashMap<String, Entry>,
    pub save_map: SaveMap,
}

impl Content {
    /// `path` — папка `data/<game-id>` GuidForGames (game.json, entries/*.json, save-map.json)
    /// или файл пакета. `save_map` — явный путь к save-map.json (у пакета его нет).
    pub fn load(path: &Path, save_map: Option<&Path>) -> Result<Self> {
        let (game, entries, mut map) = if path.is_dir() {
            let game: GameFile = read_json(&path.join("game.json"))?;
            let mut entries = Vec::new();
            let dir = path.join("entries");
            let mut files: Vec<_> = fs::read_dir(&dir)
                .with_context(|| format!("не читается {}", dir.display()))?
                .filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| p.extension().is_some_and(|e| e == "json"))
                .collect();
            files.sort();
            for f in files {
                let part: Vec<Entry> = read_json(&f)?;
                entries.extend(part);
            }
            let sm = path.join("save-map.json");
            let map = if sm.exists() {
                read_json(&sm)?
            } else {
                SaveMap::default()
            };
            (game, entries, map)
        } else {
            let pack: Pack = read_json(path)?;
            (pack.game, pack.entries, SaveMap::default())
        };
        if let Some(p) = save_map {
            map = read_json(p)?;
        }
        let mut by_id = HashMap::new();
        for e in entries {
            if by_id.contains_key(&e.id) {
                bail!("повторяется id записи {}", e.id);
            }
            by_id.insert(e.id.clone(), e);
        }
        Ok(Self {
            game_id: game.id,
            title: game.title,
            progress: game.progress.into_iter().map(|p| p.id).collect(),
            entries: by_id,
            save_map: map,
        })
    }

    pub fn progress_index(&self, id: &str) -> Option<usize> {
        self.progress.iter().position(|p| p == id)
    }
}

pub fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T> {
    let text =
        fs::read_to_string(path).with_context(|| format!("не читается {}", path.display()))?;
    // Lua-мост и Windows-редакторы иногда пишут BOM.
    let text = text.trim_start_matches('\u{feff}');
    serde_json::from_str(text).with_context(|| format!("ошибка в {}", path.display()))
}
