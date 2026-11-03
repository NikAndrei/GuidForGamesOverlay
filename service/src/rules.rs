//! Правила подсказок (`schemas/hints.schema.json`) и их проверка по модели состояния.

use std::fs;
use std::path::Path;

use anyhow::{Context, Result};
use serde::Deserialize;

use crate::content::{Content, Name, read_json};
use crate::state::{GameState, QuestStatus};

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RuleFile {
    game: String,
    rules: Vec<Rule>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Rule {
    pub id: String,
    pub when: Condition,
    #[serde(default)]
    pub entry: Option<String>,
    #[serde(default)]
    pub title: Option<Name>,
    #[serde(default)]
    pub hints: Option<Vec<String>>,
    #[serde(default)]
    pub media: Vec<String>,
    #[serde(default)]
    pub priority: i64,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Condition {
    pub progress_at_least: Option<String>,
    pub progress_before: Option<String>,
    pub quest: Option<QuestCondition>,
    pub flag: Option<String>,
    pub no_flag: Option<String>,
    pub location: Option<String>,
    pub has_item: Option<String>,
    #[serde(default)]
    pub all: Vec<Condition>,
    #[serde(default)]
    pub any: Vec<Condition>,
    pub not: Option<Box<Condition>>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct QuestCondition {
    pub id: String,
    pub status: Option<QuestStatus>,
    pub stage: Option<i64>,
    pub stage_at_least: Option<i64>,
}

impl Condition {
    /// Все заданные поля должны выполняться. Если прогресс неизвестен, `progressAtLeast` не выполняется,
    /// а `progressBefore` выполняется: лучше показать лишний ранний намёк, чем подсказку из будущего.
    pub fn eval(&self, st: &GameState, content: &Content) -> bool {
        let cur = st
            .progress
            .as_deref()
            .and_then(|p| content.progress_index(p));
        if let Some(p) = &self.progress_at_least {
            match (cur, content.progress_index(p)) {
                (Some(c), Some(need)) if c >= need => {}
                _ => return false,
            }
        }
        if let Some(p) = &self.progress_before
            && let (Some(c), Some(limit)) = (cur, content.progress_index(p))
            && c >= limit
        {
            return false;
        }
        if let Some(q) = &self.quest {
            let Some(found) = st.quest(&q.id) else {
                return false;
            };
            if q.status.is_some() && found.status != q.status {
                return false;
            }
            if q.stage.is_some() && found.stage != q.stage {
                return false;
            }
            if let Some(min) = q.stage_at_least
                && found.stage.is_none_or(|s| s < min)
            {
                return false;
            }
        }
        if let Some(f) = &self.flag
            && !st.flags.contains(f)
        {
            return false;
        }
        if let Some(f) = &self.no_flag
            && st.flags.contains(f)
        {
            return false;
        }
        if let Some(l) = &self.location
            && st.location.as_deref() != Some(l.as_str())
        {
            return false;
        }
        if let Some(i) = &self.has_item
            && !st.inventory.contains(i)
        {
            return false;
        }
        if !self.all.iter().all(|c| c.eval(st, content)) {
            return false;
        }
        if !self.any.is_empty() && !self.any.iter().any(|c| c.eval(st, content)) {
            return false;
        }
        if let Some(n) = &self.not
            && n.eval(st, content)
        {
            return false;
        }
        true
    }

    fn progress_ids<'a>(&'a self, out: &mut Vec<&'a str>) {
        out.extend(self.progress_at_least.as_deref());
        out.extend(self.progress_before.as_deref());
        for c in self.all.iter().chain(&self.any).chain(self.not.as_deref()) {
            c.progress_ids(out);
        }
    }
}

/// Загрузить правила игры: файл или все `*.json` в папке.
pub fn load(path: &Path, game_id: &str) -> Result<Vec<Rule>> {
    let files = if path.is_dir() {
        let mut v: Vec<_> = fs::read_dir(path)
            .with_context(|| format!("не читается {}", path.display()))?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|e| e == "json"))
            .collect();
        v.sort();
        v
    } else {
        vec![path.to_path_buf()]
    };
    let mut rules = Vec::new();
    for f in files {
        let file: RuleFile = read_json(&f)?;
        if file.game != game_id {
            anyhow::bail!(
                "{}: правила для игры {}, ожидалась {}",
                f.display(),
                file.game,
                game_id
            );
        }
        rules.extend(file.rules);
    }
    Ok(rules)
}

/// Ошибки, которые не мешают работе, но означают опечатку в правилах.
pub fn check(rules: &[Rule], content: &Content) -> Vec<String> {
    let mut problems = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for r in rules {
        if !seen.insert(&r.id) {
            problems.push(format!("правило {}: повторяется id", r.id));
        }
        match &r.entry {
            Some(e) if !content.entries.contains_key(e) => {
                problems.push(format!("правило {}: нет записи {e}", r.id))
            }
            None if r.title.is_none() || r.hints.as_ref().is_none_or(|h| h.is_empty()) => {
                problems.push(format!("правило {}: нужен entry или title + hints", r.id))
            }
            _ => {}
        }
        let mut ids = Vec::new();
        r.when.progress_ids(&mut ids);
        for p in ids {
            if content.progress_index(p).is_none() {
                problems.push(format!("правило {}: нет ступени прогресса {p}", r.id));
            }
        }
    }
    problems
}
