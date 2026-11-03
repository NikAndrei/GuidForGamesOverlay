//! Модель UI: что показать сейчас. Оверлей получает только раскрытые уровни подсказок,
//! так что нераскрытый спойлер не попадает в окно даже случайно.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::content::{Content, Name};
use crate::rules::Rule;
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
    /// id правила — по нему оверлей раскрывает уровни.
    pub id: String,
    pub title: Name,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub location: Option<Name>,
    /// Сколько всего уровней (намёк → подробнее → ответ).
    pub levels: usize,
    /// Сколько раскрыто.
    pub revealed: usize,
    /// Тексты раскрытых уровней.
    pub hints: Vec<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub media: Vec<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub sources: Vec<String>,
}

/// Сколько уровней раскрыто: игра → правило → число.
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

/// Текст подсказки для правила: своя лестница или запись GuidForGames.
pub struct Card<'a> {
    pub title: &'a Name,
    pub location: Option<&'a Name>,
    pub hints: &'a [String],
    pub sources: &'a [String],
    pub available_from: Option<&'a str>,
}

pub fn card<'a>(rule: &'a Rule, content: &'a Content) -> Option<Card<'a>> {
    let entry = rule.entry.as_ref().and_then(|e| content.entries.get(e));
    let title = rule.title.as_ref().or(entry.map(|e| &e.title))?;
    let hints = rule
        .hints
        .as_deref()
        .or(entry.map(|e| e.hints.as_slice()))?;
    if hints.is_empty() {
        return None;
    }
    Some(Card {
        title,
        location: entry.and_then(|e| e.location.as_ref()),
        hints,
        sources: entry.map(|e| e.sources.as_slice()).unwrap_or(&[]),
        available_from: entry.and_then(|e| e.available_from.as_deref()),
    })
}

/// Подходящие правила по убыванию приоритета (при равном — в порядке файлов).
pub fn build(state: &GameState, content: &Content, rules: &[Rule], reveals: &Reveals) -> UiModel {
    let cur = state
        .progress
        .as_deref()
        .and_then(|p| content.progress_index(p));
    let mut picked: Vec<(&Rule, Card)> = rules
        .iter()
        .filter(|r| r.when.eval(state, content))
        .filter_map(|r| card(r, content).map(|c| (r, c)))
        // Запись, скрытая до своей ступени в GuidForGames, скрыта и здесь — даже если правило написано с ошибкой.
        .filter(
            |(_, c)| match c.available_from.and_then(|a| content.progress_index(a)) {
                Some(need) => cur.is_some_and(|c| c >= need),
                None => true,
            },
        )
        .collect();
    picked.sort_by_key(|(r, _)| std::cmp::Reverse(r.priority));
    let items = picked
        .into_iter()
        .map(|(r, c)| {
            let revealed = reveals.get(&state.game, &r.id).min(c.hints.len());
            UiItem {
                id: r.id.clone(),
                title: c.title.clone(),
                location: c.location.cloned(),
                levels: c.hints.len(),
                revealed,
                hints: c.hints[..revealed].to_vec(),
                media: if revealed > 0 {
                    r.media.clone()
                } else {
                    Vec::new()
                },
                sources: c.sources.to_vec(),
            }
        })
        .collect();
    UiModel {
        game: Some(state.game.clone()),
        title: Some(content.title.clone()),
        source: Some(state.source),
        updated_at: Some(state.updated_at.clone()),
        items,
    }
}
