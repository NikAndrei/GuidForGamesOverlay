# Показ подсказок поверх игры

Логики здесь нет: подсказки, прогресс и раскрытые уровни хранит сервис `gfg-service`, показ получает от него
модель UI по TCP (`service/README.md`) и рисует окно «Справка по игре». Два способа показа с общим окном:

| | Аддон ReShade (основной) | Прозрачное окно (запасной) |
|---|---|---|
| Файл | `guidforgames.addon64` рядом с exe игры | `gfg-window.exe`, отдельная программа |
| Как рисует | внутри кадра игры (ImGui из ReShade) | своё окно поверх игры (ImGui + DirectX 11) |
| Режим экрана | любой, включая эксклюзивный полноэкранный | окно / окно без рамки |
| Античит | только игры из белого списка, без античита | в игру ничего не внедряет |
| Кириллица | нужен шрифт ReShade с кириллицей | Segoe UI, всегда |
| Контроллер, пока справка открыта | игра тоже получает нажатия | фокус у справки (игра обычно на паузе) |

Подробности — `reshade-addon/README.md` и `window/README.md`.

## Управление (одинаково в обоих)

| | Клавиатура | Контроллер |
|---|---|---|
| Открыть / закрыть | **Shift+F1** | удерживать **View (Share) + R3** ~0,5 с |
| Выбор в списке | ↑ ↓ | крестовина / левый стик ↑ ↓ (с автоповтором) |
| Вкладки | ← → | LB / RB (или крестовина ← →) |
| Открыть карточку, раскрыть следующий уровень | Enter / Space | A / ✕ |
| Скрыть раскрытое | Delete | Y / △ |
| Назад / закрыть | Esc / Backspace | B / ○ |

Мышь тоже работает. Контроллер — через XInput (Xbox и всё, что Steam Input показывает как Xbox-контроллер).
Вкладки: «Всё», «Прохождение» (quest, boss), «Загадки» (puzzle), «Собирательство» (secret, chest, file…), «Советы» (tip).
`(!)` в списке — можно пропустить: после какого-то момента сюжета уже не сделать.

## Код

```
core/            общее: протокол (model), навигация (nav), ввод (input), защита (guard), связь (client), окно (ui)
reshade-addon/   addon.cpp — аддон ReShade
window/          main.cpp — прозрачное окно
tests/           тесты ядра, проверка связи с сервисом, предпросмотр окна
cmake/           кросс-сборка mingw-w64 (проверка на Linux, что Windows-часть компилируется)
```

Ядро и окно от Windows не зависят и проверяются на Linux.

## Сборка

Windows (Visual Studio 2022) — аддон и окно:

```bash
cmake -S overlay -B build-overlay -A x64
cmake --build build-overlay --config Release
```

Результат — `build-overlay/Release/guidforgames.addon64` и `gfg-window.exe`. Готовые файлы кладёт в архив
`gfg-overlay-windows` GitHub Actions (`.github/workflows/service.yml`).

Без Windows:

```bash
cmake -S overlay -B build -DGFG_BUILD_PREVIEW=ON
cmake --build build
ctest --test-dir build                                    # ядро: протокол, навигация, ввод, защита
build/gfg_client_smoke 7871 re4.exe                       # связь с запущенным сервисом
curl -s localhost:7870/api/ui > ui.json
build/gfg_ui_preview ui.json out.ppm /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf open,down,confirm
```

`gfg_ui_preview` рисует окно настоящим ImGui в картинку (программная отрисовка): видно, как оно выглядит,
а проверки ImGui ловят ошибки вызовов, которые в игре привели бы к падению.

Кросс-сборка под Windows на Linux (mingw-w64), чтобы проверить, что аддон и окно компилируются:

```bash
cmake -S overlay -B build-win -DCMAKE_TOOLCHAIN_FILE=cmake/mingw-w64.cmake -DGFG_BUILD_TESTS=OFF
cmake --build build-win
```

Зависимости скачивает CMake: заголовки ReShade 6.6.2 (API 18), ImGui 1.92.2 (та версия, под которую собран
ReShade — `IMGUI_VERSION_NUM 19222`), nlohmann/json 3.11.3.
