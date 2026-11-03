// Окно «Справка по игре» на ImGui. Общее для аддона (ImGui из ReShade), прозрачного окна (window/)
// и предпросмотра (tests/ui_preview.cpp).
#pragma once

#include <functional>
#include <string>

#include "model.hpp"
#include "nav.hpp"

namespace gfg {

struct UiView {
    const UiModel& model;
    Nav& nav;
    bool connected = false;
    std::string error{};     // последняя ошибка связи или сервиса
    bool font_note = false;  // у ReShade шрифт без кириллицы — подсказать, как поменять
    std::string note{};      // строка внизу окна (как ведёт себя игра, пока справка открыта)
    bool* scroll_to_selected = nullptr;
    std::function<void(const std::string&)> send{};  // команда сервису
};

// Нарисовать окно (вызывать между NewFrame и Render, только когда nav.open).
void draw_help_window(UiView& view);

}  // namespace gfg
