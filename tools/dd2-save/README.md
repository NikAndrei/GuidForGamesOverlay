# dd2-save

Перенесена из GuidForGames (`tools/dd2-save`) и дальше развивается здесь.

Читает сохранение Dragon's Dogma 2 и печатает состояние квестов в JSON. **Файл только читается** —
сервер вызывает утилиту на временной копии.

```
dd2-save.exe <файл *Slot.bin> [--steamid <SteamID64 или номер аккаунта>]
```

- Без `--steamid` номер аккаунта берётся из пути `…\userdata\<номер>\2054970\…`.
  Для чужих сохранений (другой аккаунт или файл вне папки Steam) укажите SteamID вручную —
  в сервисе: `steam_id` в `config.toml`.
- Квесты лежат в файлах слотов `data0XXSlot.bin`; `data00-1.bin` — системный файл без квестов.
- Результат — строка `@@DD2SAVE@@{json}` (библиотека расшифровки печатает в stdout свою отладку).

## Сборка

Утилита входит в общий workspace: `cargo build --release` в корне репозитория собирает её вместе с сервисом,
`dd2-save.exe` оказывается рядом с `gfg-service.exe`, и сервис находит её сам. Готовый архив для Windows
собирает GitHub Actions (`.github/workflows/service.yml`).

Расшифровка и разбор формата — библиотека [ree-save-editor](https://github.com/kvasszn/ree-save-editor)
(коммит закреплён в Cargo.toml). Лицензия у неё не указана — утилита только для личного использования.

## Что известно о формате

- Шифрование «Mandarin», ключ — младшие 32 бита SteamID64.
- Квесты: `app.QuestContext.SaveData` (`ID`, `ResultNo`, `EndDay`…) и журнал
  `QuestLogSaveData` (`QuestId`, `Status`: 1 — активен, 2 — выполнен, `CurrentTaskIndex`, `CompletedTaskIndexes`).
- Номера квестов: `100xx` — основная линия, `200xx` — побочные. Сопоставление с записями —
  `games/dragons-dogma-2/save-map.json` (`confirmed: false` — предположение, подтвердить по журналу в игре).
- Позиция игрока: `app.GameSaveData.StartPosition` — `via.Position` (три f64: x, y — высота, z).
  Пример: Вернворт ≈ (478, 24, −1055). Север — −z, восток — +x. Позиции повозок — `Oxcarts[].CurrentPos`.
  Мир карты — квадрат 8192 м от −4096: так в маске исследованного (`MapMaskField`: `BasePos` −4096, `DispRange` 8192,
  у локальных областей — свои `BasePos`/`DispRange`, Int2). Метки игрока на карте (`MapPin`) пока не читаются.
- Маска исследованного (туман войны): `app.GuiManager.MapMaskSaveData` в `GameSaveDataList[…]` — `MapMaskField`
  (весь мир, `AreaNo` −1) и `MapMaskLocalArea[]` (локальные области — подземелья и т. п., сетка 8 м). `MaskBit` — массив
  u32: квадратная сетка, строки с севера (−z) на юг, в строке с запада (−x), младший бит первым. Мир — 512×512 клеток
  по 16 м (8192 u32). Утилита отдаёт `mapMasks: [{ area, base, range, bits }]`, биты — base64 (u32 little-endian).
- Пешки: `app.PawnDataContext` в базе контекстов (`_Name`, `_SearchId` у нанятых, `_PossessionLv` /
  `_PossessionProgressPoint` — драконья чума, в коде игры «Possession»); у главной пешки рядом
  `app.MainPawnDataContext._FavorabilityRating` — её симпатия к Восставшему.
- Симпатия NPC: `app.NPCManager.NPCSaveSentiment` (`CharaID`, `Value` — 0…300).
- Подобранные жетоны искателя: `app.GimmickManager.GameSaveData.It000078Array` — уникальные id объектов
  (пустые слоты — нулевой id). Привязки id к месту в сохранении нет.
- Сундуки: записи объектов (`GimmickContext` + `GimmickPosRotContext`) есть только для мест рядом с последней
  позицией, поэтому открытые сундуки по сохранению не отследить.
