//! Поиск Steam, библиотек и установленных игр — чтобы приложение работало без настройки путей.

use std::fs;
use std::path::{Path, PathBuf};

/// Папки Steam: переменная STEAM_DIR, реестр Windows, обычные места установки.
pub fn roots(configured: Option<&Path>) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = Vec::new();
    out.extend(configured.map(Path::to_path_buf));
    out.extend(std::env::var_os("STEAM_DIR").map(PathBuf::from));
    out.extend(registry_steam_path());
    for p in [r"C:\Program Files (x86)\Steam", r"C:\Program Files\Steam"] {
        out.push(PathBuf::from(p));
    }
    if let Some(home) = std::env::var_os("HOME") {
        out.push(Path::new(&home).join(".local/share/Steam"));
        out.push(Path::new(&home).join(".steam/steam"));
    }
    let mut seen = Vec::new();
    out.retain(|p| {
        let ok = p.join("steamapps").is_dir() && !seen.contains(p);
        if ok {
            seen.push(p.clone());
        }
        ok
    });
    out
}

#[cfg(windows)]
fn registry_steam_path() -> Option<PathBuf> {
    let out = std::process::Command::new("reg")
        .args(["query", r"HKCU\Software\Valve\Steam", "/v", "SteamPath"])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    let line = text.lines().find(|l| l.contains("SteamPath"))?;
    let value = line.split("REG_SZ").nth(1)?.trim();
    Some(PathBuf::from(value.replace('/', "\\")))
}

#[cfg(not(windows))]
fn registry_steam_path() -> Option<PathBuf> {
    None
}

/// Библиотеки Steam: сама папка Steam и пути из steamapps/libraryfolders.vdf.
pub fn libraries(root: &Path) -> Vec<PathBuf> {
    let mut out = vec![root.to_path_buf()];
    if let Ok(text) = fs::read_to_string(root.join("steamapps/libraryfolders.vdf")) {
        out.extend(vdf_values(&text, "path").into_iter().map(PathBuf::from));
    }
    out.dedup();
    out
}

/// Значения ключа из текстового VDF: строки вида `"key"  "value"` (экранирование `\\` снимается).
pub fn vdf_values(text: &str, key: &str) -> Vec<String> {
    let want = format!("\"{key}\"");
    text.lines()
        .filter_map(|l| {
            let l = l.trim();
            let rest = l.strip_prefix(&want)?.trim();
            let v = rest.strip_prefix('"')?.strip_suffix('"')?;
            Some(v.replace("\\\\", "\\"))
        })
        .collect()
}

/// Папка установленной игры по AppID.
pub fn game_dir(roots: &[PathBuf], app_id: u32) -> Option<PathBuf> {
    for root in roots {
        for lib in libraries(root) {
            let manifest = lib.join(format!("steamapps/appmanifest_{app_id}.acf"));
            let Ok(text) = fs::read_to_string(&manifest) else {
                continue;
            };
            if let Some(dir) = vdf_values(&text, "installdir").into_iter().next() {
                let p = lib.join("steamapps/common").join(dir);
                if p.is_dir() {
                    return Some(p);
                }
            }
        }
    }
    None
}

/// `userdata/<аккаунт>/<AppID>/<sub>` всех аккаунтов; первым — изменённый последним.
pub fn userdata_dirs(roots: &[PathBuf], app_id: u32, sub: &str) -> Vec<PathBuf> {
    let mut found: Vec<(PathBuf, std::time::SystemTime)> = Vec::new();
    for root in roots {
        let Ok(rd) = fs::read_dir(root.join("userdata")) else {
            continue;
        };
        for acc in rd.filter_map(|e| e.ok()) {
            let p = acc.path().join(app_id.to_string()).join(sub);
            if let Ok(m) = fs::metadata(&p).and_then(|m| m.modified()) {
                found.push((p, m));
            }
        }
    }
    found.sort_by_key(|f| std::cmp::Reverse(f.1));
    found.into_iter().map(|(p, _)| p).collect()
}
