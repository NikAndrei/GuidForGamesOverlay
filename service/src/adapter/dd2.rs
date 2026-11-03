//! Dragon's Dogma 2 (Steam AppID 2054970).
//!
//! Два источника:
//! - мод-мост REFramework (`mods/dd2/guidforgames.lua`): `guidforgames_live.json` раз в 2 с
//!   (отслеживаемый квест, область, позиция) и `guidforgames_state.json` при изменениях (журнал квестов);
//! - сейв `win64_save/data0XXSlot.bin`, который разбирает утилита `tools/dd2-save` (только чтение, на копии).
//!
//! Журнал квестов берётся из более свежего источника. Живые данные (позиция, отслеживаемый квест) — только от мода.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use anyhow::{Context, Result, bail};
use serde::Deserialize;
use serde_json::Value;

use super::{Adapter, Paths, mtime, sibling_tool};
use crate::content::{Content, read_json};
use crate::state::{GameState, Position, Quest, QuestStatus, Source, time_rfc3339};

/// Папка сейвов внутри userdata/<аккаунт>/2054970.
pub const SAVE_SUB: &str = "remote/win64_save";
pub const LIVE_FILE: &str = "guidforgames_live.json";
pub const STATE_FILE: &str = "guidforgames_state.json";
/// Живой файл старше этого — игра закрыта, позицию не показываем.
const LIVE_FRESH: Duration = Duration::from_secs(30);
/// Статусы журнала квестов игры (`QuestLogSaveData.Status`).
const LOG_ACTIVE: i64 = 1;
const LOG_DONE: i64 = 2;

pub struct Dd2 {
    content: Arc<Content>,
    save_dir: Option<PathBuf>,
    mod_dir: Option<PathBuf>,
    save_tool: Option<PathBuf>,
    steam_id: Option<String>,
    work_dir: PathBuf,
    /// Разбор сейва дорогой: повторяем, только когда файл изменился.
    save_cache: Mutex<Option<(PathBuf, SystemTime, SaveData)>>,
}

