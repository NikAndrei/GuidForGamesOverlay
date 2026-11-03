//! Наблюдатель за папками сейвов и мода. Debounce: игра пишет сейв в несколько приёмов,
//! а мод — каждые 2 секунды, поэтому события копятся и разбираются пачкой.

use std::path::PathBuf;
use std::time::Duration;

use notify_debouncer_mini::notify::RecursiveMode;
use notify_debouncer_mini::{DebounceEventResult, new_debouncer};
use tokio::sync::mpsc;

use crate::app::App;

const DEBOUNCE: Duration = Duration::from_millis(700);
/// Запасной опрос: папка могла появиться после запуска (игру поставили, мод установили).
const POLL: Duration = Duration::from_secs(30);

pub fn spawn(app: App) {
    let (tx, mut rx) = mpsc::unbounded_channel::<usize>();
    let paths = app.watch_paths();

    // notify работает в своём потоке; отдаём номера игр в async-часть.
    let watched: Vec<(usize, PathBuf)> = paths.clone();
    std::thread::spawn(move || {
        let tx2 = tx.clone();
        let mut debouncer = match new_debouncer(DEBOUNCE, move |res: DebounceEventResult| {
            let Ok(events) = res else { return };
            let mut games: Vec<usize> = events
                .iter()
                .filter_map(|e| {
                    watched
                        .iter()
                        .find(|(_, p)| e.path.starts_with(p))
                        .map(|(i, _)| *i)
                })
                .collect();
            games.sort();
            games.dedup();
            for g in games {
                let _ = tx2.send(g);
            }
        }) {
            Ok(d) => d,
            Err(e) => {
                eprintln!("наблюдатель не запустился: {e}");
                return;
            }
        };
        let mut pending: Vec<PathBuf> = paths.iter().map(|(_, p)| p.clone()).collect();
        loop {
            pending.retain(
                |p| match debouncer.watcher().watch(p, RecursiveMode::NonRecursive) {
                    Ok(()) => {
                        eprintln!("слежу за {}", p.display());
                        false
                    }
                    Err(_) => true,
                },
            );
            std::thread::sleep(POLL);
            // Опрос раз в POLL — на случай пропущенных событий (сетевые диски и т.п.).
            let mut games: Vec<usize> = paths.iter().map(|(i, _)| *i).collect();
            games.dedup();
            for i in games {
                let _ = tx.send(i);
            }
        }
    });

    tokio::spawn(async move {
        while let Some(i) = rx.recv().await {
            app.refresh(i).await;
        }
    });
}
