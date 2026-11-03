#include "input.hpp"

#include <cstdlib>

namespace gfg {

bool Combo::update(uint32_t buttons, uint64_t now_ms) {
    if ((buttons & mask_) != mask_) {
        since_ = 0;
        fired_ = false;
        return false;
    }
    if (since_ == 0) since_ = now_ms == 0 ? 1 : now_ms;
    if (!fired_ && now_ms - since_ >= hold_ms_) {
        fired_ = true;
        return true;
    }
    return false;
}

namespace {
constexpr uint64_t kRepeatDelay = 400;
constexpr uint64_t kRepeatEvery = 110;
}  // namespace

std::vector<Action> GamepadNav::update(uint32_t buttons, uint64_t now_ms) {
    std::vector<Action> out;
    const uint32_t pressed = buttons & ~prev_;
    prev_ = buttons;

    struct Map {
        uint32_t button;
        Action action;
    };
    static constexpr Map once[] = {
        {A, Action::Confirm}, {B, Action::Back}, {Y, Action::Hide}, {LB, Action::TabPrev}, {RB, Action::TabNext},
        {DpadLeft, Action::TabPrev}, {DpadRight, Action::TabNext},
    };
    for (const auto& m : once)
        if (pressed & m.button) out.push_back(m.action);

    // Вверх/вниз — с автоповтором, пока держат.
    for (uint32_t b : {static_cast<uint32_t>(DpadUp), static_cast<uint32_t>(DpadDown)}) {
        const Action a = b == DpadUp ? Action::Up : Action::Down;
        if (pressed & b) {
            out.push_back(a);
            repeat_button_ = b;
            repeat_at_ = now_ms + kRepeatDelay;
        } else if ((buttons & b) && repeat_button_ == b && now_ms >= repeat_at_) {
            out.push_back(a);
            repeat_at_ = now_ms + kRepeatEvery;
        }
    }
    if (!(buttons & repeat_button_)) repeat_button_ = 0;
    return out;
}

uint32_t stick_to_dpad(int16_t x, int16_t y, int16_t deadzone) {
    uint32_t out = 0;
    // Преобладающая ось: диагональ не даёт двух направлений сразу.
    if (std::abs(int(y)) >= std::abs(int(x))) {
        if (y > deadzone) out |= DpadUp;
        if (y < -deadzone) out |= DpadDown;
    } else {
        if (x > deadzone) out |= DpadRight;
        if (x < -deadzone) out |= DpadLeft;
    }
    return out;
}

}  // namespace gfg
