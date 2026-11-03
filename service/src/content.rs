//! Контент игры: папка `games/<game-id>/` — game.json, entries/*.json, save-map.json, rules.json (или rules/).

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Name {
    pub ru: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub en: Option<String>,
}

/// Запись справочника игры — только поля, нужные оверлею.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub title: Name,
    #[serde(default)]
    pub location: Option<Name>,
    /// Ступень прогресса, до которой запись скрыта целиком.
    #[serde(default)]
    pub available_from: Option<String>,
    /// Ступень, после начала которой запись уже не сделать (пропускаемое).
    #[serde(default)]
    pub missable_after: Option<String>,
    #[serde(default)]
    pub missable_note: Option<String>,
    pub hints: Vec<String>,
    #[serde(default)]
    pub sources: Vec<String>,
    /// Объекты игры («file:38», «chapter:2»…): любой есть в флагах состояния — запись найдена.
    #[serde(default)]
    pub game_refs: Vec<String>,
    /// Порядок в справочнике (файлы по имени, внутри файла — как записано): по сюжету.
    #[serde(skip)]
    pub order: usize,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ProgressStep {
    pub id: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GameFile {
    id: String,
    title: Name,
    progress: Vec<ProgressStep>,
    #[serde(default)]
    adapter: Option<String>,
    #[serde(default)]
    steam_app_id: Option<u32>,
    #[serde(default)]
    exe: Vec<String>,
}

/// Сопоставление номеров из игры с записями и ступенями (`save-map.json`).
#[derive(Debug, Clone, Default, Deserialize)]
pub struct SaveMap {
    /// Номер квеста → запись и ступень (DD2).
    #[serde(default)]
    pub quests: BTreeMap<String, SaveMapQuest>,
    /// Номер главы игры → ступень (RE4: chainsaw.ChapterID).
    #[serde(default)]
    pub chapters: BTreeMap<String, String>,
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
    pub dir: PathBuf,
    pub game_id: String,
    pub title: Name,
    pub adapter: Option<String>,
    pub steam_app_id: Option<u32>,
    /// Имена exe игры: по ним оверлей сообщает, в какой игре он запущен.
    pub exe: Vec<String>,
    /// Ступени прогресса по порядку сюжета.
    pub progress: Vec<String>,
    pub entries: HashMap<String, Entry>,
    pub save_map: SaveMap,
}

impl Content {
    pub fn load(dir: &Path) -> Result<Self> {
        let game: GameFile = read_json(&dir.join("game.json"))?;
        let mut entries = Vec::new();
        let edir = dir.join("entries");
        for f in json_files(&edir)? {
            let part: Vec<Entry> = read_json(&f)?;
            entries.extend(part);
        }
        let sm = dir.join("save-map.json");
        let save_map = if sm.exists() {
            read_json(&sm)?
        } else {
            SaveMap::default()
        };
        let mut by_id = HashMap::new();
        for (i, mut e) in entries.into_iter().enumerate() {
            e.order = i;
            if by_id.contains_key(&e.id) {
                bail!("повторяется id записи {}", e.id);
            }
            by_id.insert(e.id.clone(), e);
        }
        Ok(Self {
            dir: dir.to_path_buf(),
            game_id: game.id,
            title: game.title,
            adapter: game.adapter,
            steam_app_id: game.steam_app_id,
            exe: game.exe,
            progress: game.progress.into_iter().map(|p| p.id).collect(),
            entries: by_id,
            save_map,
        })
    }

    /// Правила: папка `rules/` или файл `rules.json`.
    pub fn rules_path(&self) -> PathBuf {
        let d = self.dir.join("rules");
        if d.is_dir() {
            d
        } else {
            self.dir.join("rules.json")
        }
    }

    pub fn progress_index(&self, id: &str) -> Option<usize> {
        self.progress.iter().position(|p| p == id)
    }
}

/// Все игры в папке: подпапки с game.json.
pub fn discover(games_dir: &Path) -> Result<Vec<PathBuf>> {
    let mut dirs: Vec<_> = fs::read_dir(games_dir)
        .with_context(|| format!("не читается {}", games_dir.display()))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.join("game.json").is_file())
        .collect();
    dirs.sort();
    Ok(dirs)
}

pub fn json_files(dir: &Path) -> Result<Vec<PathBuf>> {
    let mut files: Vec<_> = fs::read_dir(dir)
        .with_context(|| format!("не читается {}", dir.display()))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|e| e == "json"))
        .collect();
    files.sort();
    Ok(files)
}

pub fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T> {
    let text =
        fs::read_to_string(path).with_context(|| format!("не читается {}", path.display()))?;
    // Lua-мост и Windows-редакторы иногда пишут BOM.
    let text = text.trim_start_matches('\u{feff}');
    serde_json::from_str(text).with_context(|| format!("ошибка в {}", path.display()))
}
