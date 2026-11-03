// GuidForGames Overlay — аддон ReShade: окно «Справка по игре» поверх игры.
// Логика (сейвы, правила) — в сервисе gfg-service; здесь только показ и ввод.

#include <windows.h>
#include <psapi.h>
#include <xinput.h>

#include <imgui.h>
#include <reshade.hpp>

#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "client.hpp"
#include "guard.hpp"
#include "input.hpp"
#include "model.hpp"
#include "nav.hpp"
#include "ui.hpp"

// Имя и описание аддона для списка в ReShade (ищутся по этим экспортам).
extern "C" {
__declspec(dllexport) extern const char* NAME;
__declspec(dllexport) extern const char* DESCRIPTION;
}
const char* NAME = "GuidForGames Overlay";
const char* DESCRIPTION =
    "Game Help: context hints for the current progress (service gfg-service must be running).";

namespace {

constexpr const char* kSection = "GuidForGames";

struct Hotkey {
    uint32_t vk = VK_F1;
    bool ctrl = false, shift = true, alt = false;
};

struct Settings {
    std::string host = "127.0.0.1";
    uint16_t port = 7871;
    std::vector<std::string> allowed = gfg::kDefaultAllowedExe;
    Hotkey hotkey;
    bool gamepad = true;
};

// Состояние аддона: только из потока рендера (reshade_overlay), кроме клиента.
struct State {
    Settings settings;
    std::string exe;
    std::string exe_dir;
    gfg::GuardResult guard;
    std::unique_ptr<gfg::Client> client;
    gfg::Nav nav;
    gfg::UiModel model;
    uint64_t model_version = 0;
    gfg::Combo combo;
    gfg::GamepadNav pad;
    bool scroll_to_selected = false;
    bool font_note = false;
    uint64_t next_guard_check = 0;
    int runtimes = 0;
} g;

// ----- настройки (ReShade.ini, раздел [GuidForGames]) -----

std::string config_string(const char* key, const std::string& def) {
    char buf[512];
    size_t size = sizeof(buf);
    if (reshade::get_config_value(nullptr, kSection, key, buf, &size)) return std::string(buf);
    reshade::set_config_value(nullptr, kSection, key, def.c_str());  // чтобы ключ было видно и легко поменять
    return def;
}

Hotkey parse_hotkey(const std::string& s) {
    Hotkey h{0, false, false, false};
    unsigned vk = 0, c = 0, sh = 0, a = 0;
    if (std::sscanf(s.c_str(), "%u,%u,%u,%u", &vk, &c, &sh, &a) >= 1 && vk != 0) {
        h.vk = vk;
        h.ctrl = c != 0;
        h.shift = sh != 0;
        h.alt = a != 0;
        return h;
    }
    return Hotkey{};
}

Settings load_settings() {
    Settings s;
    s.host = config_string("Host", s.host);
    s.port = static_cast<uint16_t>(std::stoul(config_string("Port", std::to_string(s.port))));
    std::string allowed;
    for (const auto& e : s.allowed) allowed += (allowed.empty() ? "" : ",") + e;
    s.allowed = gfg::split_list(config_string("AllowedExe", allowed));
    // Как у ReShade: код клавиши, Ctrl, Shift, Alt. По умолчанию Shift+F1.
    s.hotkey = parse_hotkey(config_string("Hotkey", "112,0,1,0"));
    s.gamepad = config_string("GamepadCombo", "1") != "0";
    return s;
}

// ----- что за процесс -----

std::string narrow(const std::wstring& w) {
    if (w.empty()) return {};
    const int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), int(w.size()), nullptr, 0, nullptr, nullptr);
    std::string out(size_t(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), int(w.size()), out.data(), n, nullptr, nullptr);
    return out;
}

void detect_exe() {
    wchar_t path[MAX_PATH] = {};
    GetModuleFileNameW(nullptr, path, MAX_PATH);
    std::wstring p(path);
    const auto slash = p.find_last_of(L"\\/");
    g.exe = narrow(slash == std::wstring::npos ? p : p.substr(slash + 1));
    g.exe_dir = narrow(slash == std::wstring::npos ? std::wstring() : p.substr(0, slash));
}