/// То, что печатает dd2-save (лишние поля игнорируем).
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SaveData {
    #[serde(default)]
    pub quest_log: Vec<SaveLogQuest>,
    #[serde(default)]
    pub disabled: Vec<SaveId>,
    #[serde(default)]
    pub player: Option<Position>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SaveLogQuest {
    pub id: i64,
    pub status: i64,
    #[serde(default)]
    pub current_task: Option<i64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveId {
    pub id: i64,
}

impl Dd2 {
    pub fn new(content: Arc<Content>, paths: Paths) -> Self {
        Self {
            content,
            save_dir: paths.save_dir,
            mod_dir: paths.mod_dir,
            save_tool: paths.save_tool.or_else(|| sibling_tool("dd2-save")),
            steam_id: paths.steam_id,
            work_dir: paths.work_dir,
            save_cache: Mutex::new(None),
        }
    }

    /// Самый свежий файл слота (`data000Slot.bin` и т.п.; `data00-1.bin` — системный, без квестов).
    fn newest_slot(&self) -> Option<(PathBuf, SystemTime)> {
        let dir = self.save_dir.as_ref()?;
        fs::read_dir(dir)
            .ok()?
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().ends_with("Slot.bin"))
            .filter_map(|e| Some((e.path(), e.metadata().ok()?.modified().ok()?)))
            .max_by_key(|(_, t)| *t)
    }

    fn read_save(&self) -> Result<Option<(SaveData, SystemTime)>> {
        let Some((path, mtime)) = self.newest_slot() else {
            return Ok(None);
        };
        {
            let cache = self.save_cache.lock().unwrap();
            if let Some((p, t, data)) = cache.as_ref()
                && *p == path
                && *t == mtime
            {
                return Ok(Some((data.clone(), mtime)));
            }
        }
        let Some(tool) = &self.save_tool else {
            return Ok(None);
        };
        let steam = self
            .steam_id
            .clone()
            .or_else(|| account_from_path(&path))
            .context("не определить SteamID: укажите steam_id в config.toml")?;
        // Читаем копию: игра может писать сейв в этот момент, а оригинал мы не трогаем никогда.
        fs::create_dir_all(&self.work_dir)?;
        let copy = self.work_dir.join("dd2-slot.bin");
        fs::copy(&path, &copy).with_context(|| format!("не скопировать {}", path.display()))?;
        let out = Command::new(tool)
            .arg(&copy)
            .arg("--steamid")
            .arg(&steam)
            .output()
            .with_context(|| format!("не запустить {}", tool.display()))?;
        let stdout = String::from_utf8_lossy(&out.stdout);
        let data = parse_tool_output(&stdout).with_context(|| {
            format!(
                "dd2-save не разобрал сейв: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            )
        })?;
        *self.save_cache.lock().unwrap() = Some((path, mtime, data.clone()));
        Ok(Some((data, mtime)))
    }
}

impl Adapter for Dd2 {
    fn watch_paths(&self) -> Vec<PathBuf> {
        self.save_dir.iter().chain(&self.mod_dir).cloned().collect()
    }

    fn read(&self) -> Result<Option<GameState>> {
        let save = self.read_save()?;
        let modded = match &self.mod_dir {
            Some(dir) => read_mod(dir)?,
            None => None,
        };
        if save.is_none()
            && modded.is_none()
            && self.save_tool.is_none()
            && self.newest_slot().is_some()
        {
            bail!(
                "сейв есть, но нет dd2-save рядом с программой (или save_tool в config.toml) и мода-моста"
            );
        }
        Ok(combine(&self.content, save, modded, SystemTime::now()))
    }
}

/// Что удалось прочитать из файлов мода.
#[derive(Debug, Clone, Default)]
pub struct ModData {
    /// Журнал квестов и время файла, где он лежит.
    pub quest_log: Option<(Vec<(i64, i64)>, SystemTime)>,
    pub live: Option<LiveData>,
}

#[derive(Debug, Clone)]
pub struct LiveData {
    pub at: SystemTime,
    pub tracked: Option<i64>,
    pub progressing: Vec<i64>,
    pub position: Option<Position>,
    pub location: Option<String>,
}

pub fn read_mod(dir: &Path) -> Result<Option<ModData>> {
    let live_path = dir.join(LIVE_FILE);
    let state_path = dir.join(STATE_FILE);
    let mut out = ModData::default();
    let mut live_log = None;
    if let Some(t) = mtime(&live_path) {
        let v: Value = read_json(&live_path)?;
        let quest = v.get("quest");
        let tracked = quest
            .and_then(|q| q.get("tracked"))
            .and_then(Value::as_i64)
            .filter(|t| *t >= 0);
        let progressing = quest
            .and_then(|q| q.get("progressing"))
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_i64).collect())
            .unwrap_or_default();
        let position = v
            .get("player")
            .and_then(|p| serde_json::from_value(p.clone()).ok());
        let location = v.get("area").and_then(area_name);
        // Старые версии мода клали журнал прямо в живой файл.
        live_log = quest_log(&v).map(|l| (l, t));
        out.live = Some(LiveData {
            at: t,
            tracked,
            progressing,
            position,
            location,
        });
    }
    if let Some(t) = mtime(&state_path) {
        let v: Value = read_json(&state_path)?;
        out.quest_log = quest_log(&v).map(|l| (l, t));
    }
    if out.quest_log.is_none() {
        out.quest_log = live_log;
    }
    Ok((out.live.is_some() || out.quest_log.is_some()).then_some(out))
}

/// `{ town, local }` → `town:<n>` (а если город не задан — `local:<n>`). Числа — внутренние id областей игры.
fn area_name(v: &Value) -> Option<String> {
    let num = |k: &str| v.get(k).and_then(Value::as_i64).filter(|n| *n >= 0);
    num("town")
        .map(|n| format!("town:{n}"))
        .or_else(|| num("local").map(|n| format!("local:{n}")))
}

fn quest_log(v: &Value) -> Option<Vec<(i64, i64)>> {
    let arr = v.get("questLog")?.as_array()?;
    let log: Vec<_> = arr
        .iter()
        .filter_map(|q| Some((q.get("id")?.as_i64()?, q.get("status")?.as_i64()?)))
        .collect();
    (!log.is_empty()).then_some(log)
}

