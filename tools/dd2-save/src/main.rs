//! dd2-save — читает сохранение Dragon's Dogma 2 и печатает состояние квестов в JSON.
//!
//! Кроме квестов печатает позицию игрока (для карты), пешек с уровнем драконьей чумы,
//! симпатию NPC, подобранные жетоны искателя и маску исследованного на карте.
//!
//! Использование:  dd2-save <файл.bin> [--steamid <SteamID64 или номер аккаунта>]
//! Без --steamid номер аккаунта берётся из пути (…\userdata\<номер>\2054970\…).
//! Файл только читается. Имена полей ищутся по murmur3-хешам, схема типов не нужна.

use ree_lib::save::{
    SaveFile, SaveOptions,
    game::Game,
    types::{Class, FieldValue},
};
use serde_json::{Value, json};

const STEAM_ID_BASE: u64 = 0x0110000100000000;

fn h(name: &str) -> u32 {
    util::murmur3(name, 0xffffffff)
}

fn field<'a>(c: &'a Class, name: &str) -> Option<&'a FieldValue> {
    let hash = h(name);
    c.fields.iter().find(|f| f.hash == hash).map(|f| &f.value)
}

fn num(v: Option<&FieldValue>) -> Option<i64> {
    match v? {
        FieldValue::S8(x) => Some(*x as i64),
        FieldValue::S16(x) => Some(*x as i64),
        FieldValue::S32(x) => Some(*x as i64),
        FieldValue::S64(x) => Some(*x),
        FieldValue::U8(x) => Some(*x as i64),
        FieldValue::U16(x) => Some(*x as i64),
        FieldValue::U32(x) => Some(*x as i64),
        FieldValue::U64(x) => Some(*x as i64),
        FieldValue::Enum(e) => Some(e.as_i64()),
        _ => None,
    }
}

fn nums(v: Option<&FieldValue>) -> Vec<i64> {
    match v {
        Some(FieldValue::Array(a)) => a.values.iter().filter_map(|x| num(Some(x))).collect(),
        _ => vec![],
    }
}

#[derive(Default)]
struct Out {
    contexts: Vec<Value>,
    log: Vec<Value>,
    disabled: Vec<Value>,
    /// Позиция игрока на момент сохранения: мировые координаты (x, y — высота, z).
    player: Option<[f64; 3]>,
    /// Пешки: имя, главная ли, уровень драконьей чумы (Possession — внутреннее название).
    pawns: Vec<Value>,
    /// Симпатия NPC: CharaID → значение (0…300, в игре не показывается).
    sentiments: Vec<Value>,
    /// Подобранные жетоны искателя: уникальные id объектов (GimmickManager.It000078Array).
    seeker_tokens: Vec<String>,
    /// Маска исследованного на карте (туман войны): app.GuiManager.MapMaskSaveData.
    map_masks: Vec<Value>,
}

fn text(v: Option<&FieldValue>) -> Option<String> {
    match v? {
        FieldValue::String(st) => Some(
            String::from_utf16_lossy(&st.0)
                .trim_end_matches('\0')
                .to_string(),
        ),
        _ => None,
    }
}

fn float(v: Option<&FieldValue>) -> Option<f64> {
    match v? {
        FieldValue::F32(x) => Some(*x as f64),
        FieldValue::F64(x) => Some(*x),
        _ => num(v).map(|x| x as f64),
    }
}

/// app.UniqueID: _RowID (16 байт) + _Index → строка «hex:index».
fn unique_id(v: &FieldValue) -> Option<String> {
    let FieldValue::Class(c) = v else { return None };
    let FieldValue::Struct(row) = field(c, "_RowID")? else {
        return None;
    };
    let hex: String = row.data.iter().map(|b| format!("{b:02x}")).collect();
    Some(format!("{hex}:{}", num(field(c, "_Index")).unwrap_or(0)))
}

