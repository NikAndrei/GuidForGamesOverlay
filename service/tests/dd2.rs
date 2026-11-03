use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use gfg_service::adapter::dd2::{
    SaveData, SaveId, SaveLogQuest, account_from_path, combine, parse_tool_output, read_mod,
};
use gfg_service::app::App;
use gfg_service::config::Config;
use gfg_service::content::Content;
use gfg_service::rules;
use gfg_service::state::{QuestStatus, Source};
use gfg_service::ui::{self, Reveals};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

fn content() -> Content {
    Content::load(&fixtures().join("games/dragons-dogma-2")).unwrap()
}

/// Копия файлов мода во временной папке: время изменения — «сейчас», как у работающей игры.
fn fresh_mod() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    for f in ["guidforgames_live.json", "guidforgames_state.json"] {
        fs::copy(fixtures().join("dd2-mod").join(f), dir.path().join(f)).unwrap();
    }
    dir
}

#[test]
fn content_and_rules_load() {
    let c = content();
    assert_eq!(c.game_id, "dragons-dogma-2");
    assert_eq!(c.progress.len(), 4);
    assert_eq!(c.entries.len(), 4);
    assert_eq!(c.adapter.as_deref(), Some("dd2"));
    let r = rules::load(&c.rules_path(), &c.game_id).unwrap();
    assert_eq!(r.len(), 6);
    assert!(rules::check(&r, &c).is_empty());
}

#[test]
fn rules_check_finds_typos() {
    let c = content();
    let r: serde_json::Value = serde_json::json!({
        "game": "dragons-dogma-2",
        "rules": [
            { "id": "a", "when": { "progressAtLeast": "nope" }, "entry": "missing" },
            { "id": "a", "when": {}, "title": { "ru": "x" } }
        ]
    });
    let dir = tempfile::tempdir().unwrap();
    let f = dir.path().join("r.json");
    fs::write(&f, r.to_string()).unwrap();
    let problems = rules::check(&rules::load(&f, &c.game_id).unwrap(), &c);
    assert_eq!(problems.len(), 4, "{problems:?}");
}

#[test]
fn mod_state_to_ui() {
    let c = content();
    let dir = fresh_mod();
    let m = read_mod(dir.path()).unwrap().unwrap();
    let st = combine(&c, None, Some(m), SystemTime::now()).unwrap();
    assert_eq!(st.source, Source::Mod);
    assert_eq!(st.progress.as_deref(), Some("in-dragons-wake"));
    assert_eq!(st.location.as_deref(), Some("town:3"));
    assert!(st.position.is_some());
    let wake = st.quest("10060").unwrap();
    assert!(wake.tracked);
    assert_eq!(wake.status, Some(QuestStatus::Active));
    assert_eq!(st.quest("10050").unwrap().status, Some(QuestStatus::Done));
    // Статус 0 (не начат) в модель не попадает.
    assert!(st.quest("20010").is_none());

    let rules = rules::load(&c.rules_path(), &c.game_id).unwrap();
    let mut reveals = Reveals::default();
    let model = ui::build(&st, &c, &rules, &reveals);
    let ids: Vec<_> = model.items.iter().map(|i| i.id.as_str()).collect();
    // Отслеживаемый квест (приоритет 100) один раз, хотя его выбирает и правило wake;
    // tales выполнен; sovran скрыт по availableFrom записи.
    assert_eq!(ids, ["mq-in-dragons-wake", "sq-missable", "own-text"]);
    assert!(model.items.iter().all(|i| i.hints.is_empty()));
    assert_eq!(model.items[0].levels, 3);
    assert_eq!(model.items[0].kind, "quest");
    assert!(model.items[1].missable);
    assert_eq!(model.items[2].kind, "tip");

    reveals.set(&st.game, "mq-in-dragons-wake", 2);
    let model = ui::build(&st, &c, &rules, &reveals);
    assert_eq!(model.items[0].hints, ["Намёк 2", "Подробнее 2"]);
}

#[test]
fn stale_live_file_is_ignored() {
    let c = content();
    let dir = fresh_mod();
    let m = read_mod(dir.path()).unwrap().unwrap();
    let later = SystemTime::now() + Duration::from_secs(120);
    let st = combine(&c, None, Some(m), later).unwrap();
    assert!(st.position.is_none());
    assert!(st.location.is_none());
    assert!(!st.quest("10060").unwrap().tracked);
    // Журнал из state-файла остаётся.
    assert_eq!(st.progress.as_deref(), Some("in-dragons-wake"));
}

