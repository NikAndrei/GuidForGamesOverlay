# GuidForGamesOverlay

«Справка по игре» (как Game Help на PS5) для игр в Steam на ПК. Приложение показывает подсказки
по текущему прогрессу игрока прямо поверх игры и вызывается с клавиатуры или контроллера.

Самостоятельное приложение: данные игр, моды-мосты и чтение сейвов лежат в этом репозитории.
Данные и моды изначально перенесены из [GuidForGames](https://github.com/NikAndrei/GuidForGames)
(приложение-компаньон для телефона), дальше ведутся здесь.

## Игры

| Игра | Откуда прогресс | Подсказок |
|---|---|---|
| Dragon's Dogma 2 | мод-мост REFramework или сейв | 354 |
| Resident Evil 4 (ремейк) | мод-мост REFramework | 428 |

## Быстрый старт (Windows)

1. Собрать: `cargo build --release` (или скачать архив `gfg-overlay-windows` из GitHub Actions).
2. Поставить в игру [REFramework](https://github.com/praydog/REFramework), затем мод-мост:
   ```bash
   gfg-service install-mods
   ```
3. Запустить сервис и открыть http://127.0.0.1:7870/:
   ```bash
   gfg-service
   ```

Игры, их сейвы и папки модов сервис находит в Steam сам. `config.toml` нужен, только если что-то не нашлось
(образец — `config.example.toml`).

## Документы

- [`docs/plan.md`](docs/plan.md): план MVP, решения, открытые вопросы. Читать первым.
- [`docs/design.md`](docs/design.md): проектная записка (архитектура, риски).
- [`service/README.md`](service/README.md): сервис, протокол оверлея, HTTP API.

## Структура

```
service/                 сервис (Rust): наблюдатель, адаптеры игр, правила, отладочная страница, протокол оверлея
games/<game-id>/         данные игры: game.json, entries/ (справочник), save-map.json, rules.json, README
mods/<game>/             моды-мосты REFramework (Lua): читают состояние игры и пишут JSON
tools/dd2-save/          чтение сейва Dragon's Dogma 2 (Rust)
schemas/                 JSON Schema: модель состояния, правила
overlay/reshade-addon/   основной показ: аддон ReShade (C++) с окном на ImGui — следующий шаг
window/                  запасной показ: прозрачное окно поверх игры
docs/                    записка и план
```
