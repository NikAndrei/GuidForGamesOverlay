cmake_minimum_required(VERSION 3.21)
project(gfg_overlay LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(MSVC)
  add_compile_options(/utf-8 /W4 /permissive-)
  add_compile_definitions(_CRT_SECURE_NO_WARNINGS _WINSOCK_DEPRECATED_NO_WARNINGS)
  # Аддон грузится в чужой процесс: свой рантайм внутри, без зависимости от VC++ Redistributable.
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

# Ядро без Windows и ReShade: протокол, навигация, ввод, проверка игры. Собирается и тестируется где угодно.
add_library(gfg_core STATIC src/model.cpp src/nav.cpp src/input.cpp src/guard.cpp src/client.cpp)
target_include_directories(gfg_core PUBLIC src)
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

# ImGui той версии, под которую собран ReShade 6.6.2 (1.92.2, IMGUI_VERSION_NUM 19222).
FetchContent_Declare(imgui
  GIT_REPOSITORY https://github.com/ocornut/imgui.git
  GIT_TAG 1f7f1f54af38b0350d8c0008b096a9af6de299c7)

# Предпросмотр окна без игры (Linux/macOS): настоящий ImGui, программная отрисовка в картинку.
option(GFG_BUILD_PREVIEW "Предпросмотр окна (tests/ui_preview.cpp)" OFF)
if(GFG_BUILD_PREVIEW AND NOT WIN32)
  FetchContent_GetProperties(imgui)
  if(NOT imgui_POPULATED)
    FetchContent_Populate(imgui)
  endif()
  add_executable(gfg_ui_preview tests/ui_preview.cpp src/ui.cpp
    ${imgui_SOURCE_DIR}/imgui.cpp ${imgui_SOURCE_DIR}/imgui_draw.cpp
    ${imgui_SOURCE_DIR}/imgui_widgets.cpp ${imgui_SOURCE_DIR}/imgui_tables.cpp)
  target_include_directories(gfg_ui_preview SYSTEM PRIVATE ${imgui_SOURCE_DIR})
  target_compile_definitions(gfg_ui_preview PRIVATE ImTextureID=ImU64)
  target_link_libraries(gfg_ui_preview PRIVATE gfg_core)
endif()

# Сам аддон — только под Windows.
if(WIN32)
  # Заголовки ReShade SDK (версия API 18) и ImGui той версии, под которую они собраны (1.92.2, 19222).
  # Подмодули ReShade не нужны: ImGui берём отдельно, нужной версии.
  FetchContent_Declare(reshade
    GIT_REPOSITORY https://github.com/crosire/reshade.git
    GIT_TAG v6.6.2
    GIT_SHALLOW TRUE
    GIT_SUBMODULES "")
  FetchContent_GetProperties(reshade)
  if(NOT reshade_POPULATED)
    FetchContent_Populate(reshade)
  endif()
  FetchContent_GetProperties(imgui)
  if(NOT imgui_POPULATED)
    FetchContent_Populate(imgui)
  endif()

  add_library(gfg_overlay SHARED src/addon.cpp src/ui.cpp)
  target_include_directories(gfg_overlay SYSTEM PRIVATE ${reshade_SOURCE_DIR}/include ${imgui_SOURCE_DIR})
  target_compile_definitions(gfg_overlay PRIVATE GFG_RESHADE ImTextureID=ImU64 WIN32_LEAN_AND_MEAN NOMINMAX UNICODE _UNICODE)
  target_link_libraries(gfg_overlay PRIVATE gfg_core psapi)
  if(NOT MSVC)
    target_link_options(gfg_overlay PRIVATE -static -static-libgcc -static-libstdc++)
  endif()
  # ReShade ищет аддоны по расширению .addon64 рядом с игрой.
  set_target_properties(gfg_overlay PROPERTIES PREFIX "" OUTPUT_NAME "guidforgames" SUFFIX ".addon64")
endif()
