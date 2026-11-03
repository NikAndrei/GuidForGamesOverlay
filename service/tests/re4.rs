use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use gfg_service::adapter::re4::read_live;
use gfg_service::content::Content;
use gfg_service::rules;
use gfg_service::state::Source;
use gfg_service::ui::{self, Reveals};

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

#[test]
fn live_file_to_state_and_ui() {
    let c = Content::load(&fixtures().join("games/re4-remake")).unwrap();
    let st = read_live(&c, &fixtures().join("re4-mod"), SystemTime::now())
        .unwrap()
        .unwrap();
    assert_eq!(st.source, Source::Mod);
    assert_eq!(st.progress.as_deref(), Some("ch2"));
    assert_eq!(st.location.as_deref(), Some("stage:40100"));
    assert_eq!(st.flags, ["chapter:1", "item:123", "item:999"]);

    let r = rules::load(&c.rules_path(), &c.game_id).unwrap();
    assert!(rules::check(&r, &c).is_empty());
    let model = ui::build(&st, &c, &r, &Reveals::default());
    let ids: Vec<_> = model.items.iter().map(|i| i.id.as_str()).collect();
    // Кольцо уже подобрано (item:123), глава 1 пройдена.
    assert_eq!(ids, ["wv-ch2", "file-note"]);
    assert_eq!(model.items[1].kind, "file");
}

#[test]
fn stale_live_file_keeps_progress_but_not_position() {
    let c = Content::load(&fixtures().join("games/re4-remake")).unwrap();
    let later = SystemTime::now() + Duration::from_secs(600);
    let st = read_live(&c, &fixtures().join("re4-mod"), later)
        .unwrap()
        .unwrap();
    assert!(st.position.is_none());
    assert_eq!(st.progress.as_deref(), Some("ch2"));
}

#[test]
fn no_mod_dir_means_no_state() {
    let c = Content::load(&fixtures().join("games/re4-remake")).unwrap();
    let dir = tempfile::tempdir().unwrap();
    assert!(
        read_live(&c, dir.path(), SystemTime::now())
            .unwrap()
            .is_none()
    );
}
