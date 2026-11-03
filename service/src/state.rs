//! Общая модель состояния игры (`schemas/state.schema.json`).

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    /// Файл сохранения.
    Save,
    /// Мод-мост в игре (REFramework и т.п.).
    Mod,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum QuestStatus {
    Active,
    Done,
    Failed,
    Unavailable,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Quest {
    /// Номер квеста в игре строкой (DD2: `10050` ↔ `qu010050`).
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stage: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<QuestStatus>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub tracked: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Position {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GameState {
    pub game: String,
    pub source: Source,
    /// RFC 3339, UTC.
    pub updated_at: String,
    /// id ступени прогресса из game.json GuidForGames.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub progress: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub quests: Vec<Quest>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub flags: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub location: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub position: Option<Position>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub inventory: Vec<String>,
}

impl GameState {
    pub fn quest(&self, id: &str) -> Option<&Quest> {
        self.quests.iter().find(|q| q.id == id)
    }
}

pub fn now_rfc3339() -> String {
    humantime::format_rfc3339_seconds(std::time::SystemTime::now()).to_string()
}

pub fn time_rfc3339(t: std::time::SystemTime) -> String {
    humantime::format_rfc3339_seconds(t).to_string()
}
