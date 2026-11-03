# Адаптер Dragon's Dogma 2 (Steam AppID 2054970)

Два источника, оба уже работают в GuidForGames:

1. **Сейв:** `<Steam>/userdata/<AccountID>/2054970/remote/win64_save/`. Шифрование «Mandarin», ключ выводится
   из SteamID64, внутри данные RSZ. Расшифровку делает утилита `tools/dd2-save` из GuidForGames (Rust, поверх
   ree-save-editor). Подробности — в `docs/save-reading.md` GuidForGames.
2. **Мод-мост REFramework** (`mods/dd2/guidforgames.lua` в GuidForGames): пишет в `<игра>/reframework/data/`
   `guidforgames_live.json` раз в 2 с (позиция, отслеживаемый квест и его цель, область) и
   `guidforgames_state.json` при изменениях (журнал квестов). Если мод установлен, это основной источник.

Номера квестов → записи и ступени прогресса: `data/dragons-dogma-2/save-map.json` в GuidForGames.
