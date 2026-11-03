//! Модель UI: что показать сейчас. Оверлей получает только раскрытые уровни подсказок,
//! так что нераскрытый спойлер не попадает в окно даже случайно.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::content::{Content, Name};
use std::collections::HashSet;

use crate::content::Entry;
use crate::rules::Rule;
use crate::state::QuestStatus;
use crate::state::{GameState, Source};

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UiModel {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub game: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<Name>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<Source>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<String>,
    pub items: Vec<UiItem>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UiItem {
    /// id записи справочника (или правила со своим текстом) — по нему оверлей раскрывает уровни.
    pub id: String,
    /// Вид: quest, secret, file, puzzle, boss, tip… — для вкладок в оверлее.
    pub kind: String,
    pub title: Name,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub location: Option<Name>,
    /// Сколько всего уровней (намёк → подробнее → ответ).
    pub levels: usize,
    /// Сколько раскрыто.
    pub revealed: usize,
    /// Тексты раскрытых уровней.
    pub hints: Vec<String>,
    /// Можно пропустить: после какой-то ступени уже не сделать.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub missable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub missable_note: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub media: Vec<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub sources: Vec<String>,
}

/// Сколько уровней раскрыто: игра → подсказка → число.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Reveals(pub BTreeMap<String, BTreeMap<String, usize>>);

impl Reveals {
    pub fn get(&self, game: &str, rule: &str) -> usize {
        self.0
            .get(game)
            .and_then(|g| g.get(rule))
            .copied()
            .unwrap_or(0)
    }

    pub fn set(&mut self, game: &str, rule: &str, n: usize) {
        let g = self.0.entry(game.to_string()).or_default();
        if n == 0 {
            g.remove(rule);
        } else {
            g.insert(rule.to_string(), n);
        }
    }
}

/// Записи, которые уже сделаны или стали недоступны: по флагам (`gameRefs`) и квестам игры (save-map.json).
pub fn closed_entries<'a>(state: &GameState, content: &'a Content) -> HashSet<&'a str> {
    let flags: HashSet<&str> = state.flags.iter().map(String::as_str).collect();
    let mut out: HashSet<&str> = content
        .entries
        .values()
        .filter(|e| e.game_refs.iter().any(|r| flags.contains(r.as_str())))
        .map(|e| e.id.as_str())
        .collect();
    for q in &state.quests {
        if matches!(q.status, Some(QuestStatus::Done | QuestStatus::Unavailable))
            && let Some(e) = content
                .save_map
                .quests
                .get(&q.id)
                .and_then(|m| m.entry.as_deref())
            && let Some(entry) = content.entries.get(e)
        {
            out.insert(entry.id.as_str());
        }
    }
    out
}

/// Запись можно показывать: ступень достигнута и момент ещё не упущен.
fn entry_open(e: &Entry, cur: Option<usize>, content: &Content) -> bool {
    let idx = |s: &Option<String>| s.as_deref().and_then(|a| content.progress_index(a));
    let reached = match idx(&e.available_from) {
        Some(need) => cur.is_some_and(|c| c >= need),
        None => true,
    };
    let missed = match idx(&e.missable_after) {
        Some(limit) => cur.is_some_and(|c| c >= limit),
        None => false,
    };
    reached && !missed
}

/// Подходящие подсказки: правила по убыванию приоритета (при равном — в порядке файлов),
/// одна запись — один раз (у правила с большим приоритетом).
pub fn build(state: &GameState, content: &Content, rules: &[Rule], reveals: &Reveals) -> UiModel {
    let cur = state
        .progress
        .as_deref()
        .and_then(|p| content.progress_index(p));
    let closed = closed_entries(state, content);
    let mut active: Vec<&Rule> = rules
        .iter()
        .filter(|r| r.when.eval(state, content))
        .collect();
    active.sort_by_key(|r| std::cmp::Reverse(r.priority));

    let mut seen: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    let mut push = |id: &str,
                    kind: &str,
                    title: &Name,
                    location: Option<&Name>,
                    hints: &[String],
                    entry: Option<&Entry>,
                    rule: &Rule| {
        if hints.is_empty() || !seen.insert(id.to_string()) {
            return;
        }
        let revealed = reveals.get(&state.game, id).min(hints.len());
        items.push(UiItem {
            id: id.to_string(),
            kind: kind.to_string(),
            title: title.clone(),
            location: location.cloned(),
            levels: hints.len(),
            revealed,
            hints: hints[..revealed].to_vec(),
            missable: entry.is_some_and(|e| e.missable_after.is_some()),
            missable_note: entry.and_then(|e| e.missable_note.clone()),
            media: if revealed > 0 {
                rule.media.clone()
            } else {
                Vec::new()
            },
            sources: entry.map(|e| e.sources.clone()).unwrap_or_default(),
        });
    };
    for rule in active {
        let ids: Vec<&str> = match (&rule.entry, &rule.select) {
            (Some(e), _) => vec![e.as_str()],
            (None, Some(sel)) => sel.entries(state, content),
            (None, None) => {
                if let (Some(title), Some(hints)) = (&rule.title, &rule.hints) {
                    push(
                        &rule.id,
                        rule.kind.as_deref().unwrap_or("tip"),
                        title,
                        None,
                        hints,
                        None,
                        rule,
                    );
                }
                continue;
            }
        };
        for id in ids {
            let Some(e) = content.entries.get(id) else {
                continue;
            };
            // Запись, скрытая до своей ступени, скрыта и здесь — даже если правило написано с ошибкой.
            if closed.contains(id) || !entry_open(e, cur, content) {
                continue;
            }
            let title = rule.title.as_ref().unwrap_or(&e.title);
            let hints = rule.hints.as_deref().unwrap_or(&e.hints);
            let kind = rule.kind.as_deref().unwrap_or(&e.kind);
            push(
                &e.id,
                kind,
                title,
                e.location.as_ref(),
                hints,
                Some(e),
                rule,
            );
        }
    }
    UiModel {
        game: Some(state.game.clone()),
        title: Some(content.title.clone()),
        source: Some(state.source),
        updated_at: Some(state.updated_at.clone()),
        items,
    }
}