fn base64(bytes: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |acc, (i, b)| acc | (*b as u32) << (16 - 8 * i));
        for i in 0..4 {
            out.push(if i <= chunk.len() {
                T[(n >> (18 - 6 * i) & 63) as usize] as char
            } else {
                '='
            });
        }
    }
    out
}

/// via.Int2 (две i32) из сырой структуры.
fn int2(v: Option<&FieldValue>) -> Option<[i32; 2]> {
    let FieldValue::Struct(st) = v? else {
        return None;
    };
    if st.data.len() != 8 {
        return None;
    }
    let i = |k: usize| i32::from_le_bytes(st.data[k * 4..k * 4 + 4].try_into().unwrap());
    Some([i(0), i(1)])
}

/// Маска исследованного: MaskBit — u32, по строкам с севера (−z) на юг, биты с запада (−x), младший бит первым;
/// клетка — 16 м. AreaNo −1 — весь мир (BasePos −4096, DispRange 8192), остальные — локальные области.
fn map_mask(c: &Class, out: &mut Out) {
    let Some(FieldValue::Array(a)) = field(c, "MaskBit") else {
        return;
    };
    let (Some(base), Some(range), Some(area)) = (
        int2(field(c, "BasePos")),
        int2(field(c, "DispRange")),
        num(field(c, "AreaNo")),
    ) else {
        return;
    };
    let words: Vec<u32> = a
        .values
        .iter()
        .map(|v| num(Some(v)).unwrap_or(0) as u32)
        .collect();
    if area != -1 && words.iter().all(|w| *w == 0) {
        return;
    }
    let bytes: Vec<u8> = words.iter().flat_map(|w| w.to_le_bytes()).collect();
    out.map_masks
        .push(json!({ "area": area, "base": base, "range": range, "bits": base64(&bytes) }));
}

/// Запись базы контекстов с пешкой: PawnDataContext (+ MainPawnDataContext у главной пешки).
fn pawn(c: &Class, out: &mut Out) {
    let Some(FieldValue::Array(a)) = field(c, "Contexts") else {
        return;
    };
    let classes: Vec<&Class> = a
        .values
        .iter()
        .filter_map(|v| {
            if let FieldValue::Class(c) = v {
                Some(c.as_ref())
            } else {
                None
            }
        })
        .collect();
    let Some(p) = classes.iter().find(|c| field(c, "_PossessionLv").is_some()) else {
        return;
    };
    let main = classes
        .iter()
        .find(|c| field(c, "_FavorabilityRating").is_some());
    out.pawns.push(json!({
        "name": text(field(p, "_Name")), "nickname": text(field(p, "_Nickname")),
        "searchId": text(field(p, "_SearchId")).filter(|s| !s.is_empty()),
        "main": main.is_some(),
        "affinity": main.and_then(|m| float(field(m, "_FavorabilityRating"))),
        "possessionLv": num(field(p, "_PossessionLv")), "possessionPoint": num(field(p, "_PossessionProgressPoint")),
    }));
}