std::vector<std::string> loaded_modules() {
    std::vector<std::string> out;
    HMODULE mods[1024];
    DWORD needed = 0;
    if (!EnumProcessModules(GetCurrentProcess(), mods, sizeof(mods), &needed)) return out;
    for (DWORD i = 0; i < needed / sizeof(HMODULE) && i < 1024; ++i) {
        wchar_t name[MAX_PATH];
        if (GetModuleBaseNameW(GetCurrentProcess(), mods[i], name, MAX_PATH)) out.push_back(narrow(name));
    }
    return out;
}

std::vector<std::string> game_files() {
    std::vector<std::string> out;
    if (g.exe_dir.empty()) return out;
    const int n = MultiByteToWideChar(CP_UTF8, 0, g.exe_dir.c_str(), -1, nullptr, 0);
    std::wstring dir(size_t(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, g.exe_dir.c_str(), -1, dir.data(), n);
    dir.resize(wcslen(dir.c_str()));
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((dir + L"\\*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return out;
    do out.push_back(narrow(fd.cFileName));
    while (FindNextFileW(h, &fd));
    FindClose(h);
    return out;
}

// Файлы рядом с exe не меняются за время игры — читаем один раз; модули — при каждой проверке.
void run_guard() {
    static const std::vector<std::string> files = game_files();
    gfg::GuardInput in{g.exe, g.settings.allowed, loaded_modules(), files};
    g.guard = gfg::check(in);
    if (!g.guard.allowed) {
        reshade::log::message(reshade::log::level::warning, ("GuidForGames: " + g.guard.reason).c_str());
        g.nav.open = false;
        if (g.client) {
            g.client->stop();
            g.client.reset();
        }
    }
}

// Кириллица видна, только если у ReShade шрифт с ней: язык интерфейса русский (Calibri) или свой шрифт.
bool font_lacks_cyrillic() {
    char buf[512];
    size_t size = sizeof(buf);
    if (reshade::get_config_value(nullptr, "STYLE", "Font", buf, &size) && buf[0] != '\0') return false;
    size = sizeof(buf);
    std::string lang;
    if (reshade::get_config_value(nullptr, "OVERLAY", "Language", buf, &size)) lang = buf;
    if (lang.empty()) {
        const LANGID ui = GetUserDefaultUILanguage();
        return PRIMARYLANGID(ui) != LANG_RUSSIAN && PRIMARYLANGID(ui) != LANG_BULGARIAN;
    }
    return lang.rfind("ru", 0) != 0 && lang.rfind("bg", 0) != 0;
}

// ----- контроллер (XInput, подгружается сам) -----

using XInputGetStateFn = DWORD(WINAPI*)(DWORD, XINPUT_STATE*);
XInputGetStateFn xinput_get_state() {
    static XInputGetStateFn fn = [] {
        for (const wchar_t* dll : {L"xinput1_4.dll", L"xinput1_3.dll", L"xinput9_1_0.dll"})
            if (HMODULE m = LoadLibraryW(dll))
                if (auto f = reinterpret_cast<XInputGetStateFn>(
                        reinterpret_cast<void*>(GetProcAddress(m, "XInputGetState"))))
                    return f;
        return XInputGetStateFn(nullptr);
    }();
    return fn;
}

uint32_t gamepad_buttons() {
    auto get = xinput_get_state();
    if (!get) return 0;
    uint32_t out = 0;
    for (DWORD i = 0; i < 4; ++i) {
        XINPUT_STATE st{};
        if (get(i, &st) != ERROR_SUCCESS) continue;
        out |= st.Gamepad.wButtons;
        out |= gfg::stick_to_dpad(st.Gamepad.sThumbLX, st.Gamepad.sThumbLY);
    }
    return out;
}

// ----- ввод -----

void act(gfg::Action a) {
    if (auto cmd = gfg::apply(g.nav, a, g.model); cmd && g.client) g.client->send(*cmd);
    if (a == gfg::Action::Up || a == gfg::Action::Down || a == gfg::Action::TabPrev || a == gfg::Action::TabNext ||
        a == gfg::Action::Toggle)
        g.scroll_to_selected = true;
}

void poll_input(reshade::api::effect_runtime* rt) {
    const Hotkey& hk = g.settings.hotkey;
    if (rt->is_key_pressed(hk.vk) && rt->is_key_down(VK_CONTROL) == hk.ctrl &&
        rt->is_key_down(VK_SHIFT) == hk.shift && rt->is_key_down(VK_MENU) == hk.alt)
        act(gfg::Action::Toggle);

    if (g.settings.gamepad) {
        const uint64_t now = GetTickCount64();
        const uint32_t buttons = gamepad_buttons();
        if (g.combo.update(buttons, now)) act(gfg::Action::Toggle);
        // Пока зажата комбинация, её кнопки не управляют окном; без окна контроллер — только игре.
        const auto actions = g.pad.update(g.combo.holding() ? 0 : buttons, now);
        if (g.nav.open)
            for (auto a : actions) act(a);
    }

    if (!g.nav.open) return;
    struct Key {
        uint32_t vk;
        gfg::Action action;
    };
    static constexpr Key keys[] = {
        {VK_UP, gfg::Action::Up},           {VK_DOWN, gfg::Action::Down},       {VK_LEFT, gfg::Action::TabPrev},
        {VK_RIGHT, gfg::Action::TabNext},   {VK_RETURN, gfg::Action::Confirm},  {VK_SPACE, gfg::Action::Confirm},
        {VK_ESCAPE, gfg::Action::Back},     {VK_BACK, gfg::Action::Back},       {VK_DELETE, gfg::Action::Hide},
    };
    for (const auto& k : keys)
        if (rt->is_key_pressed(k.vk)) act(k.action);
}

// ----- события ReShade -----

void on_init(reshade::api::effect_runtime*) {
    if (g.runtimes++ > 0) return;
    g.settings = load_settings();
    detect_exe();
    run_guard();
    g.next_guard_check = GetTickCount64() + 10000;
    if (!g.guard.allowed) return;
    g.font_note = font_lacks_cyrillic();
    g.client = std::make_unique<gfg::Client>(g.settings.host, g.settings.port, gfg::cmd_game(g.exe));
    g.client->start();
    reshade::log::message(reshade::log::level::info, ("GuidForGames overlay enabled for " + g.exe).c_str());
}

void on_destroy(reshade::api::effect_runtime*) {
    if (--g.runtimes > 0) return;
    if (g.client) {
        g.client->stop();
        g.client.reset();
    }
}

void on_overlay(reshade::api::effect_runtime* rt) {
    if (!g.client) return;
    // Античит может загрузиться позже нас: проверяем снова раз в 10 с.
    if (GetTickCount64() >= g.next_guard_check) {
        g.next_guard_check = GetTickCount64() + 10000;
        run_guard();
        if (!g.client) return;
    }
    if (g.client->version() != g.model_version) {
        g.model = g.client->model(&g.model_version);
        gfg::sync(g.nav, g.model);
    }
    poll_input(rt);
    if (!g.nav.open) return;
    rt->block_input_next_frame();  // клавиатура и мышь — окну, не игре
    gfg::UiView view{.model = g.model, .nav = g.nav};
    view.connected = g.client->connected();
    view.error = g.client->last_error();
    view.font_note = g.font_note;
    view.scroll_to_selected = &g.scroll_to_selected;
    view.send = [](const std::string& cmd) {
        if (g.client) g.client->send(cmd);
    };
    gfg::draw_help_window(view);
}

}  // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    switch (reason) {
        case DLL_PROCESS_ATTACH:
            if (!reshade::register_addon(module)) return FALSE;
            reshade::register_event<reshade::addon_event::init_effect_runtime>(on_init);
            reshade::register_event<reshade::addon_event::destroy_effect_runtime>(on_destroy);
            reshade::register_event<reshade::addon_event::reshade_overlay>(on_overlay);
            break;
        case DLL_PROCESS_DETACH:
            reshade::unregister_addon(module);
            break;
    }
    return TRUE;
}