#[test]
fn newer_save_wins_and_knows_unavailable() {
    let c = content();
    let dir = fresh_mod();
    let m = read_mod(dir.path()).unwrap().unwrap();
    let save = SaveData {
        quest_log: vec![
            SaveLogQuest {
                id: 10050,
                status: 1,
                current_task: Some(2),
            },
            SaveLogQuest {
                id: 10060,
                status: 0,
                current_task: None,
            },
        ],
        disabled: vec![SaveId { id: 20020 }],
        player: None,
    };
    let save_time = SystemTime::now() + Duration::from_secs(5);
    let st = combine(&c, Some((save, save_time)), Some(m), save_time).unwrap();
    let tales = st.quest("10050").unwrap();
    assert_eq!(tales.status, Some(QuestStatus::Active));
    assert_eq!(tales.stage, Some(2));
    assert_eq!(
        st.quest("20020").unwrap().status,
        Some(QuestStatus::Unavailable)
    );
    // Живой файл свежий: отслеживаемый квест от мода добавлен поверх сейва.
    assert!(st.quest("10060").unwrap().tracked);
}

#[test]
fn tool_output_and_account() {
    let out = "debug noise\n@@DD2SAVE@@{\"file\":\"x\",\"questLog\":[{\"id\":10050,\"status\":2,\"currentTask\":null,\"completedTasks\":[]}],\"disabled\":[],\"player\":{\"x\":1,\"y\":2,\"z\":3}}\n";
    let d = parse_tool_output(out).unwrap();
    assert_eq!(d.quest_log.len(), 1);
    assert!(parse_tool_output("nothing").is_err());
    let p = Path::new("C:/Steam/userdata/123456/2054970/remote/win64_save/data000Slot.bin");
    assert_eq!(account_from_path(p).as_deref(), Some("123456"));
    assert_eq!(account_from_path(Path::new("/tmp/data000Slot.bin")), None);
}

#[tokio::test]
async fn overlay_protocol_end_to_end() {
    let dir = tempfile::tempdir().unwrap();
    let mod_dir = fresh_mod();
    let fx = fixtures();
    let cfg_text = format!(
        "games_dir = {:?}\nsteam_dir = {:?}\n\n[games.dragons-dogma-2]\nmod_dir = {:?}\n\n[games.re4-remake]\nenabled = false\n",
        fx.join("games"),
        dir.path(),
        mod_dir.path()
    );
    let cfg_path = dir.path().join("config.toml");
    fs::write(&cfg_path, cfg_text).unwrap();
    let cfg = Config::load(Some(&cfg_path)).unwrap();
    let app = App::new(&cfg).unwrap();
    app.refresh_all().await;

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    drop(listener);
    tokio::spawn(gfg_service::overlay::serve(app.clone(), addr));
    let stream = loop {
        if let Ok(s) = tokio::net::TcpStream::connect(addr).await {
            break s;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    };
    let (r, mut w) = stream.into_split();
    let mut lines = BufReader::new(r).lines();
    let mut next = async || -> serde_json::Value {
        serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap()
    };
    assert_eq!(next().await["type"], "hello");
    let ui = next().await;
    assert_eq!(ui["ui"]["items"][0]["id"], "mq-in-dragons-wake");
    assert_eq!(ui["ui"]["items"][0]["revealed"], 0);

    w.write_all(b"{\"cmd\":\"reveal\",\"item\":\"mq-in-dragons-wake\"}\n")
        .await
        .unwrap();
    let ui = next().await;
    assert_eq!(ui["ui"]["items"][0]["hints"][0], "Намёк 2");

    w.write_all(b"{\"cmd\":\"reveal\",\"item\":\"nope\"}\n")
        .await
        .unwrap();
    assert_eq!(next().await["type"], "error");

    // Раскрытое сохраняется на диск.
    let saved = fs::read_to_string(dir.path().join("state/reveals.json")).unwrap();
    assert!(saved.contains("\"mq-in-dragons-wake\": 1"));
}