fn walk(c: &Class, out: &mut Out) {
    pawn(c, out);
    map_mask(c, out);
    // app.NPCManager.NPCSaveSentiment: CharaID, Value
    if let (Some(id), Some(v)) = (num(field(c, "CharaID")), num(field(c, "Value"))) {
        if field(c, "ValueTemp").is_some() {
            out.sentiments.push(json!({ "id": id, "value": v }));
        }
    }
    if let Some(FieldValue::Array(a)) = field(c, "It000078Array") {
        // Пустые слоты массива — нулевой id.
        out.seeker_tokens.extend(
            a.values
                .iter()
                .filter_map(unique_id)
                .filter(|id| !id.starts_with("00000000000000000000000000000000")),
        );
    }
    // app.QuestContext.SaveData: ID, OrderedNo, ResultNo, EndDay…
    if let (Some(id), Some(result)) = (num(field(c, "ID")), num(field(c, "ResultNo"))) {
        if field(c, "OrderedNo").is_some() {
            out.contexts.push(json!({
                "id": id, "resultNo": result, "orderedNo": num(field(c, "OrderedNo")),
                "endDay": num(field(c, "EndDay")), "endHour": num(field(c, "EndHour")),
            }));
        }
    }
    // app.QuestLogManager.QuestLogInfo.QuestLogSaveData: QuestId, Status, CurrentTaskIndex…
    if let (Some(id), Some(status)) = (num(field(c, "QuestId")), num(field(c, "Status"))) {
        out.log.push(json!({
            "id": id, "status": status, "currentTask": num(field(c, "CurrentTaskIndex")),
            "completedTasks": nums(field(c, "CompletedTaskIndexes")),
            "reportIndex": num(field(c, "ReportIndex")),
        }));
    }
    // app.QuestManager.DisableQuestSaveData: QuestID — ставшие недоступными квесты
    if let (Some(id), Some(_)) = (num(field(c, "QuestID")), field(c, "IsTImeLimit")) {
        out.disabled.push(json!({ "id": id }));
    }
    for f in &c.fields {
        // app.GameSaveData.StartPosition — via.Position, три f64.
        if let FieldValue::Struct(st) = &f.value {
            if f.hash == h("StartPosition") && st.data.len() == 24 && out.player.is_none() {
                let d =
                    |i: usize| f64::from_le_bytes(st.data[i * 8..i * 8 + 8].try_into().unwrap());
                out.player = Some([d(0), d(1), d(2)]);
            }
        }
        visit(&f.value, out);
    }
}

fn visit(v: &FieldValue, out: &mut Out) {
    match v {
        FieldValue::Class(c) => walk(c, out),
        FieldValue::Array(a) => a.values.iter().for_each(|x| visit(x, out)),
        _ => {}
    }
}

fn account_from_path(path: &str) -> Option<u64> {
    let parts: Vec<&str> = path.split(['\\', '/']).collect();
    let i = parts
        .iter()
        .position(|p| p.eq_ignore_ascii_case("userdata"))?;
    parts.get(i + 1)?.parse().ok()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let Some(file) = args.get(1).filter(|a| !a.starts_with("--")) else {
        eprintln!("Использование: dd2-save <файл.bin> [--steamid <SteamID64 или номер аккаунта>]");
        std::process::exit(2);
    };
    let explicit = args
        .iter()
        .position(|a| a == "--steamid")
        .and_then(|i| args.get(i + 1))
        .and_then(|s| s.parse::<u64>().ok());
    let Some(id) = explicit.or_else(|| account_from_path(file)) else {
        eprintln!("Не удалось определить SteamID: укажите --steamid");
        std::process::exit(2);
    };
    // Для DD2 ключ — младшие 32 бита SteamID64 (= номер аккаунта); принимаем оба вида.
    let steam_id = if id < STEAM_ID_BASE {
        STEAM_ID_BASE + id
    } else {
        id
    };

    let mut opts = SaveOptions::new(Game::DD2).id(steam_id);
    let save = match SaveFile::load(file, &mut opts) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("Не удалось расшифровать {file}: {e:?}");
            std::process::exit(1);
        }
    };
    let mut out = Out::default();
    for (_, c) in &save.fields {
        walk(c, &mut out);
    }
    let result = json!({
        "file": file, "steamId": steam_id.to_string(),
        "quests": out.contexts, "questLog": out.log, "disabled": out.disabled,
        "player": out.player.map(|[x, y, z]| json!({ "x": x, "y": y, "z": z })),
        "pawns": out.pawns, "sentiments": out.sentiments, "seekerTokens": out.seeker_tokens,
        "mapMasks": out.map_masks,
    });
    // Библиотека печатает отладку в stdout, поэтому результат помечаем маркером.
    println!("@@DD2SAVE@@{}", serde_json::to_string(&result).unwrap());
}
