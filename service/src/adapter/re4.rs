//! Resident Evil 4 (Remake, Steam AppID 2050650).
//!
//! Источник — мод-мост REFramework (`mods/re4/guidforgames.lua`): `guidforgames_re4_live.json` раз в 2 с.
//! Сейв RE4 пока не разбирается.
//!
//! - ступень прогресса — самая дальняя глава прохождения (`mostChapter`, chainsaw.ChapterID → `save-map.json`);
//! - флаги — собранное: `file:<FileID>`, `item:<ItemID>`, `castellan:<глава куклы>`, `request:<QID>`
//!   и `chapter:<n>` для пройденных глав (все до самой дальней); по ним записи с `gameRefs` считаются найденными;
//! - место — `stage:<CurrentStageID>`.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use anyhow::Result;
use serde_json::Value;

use super::{Adapter, Paths, mtime};
use crate::content::{Content, read_json};
use crate::state::{GameState, Position, Source, time_rfc3339};

pub const LIVE_FILE: &str = "guidforgames_re4_live.json";
const LIVE_FRESH: Duration = Duration::from_secs(30);

pub struct Re4 {
    content: Arc<Content>,
    mod_dir: Option<PathBuf>,
}

impl Re4 {
    pub fn new(content: Arc<Content>, paths: Paths) -> Self {
        Self {
            content,
            mod_dir: paths.mod_dir,
        }
    }
}

impl Adapter for Re4 {
    fn watch_paths(&self) -> Vec<PathBuf> {
        self.mod_dir.iter().cloned().collect()
    }

    fn read(&self) -> Result<Option<GameState>> {
        let Some(dir) = &self.mod_dir else {
            return Ok(None);
        };
        read_live(&self.content, dir, SystemTime::now())
    }
}

pub fn read_live(content: &Content, dir: &Path, now: SystemTime) -> Result<Option<GameState>> {
    let path = dir.join(LIVE_FILE);
    let Some(at) = mtime(&path) else {
        return Ok(None);
    };
    let v: Value = read_json(&path)?;
    Ok(Some(from_live(content, &v, at, now)))
}

pub fn from_live(content: &Content, v: &Value, at: SystemTime, now: SystemTime) -> GameState {
    let num = |k: &str| v.get(k).and_then(Value::as_i64);
    let nums = |k: &str| -> Vec<i64> {
        v.get(k)
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_i64).collect())
            .unwrap_or_default()
    };
    let step =
        |ch: Option<i64>| ch.and_then(|c| content.save_map.chapters.get(&c.to_string()).cloned());
    // Самая дальняя глава; старые версии мода её не пишут — тогда текущая.
    let progress = step(num("mostChapter")).or_else(|| step(num("chapter")));

    let mut flags = Vec::new();
    for (key, prefix) in [
        ("files", "file"),
        ("items", "item"),
        ("castellans", "castellan"),
        ("requests", "request"),
    ] {
        flags.extend(nums(key).into_iter().map(|n| format!("{prefix}:{n}")));
    }
    // Пройденные главы — все до самой дальней (ступени «chN»).
    let most = progress
        .as_deref()
        .and_then(|p| p.strip_prefix("ch")?.parse::<u32>().ok())
        .unwrap_or(0);
    flags.extend((1..most).map(|n| format!("chapter:{n}")));
    flags.sort();
    flags.dedup();

    let fresh = now.duration_since(at).unwrap_or_default() <= LIVE_FRESH;
    let position = if fresh {
        v.get("player")
            .and_then(|p| serde_json::from_value::<Position>(p.clone()).ok())
    } else {
        None
    };
    GameState {
        game: content.game_id.clone(),
        source: Source::Mod,
        updated_at: time_rfc3339(at),
        progress,
        quests: Vec::new(),
        flags,
        location: num("stage").map(|s| format!("stage:{s}")),
        position,
        inventory: Vec::new(),
    }
}
