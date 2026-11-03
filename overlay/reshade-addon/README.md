# Аддон ReShade (C++)

| Файл | Что делает |
|---|---|
| `src/addon.cpp` | только Windows: регистрация в ReShade, проверка игры, клавиатура (через ReShade) и XInput, `block_input_next_frame` |
| `src/ui.cpp` | окно на ImGui: вкладки, список, карточка с уровнями |
| `src/client.cpp` | связь с сервисом: TCP, JSON по строкам, переподключение каждые 2 с, свой поток |
| `src/model.cpp` | разбор сообщений сервиса и команды (`reveal`, `hide`, `game`) |
| `src/nav.cpp` | навигация: вкладки, выбор (держится по id, когда список обновился), карточка |
| `src/input.cpp` | комбинация вызова (View+R3, 0,5 с), кнопки → действия, автоповтор, стик → крестовина |
| `src/guard.cpp` | белый список игр, признаки античитов |

Всё, кроме `addon.cpp`, от Windows не зависит и проверяется на Linux.

Зависимости скачивает CMake: заголовки ReShade 6.6.2 (API 18), ImGui 1.92.2 (та версия, под которую собран
ReShade — `IMGUI_VERSION_NUM 19222`), nlohmann/json 3.11.3. Функции ImGui аддон вызывает через таблицу ReShade
(`reshade_overlay.hpp`), сам ImGui в аддон не входит.

## Сборка (Windows, Visual Studio 2022)

```bash
cmake -S overlay/reshade-addon -B build-addon -A x64
cmake --build build-addon --config Release
```

Результат — `build-addon/Release/guidforgames.addon64`. Готовый файл кладёт в архив `gfg-overlay-windows`
GitHub Actions (`.github/workflows/service.yml`).

## Проверка без Windows

```bash
cmake -S overlay/reshade-addon -B build -DGFG_BUILD_PREVIEW=ON
cmake --build build
ctest --test-dir build                                    # ядро: протокол, навигация, ввод, защита
build/gfg_client_smoke 7871 re4.exe                       # связь с запущенным сервисом
curl -s localhost:7870/api/ui > ui.json
build/gfg_ui_preview ui.json out.ppm /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf open,down,confirm
```

`gfg_ui_preview` рисует окно настоящим ImGui в картинку (программная отрисовка) — так видно, как оно выглядит,
и проверки ImGui ловят ошибки вызовов, которые в игре привели бы к падению.

Кросс-сборка под Windows на Linux (mingw-w64) — для проверки, что аддон компилируется:

```bash
cmake -S overlay/reshade-addon -B build-win -DCMAKE_TOOLCHAIN_FILE=cmake/mingw-w64.cmake -DGFG_BUILD_TESTS=OFF
cmake --build build-win
```
