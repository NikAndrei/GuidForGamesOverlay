# Сервис (Rust)

Отдельный процесс: если разбор сейва упадёт, игра не пострадает. Один сервис обслуживает и оверлей ReShade,
и запасное прозрачное окно.

```
папки сейвов и мода → наблюдатель (debounce 0,7 с + опрос раз в 30 с) → адаптер игры → модель состояния
    → правила (games/<id>/rules.json) + справочник (games/<id>/entries) → модель UI → оверлей (TCP) и отладочная страница (HTTP)
```

## Запуск

```bash
cargo run --release -p gfg-service                    # игры и сейвы находятся в Steam сами
cargo run --release -p gfg-service -- install-mods    # поставить моды-мосты в найденные игры
cargo run --release -p gfg-service -- --config config.toml
```

`config.toml` необязателен (образец — `config.example.toml`). Без него папка `games/` ищется в текущей папке,
рядом с программой или в корне репозитория.

Отладочная страница: http://127.0.0.1:7870/. Там видно, что сейчас актуально (уровни подсказок можно раскрывать),
модель состояния каждой игры, ошибки адаптера и опечатки в правилах.

```bash
cargo test
```

## Модули (`src/`)

| Файл | Что делает |
|---|---|
| `config.rs` | `config.toml` (необязательный): адреса, папки, настройки игр (`[games.<id>]`) |
| `steam.rs` | поиск Steam (реестр, обычные места), библиотек (libraryfolders.vdf), игр (appmanifest), userdata |
| `content.rs` | папка `games/<id>/`: game.json, entries/, save-map.json, rules.json |
| `install.rs` | `install-mods`: копирует моды-мосты в `<игра>/reframework/autorun/` |
| `state.rs` | общая модель состояния (`schemas/state.schema.json`) |
| `adapter/` | адаптеры игр; `dd2.rs` — мод-мост и сейв через `dd2-save`, `re4.rs` — мод-мост |
| `rules.rs` | правила (`schemas/hints.schema.json`): загрузка, проверка опечаток, вычисление условий |
| `ui.rs` | модель UI: подсказки по приоритету правил, без сделанного и упущенного, раскрытые уровни |
| `app.rs` | ядро: игры, обновление, раскрытие подсказок (`state/reveals.json`), рассылка модели UI |
| `watcher.rs` | наблюдатель за папками |
| `overlay.rs` | протокол для оверлея |
| `http.rs` | отладочная страница и HTTP API |

Текущая игра — та, чьё состояние обновлялось последним.

## Защита от спойлеров

- В модели UI есть только **раскрытые** уровни подсказок, нераскрытые до оверлея не доходят.
- Запись справочника, у которой `availableFrom` дальше текущей ступени прогресса, не показывается,
  даже если правило написано с ошибкой.
- Если прогресс неизвестен, `progressAtLeast` не выполняется, а `progressBefore` выполняется.

## Протокол оверлея (версия 1)

TCP `127.0.0.1:7871`, по одному JSON-объекту в строке, UTF-8.

Сервис → клиент:
- `{"type":"hello","protocol":1}` — сразу после подключения;
- `{"type":"ui","ui":{…}}` — модель UI: сразу и при каждом изменении;
- `{"type":"error","message":"…"}` — ответ на неверную команду.

Клиент → сервис:
- `{"cmd":"reveal","item":"<id>"}` — раскрыть следующий уровень;
- `{"cmd":"hide","item":"<id>"}` — скрыть все уровни;
- `{"cmd":"refresh"}` — перечитать сейвы.

Модель UI (`kind` — вид записи для вкладок; `missable: true` и `missableNote` — у пропускаемого):

```json
{
  "game": "dragons-dogma-2",
  "title": { "ru": "Dragon's Dogma 2", "en": "Dragon's Dogma 2" },
  "source": "mod",
  "updatedAt": "2026-11-03T08:06:15Z",
  "items": [
    {
      "id": "mq-in-dragons-wake",
      "kind": "quest",
      "title": { "ru": "По следам Дракона", "en": "In Dragon's Wake" },
      "location": { "ru": "Мелв → Вернворт", "en": "Melve → Vernworth" },
      "levels": 3,
      "revealed": 1,
      "hints": ["Иди в разорённую деревню на юге…"],
      "sources": ["https://dragonsdogma2.wiki.fextralife.com/In+Dragon%27s+Wake"]
    }
  ]
}
```

## HTTP API

- `GET /api/ui` — модель UI;
- `GET /api/status` — игры: модель состояния, ошибки, опечатки в правилах, за чем следим;
- `POST /api/reveal/<id>`, `POST /api/hide/<id>`, `POST /api/refresh`.
