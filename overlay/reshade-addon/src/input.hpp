// Ввод с контроллера: кнопки в раскладке XInput, комбинация вызова, нажатия с автоповтором.
// Не зависит от Windows: опрос XInput — в addon.cpp.
#pragma once

#include <cstdint>
#include <vector>

#include "nav.hpp"

namespace gfg {

// Биты как в XINPUT_GAMEPAD::wButtons.
enum Button : uint32_t {
    DpadUp = 0x0001,
    DpadDown = 0x0002,
    DpadLeft = 0x0004,
    DpadRight = 0x0008,
    Start = 0x0010,
    View = 0x0020,  // Back / Share
    L3 = 0x0040,
    R3 = 0x0080,
    LB = 0x0100,
    RB = 0x0200,
    A = 0x1000,
    B = 0x2000,
    X = 0x4000,
    Y = 0x8000,
};

// Комбинация вызова: все кнопки mask удерживаются hold_ms — срабатывает один раз до отпускания.
class Combo {
public:
    explicit Combo(uint32_t mask = View | R3, uint64_t hold_ms = 500) : mask_(mask), hold_ms_(hold_ms) {}
    bool update(uint32_t buttons, uint64_t now_ms);
    // Кнопки комбинации сейчас зажаты (их нажатия не должны превращаться в другие действия).
    bool holding() const { return since_ != 0; }

private:
    uint32_t mask_;
    uint64_t hold_ms_;
    uint64_t since_ = 0;
    bool fired_ = false;
};

// Действия навигации из состояния кнопок: по нажатию, крестовина — с автоповтором.
class GamepadNav {
public:
    std::vector<Action> update(uint32_t buttons, uint64_t now_ms);

private:
    uint32_t prev_ = 0;
    uint32_t repeat_button_ = 0;
    uint64_t repeat_at_ = 0;
};

// Левый стик → биты крестовины (порог — как у XInput: 7849 из 32767).
uint32_t stick_to_dpad(int16_t x, int16_t y, int16_t deadzone = 16000);

}  // namespace gfg
