cmake_minimum_required(VERSION 3.21)
project(gfg_overlay LANGUAGES CXX)

# Показ подсказок поверх игры: общее ядро (core/), аддон ReShade (reshade-addon/), прозрачное окно (window/).

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(MSVC)
  add_compile_options(/utf-8 /W4 /permissive-)
  add_compile_definitions(_CRT_SECURE_NO_WARNINGS _WINSOCK_DEPRECATED_NO_WARNINGS)
  # Аддон грузится в чужой процесс, окно ставится копированием: свой рантайм внутри, без VC++ Redistributable.
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
else()
  add_compile_options(-Wall -Wextra)
endif()

include(FetchContent)

# JSON — только заголовки.
FetchContent_Declare(nlohmann_json
  URL https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz
  URL_HASH SHA256=d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
set(JSON_BuildTests OFF CACHE INTERNAL "")
FetchContent_MakeAvailable(nlohmann_json)

# ImGui той версии, под которую собран ReShade 6.6.2 (1.92.2, IMGUI_VERSION_NUM 19222):
# аддон берёт из него только заголовки, окно и предпросмотр — весь ImGui.
FetchContent_Declare(imgui
  GIT_REPOSITORY https://github.com/ocornut/imgui.git
  GIT_TAG 1f7f1f54af38b0350d8c0008b096a9af6de299c7)
macro(gfg_need_imgui)
  FetchContent_GetProperties(imgui)
  if(NOT imgui_POPULATED)
    FetchContent_Populate(imgui)
  endif()
  set(GFG_IMGUI_SOURCES ${imgui_SOURCE_DIR}/imgui.cpp ${imgui_SOURCE_DIR}/imgui_draw.cpp
    ${imgui_SOURCE_DIR}/imgui_widgets.cpp ${imgui_SOURCE_DIR}/imgui_tables.cpp)
endmacro()

# Ядро без Windows и ReShade: протокол, навигация, ввод, проверка игры, связь. Собирается и тестируется где угодно.
add_library(gfg_core STATIC core/model.cpp core/nav.cpp core/input.cpp core/guard.cpp core/client.cpp)
target_include_directories(gfg_core PUBLIC core)
target_link_libraries(gfg_core PUBLIC nlohmann_json::nlohmann_json)
if(WIN32)
  target_link_libraries(gfg_core PUBLIC ws2_32)
else()
  find_package(Threads REQUIRED)
  target_link_libraries(gfg_core PUBLIC Threads::Threads)
endif()

option(GFG_BUILD_TESTS "Тесты ядра" ON)
if(GFG_BUILD_TESTS)
  enable_testing()
  add_executable(gfg_tests tests/tests.cpp)
  target_link_libraries(gfg_tests PRIVATE gfg_core)
  add_test(NAME gfg_tests COMMAND gfg_tests)
  # Ручная проверка связи с запущенным сервисом: gfg_client_smoke <порт> <exe>
  add_executable(gfg_client_smoke tests/client_smoke.cpp)
  target_link_libraries(gfg_client_smoke PRIVATE gfg_core)
endif()

# Предпросмотр окна без игры (Linux/macOS): настоящий ImGui, программная отрисовка в картинку.
option(GFG_BUILD_PREVIEW "Предпросмотр окна (tests/ui_preview.cpp)" OFF)
if(GFG_BUILD_PREVIEW AND NOT WIN32)
  gfg_need_imgui()
  add_executable(gfg_ui_preview tests/ui_preview.cpp core/ui.cpp ${GFG_IMGUI_SOURCES})
  target_include_directories(gfg_ui_preview SYSTEM PRIVATE ${imgui_SOURCE_DIR})
  target_compile_definitions(gfg_ui_preview PRIVATE ImTextureID=ImU64)
  target_link_libraries(gfg_ui_preview PRIVATE gfg_core)
endif()

if(WIN32)
  gfg_need_imgui()

  # Аддон ReShade: заголовки ReShade SDK (API 18); функции ImGui — через таблицу ReShade.
  FetchContent_Declare(reshade
    GIT_REPOSITORY https://github.com/crosire/reshade.git
    GIT_TAG v6.6.2
    GIT_SHALLOW TRUE
    GIT_SUBMODULES "")  # подмодули ReShade не нужны: ImGui берём отдельно, нужной версии
  FetchContent_GetProperties(reshade)
  if(NOT reshade_POPULATED)
    FetchContent_Populate(reshade)
  endif()
  add_library(gfg_addon SHARED reshade-addon/addon.cpp core/ui.cpp)
  target_include_directories(gfg_addon SYSTEM PRIVATE ${reshade_SOURCE_DIR}/include ${imgui_SOURCE_DIR})
  target_compile_definitions(gfg_addon PRIVATE GFG_RESHADE ImTextureID=ImU64 WIN32_LEAN_AND_MEAN NOMINMAX UNICODE _UNICODE)
  target_link_libraries(gfg_addon PRIVATE gfg_core psapi)
  # ReShade ищет аддоны по расширению .addon64 рядом с игрой.
  set_target_properties(gfg_addon PROPERTIES PREFIX "" OUTPUT_NAME "guidforgames" SUFFIX ".addon64")

  # Прозрачное окно поверх игры (запасной путь): свой ImGui + Win32 + DirectX 11.
  add_executable(gfg_window WIN32 window/main.cpp core/ui.cpp ${GFG_IMGUI_SOURCES}
    ${imgui_SOURCE_DIR}/backends/imgui_impl_win32.cpp ${imgui_SOURCE_DIR}/backends/imgui_impl_dx11.cpp)
  target_include_directories(gfg_window SYSTEM PRIVATE ${imgui_SOURCE_DIR} ${imgui_SOURCE_DIR}/backends)
  target_compile_definitions(gfg_window PRIVATE ImTextureID=ImU64 WIN32_LEAN_AND_MEAN NOMINMAX UNICODE _UNICODE)
  target_link_libraries(gfg_window PRIVATE gfg_core d3d11 dxgi d3dcompiler dwmapi)
  set_target_properties(gfg_window PROPERTIES OUTPUT_NAME "gfg-window")

  if(NOT MSVC)
    foreach(t gfg_addon gfg_window)
      target_link_options(${t} PRIVATE -static -static-libgcc -static-libstdc++)
    endforeach()
    target_link_options(gfg_window PRIVATE -municode)
  endif()
endif()
