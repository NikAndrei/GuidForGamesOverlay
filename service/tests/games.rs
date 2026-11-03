//! Настоящие данные игр из `games/`: всё загружается, в правилах нет опечаток, подсказки находятся.

use std::path::{Path, PathBuf};

use gfg_service::content::{Content, discover};
use gfg_service::rules;
use gfg_service::state::{GameState, Quest, QuestStatus, Source};
use gfg_service::steam::vdf_values;
use gfg_service::ui::{self, Reveals};

fn games_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../games")
}

fn state(game: &str, progress: &str) -> GameState {
    GameState {
        game: game.into(),
        source: Source::Mod,
        updated_at: "2026-11-03T00:00:00Z".into(),
        progress: Some(progress.into()),
        quests: Vec::new(),
        flags: Vec::new(),
        location: None,
        position: None,
        inventory: Vec::new(),
    }
}

#[test]
fn all_games_load_without_problems() {
    let dirs = discover(&games_dir()).unwrap();
    assert!(dirs.len() >= 2);
    for d in dirs {
        let c = Content::load(&d).unwrap();
        assert!(c.adapter.is_some(), "{}: нет adapter", c.game_id);
        assert!(c.steam_app_id.is_some(), "{}: нет steamAppId", c.game_id);
        let r = rules::load(&c.rules_path(), &c.game_id).unwrap();
        let problems = rules::check(&r, &c);
        assert!(problems.is_empty(), "{}: {problems:?}", c.game_id);
        for e in c.entries.values() {
            for s in [&e.available_from, &e.missable_after].into_iter().flatten() {
                assert!(c.progress_index(s).is_some(), "{}: нет ступени {s}", e.id);
            }
        }
    }
}

#[test]
fn re4_chapter_has_hints() {
    let c = Content::load(&games_dir().join("re4-remake")).unwrap();
    let r = rules::load(&c.rules_path(), &c.game_id).unwrap();
    let model = ui::build(&state("re4-remake", "ch3"), &c, &r, &Reveals::default());
    assert!(model.items.iter().any(|i| i.kind == "quest"));
    assert!(model.items.iter().any(|i| i.kind == "secret"));
    // Ничего из будущих глав.
    let ch3 = c.progress_index("ch3").unwrap();
    for i in &model.items {
        let e = &c.entries[&i.id];
        let need = e
            .available_from
            .as_deref()
            .and_then(|a| c.progress_index(a))
            .unwrap_or(0);
        assert!(need <= ch3, "{} из будущего", i.id);
    }
}

#[test]
fn dd2_tracked_quest_first() {
    let c = Content::load(&games_dir().join("dragons-dogma-2")).unwrap();
    let r = rules::load(&c.rules_path(), &c.game_id).unwrap();
    let mut st = state("dragons-dogma-2", "in-dragons-wake");
    st.quests = vec![Quest {
        id: "10060".into(),
        stage: None,
        status: Some(QuestStatus::Active),
        tracked: true,
    }];
    let model = ui::build(&st, &c, &r, &Reveals::default());
    assert_eq!(model.items[0].id, "mq-in-dragons-wake");
}

#[test]
fn vdf_parsing() {
    let vdf = r#"
"libraryfolders"
{
	"0"
	{
		"path"		"C:\\Program Files (x86)\\Steam"
	}
	"1"
	{
		"path"		"D:\\SteamLibrary"
	}
}"#;
    assert_eq!(
        vdf_values(vdf, "path"),
        [r"C:\Program Files (x86)\Steam", r"D:\SteamLibrary"]
    );
}