pub fn parse_tool_output(stdout: &str) -> Result<SaveData> {
    const MARK: &str = "@@DD2SAVE@@";
    let Some(line) = stdout
        .lines()
        .find_map(|l| l.split_once(MARK).map(|(_, j)| j))
    else {
        bail!("в выводе нет строки {MARK}");
    };
    Ok(serde_json::from_str(line)?)
}

pub fn account_from_path(p: &Path) -> Option<String> {
    let parts: Vec<_> = p
        .components()
        .map(|c| c.as_os_str().to_string_lossy().to_string())
        .collect();
    let i = parts
        .iter()
        .position(|s| s.eq_ignore_ascii_case("userdata"))?;
    let id = parts.get(i + 1)?;
    id.chars().all(|c| c.is_ascii_digit()).then(|| id.clone())
}

/// Свести сейв и мод в общую модель.
pub fn combine(
    content: &Content,
    save: Option<(SaveData, SystemTime)>,
    modded: Option<ModData>,
    now: SystemTime,
) -> Option<GameState> {
    if save.is_none() && modded.is_none() {
        return None;
    }
    let mut quests: BTreeMap<i64, Quest> = BTreeMap::new();
    let mut source = Source::Save;
    let mut updated = SystemTime::UNIX_EPOCH;

    let save_time = save.as_ref().map(|(_, t)| *t);
    let mod_log = modded.as_ref().and_then(|m| m.quest_log.clone());
    let use_mod_log = match (&mod_log, save_time) {
        (Some((_, mt)), Some(st)) => *mt >= st,
        (Some(_), None) => true,
        _ => false,
    };

    if let Some((data, t)) = &save {
        updated = updated.max(*t);
        if !use_mod_log {
            for q in &data.quest_log {
                if let Some(status) = log_status(q.status) {
                    quests.insert(q.id, quest(q.id, Some(status), q.current_task));
                }
            }
        }
        // Недоступные квесты знает только сейв.
        for d in &data.disabled {
            quests.insert(d.id, quest(d.id, Some(QuestStatus::Unavailable), None));
        }
    }
    if use_mod_log {
        let (log, t) = mod_log.unwrap();
        source = Source::Mod;
        updated = updated.max(t);
        for (id, st) in log {
            if quests
                .get(&id)
                .is_some_and(|q| q.status == Some(QuestStatus::Unavailable))
            {
                continue;
            }
            if let Some(status) = log_status(st) {
                quests.insert(id, quest(id, Some(status), None));
            }
        }
    }

    let mut position = save.as_ref().and_then(|(d, _)| d.player);
    let mut location = None;
    if let Some(live) = modded.and_then(|m| m.live)
        && now.duration_since(live.at).unwrap_or_default() <= LIVE_FRESH
    {
        source = Source::Mod;
        updated = updated.max(live.at);
        position = live.position.or(position);
        location = live.location;
        for id in live.progressing {
            quests
                .entry(id)
                .or_insert_with(|| quest(id, Some(QuestStatus::Active), None));
        }
        if let Some(t) = live.tracked {
            quests
                .entry(t)
                .or_insert_with(|| quest(t, Some(QuestStatus::Active), None))
                .tracked = true;
        }
    }

    // Ступень прогресса — самая дальняя среди начатых или выполненных квестов из save-map.
    let progress = quests
        .values()
        .filter(|q| matches!(q.status, Some(QuestStatus::Active | QuestStatus::Done)))
        .filter_map(|q| content.save_map.quests.get(&q.id)?.progress.as_deref())
        .filter_map(|p| content.progress_index(p))
        .max()
        .map(|i| content.progress[i].clone());

    Some(GameState {
        game: content.game_id.clone(),
        source,
        updated_at: time_rfc3339(updated),
        progress,
        quests: quests.into_values().collect(),
        flags: Vec::new(),
        location,
        position,
        inventory: Vec::new(),
    })
}

fn log_status(s: i64) -> Option<QuestStatus> {
    match s {
        LOG_ACTIVE => Some(QuestStatus::Active),
        LOG_DONE => Some(QuestStatus::Done),
        _ => None,
    }
}

fn quest(id: i64, status: Option<QuestStatus>, stage: Option<i64>) -> Quest {
    Quest {
        id: id.to_string(),
        stage,
        status,
        tracked: false,
    }
}
