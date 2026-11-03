//! Установка модов-мостов REFramework в найденные игры: `gfg-service install-mods`.

use std::fs;
use std::path::Path;

use anyhow::Result;

use crate::adapter::{self, Paths};
use crate::config::Config;
use crate::content::{self, Content};
use crate::steam;

/// Мод для адаптера: файл в `mods/<папка>/guidforgames.lua`.
fn mod_folder(adapter: &str) -> Option<&'static str> {
    match adapter {
        "dd2" => Some("dd2"),
        "re4" => Some("re4"),
        _ => None,
    }
}

/// Копирует мод в `<игра>/reframework/autorun/`. Сама игра и REFramework не меняются;
/// если REFramework не установлен — только сообщение.
pub fn install_mods(cfg: &Config) -> Result<()> {
    let roots = steam::roots(cfg.steam_dir.as_deref());
    let mods_dir = cfg
        .games_dir()
        .parent()
        .unwrap_or(Path::new("."))
        .join("mods");
    for dir in content::discover(cfg.games_dir())? {
        let c = Content::load(&dir)?;
        let name = c.adapter.clone().unwrap_or_default();
        let Some(folder) = mod_folder(&name) else {
            continue;
        };
        let gc = cfg.games.get(&c.game_id).cloned().unwrap_or_default();
        let paths = Paths::resolve(
            &c,
            &gc,
            &roots,
            adapter::save_sub(&name),
            Default::default(),
        );
        let title = &c.title.ru;
        let Some(game_dir) = paths.game_dir else {
            println!("{title}: игра не найдена в Steam (можно указать game_dir в config.toml)");
            continue;
        };
        let rf = game_dir.join("reframework");
        if !rf.is_dir() {
            println!(
                "{title}: REFramework не установлен в {} — сначала поставьте его (dinput8.dll в папку игры)",
                game_dir.display()
            );
            continue;
        }
        let src = mods_dir.join(folder).join("guidforgames.lua");
        let dst_dir = rf.join("autorun");
        fs::create_dir_all(&dst_dir)?;
        let dst = dst_dir.join("guidforgames.lua");
        fs::copy(&src, &dst)?;
        println!("{title}: мод установлен → {}", dst.display());
    }
    Ok(())
}
