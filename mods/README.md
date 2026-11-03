# Моды-мосты REFramework

Lua-скрипты для [REFramework](https://github.com/praydog/REFramework): **только читают** состояние игры
и пишут его в JSON-файлы в `<игра>/reframework/data/`. В игре ничего не меняют.

| Папка | Игра | Что пишет |
|---|---|---|
| `dd2/` | Dragon's Dogma 2 | `guidforgames_live.json`, `guidforgames_state.json` и др. |
| `re4/` | Resident Evil 4 (ремейк) | `guidforgames_re4_live.json` и др. |

Установка: сначала REFramework в папку игры (dinput8.dll), затем

```bash
gfg-service install-mods
```

Команда сама находит игры в Steam и копирует скрипт в `<игра>/reframework/autorun/guidforgames.lua`.

Моды перенесены из GuidForGames (dd2 v37, re4 v22) и дальше ведутся здесь. Имена файлов прежние,
поэтому оба приложения могут работать от одного и того же мода.
