// GuidForGames Overlay — запасной путь: прозрачное окно поверх игры (без внедрения в игру).
// Окно справки — то же, что в аддоне ReShade (core/ui.cpp), рисуется своим ImGui через DirectX 11.
//
// Пока справка закрыта, окно спрятано и ничему не мешает. Shift+F1 (или View+R3 на контроллере) — окно
// разворачивается на мониторе игры, забирает фокус; Esc / B / клик мимо справки — прячется и возвращает фокус игре.
// Работает с играми в окне или окне без рамки; поверх эксклюзивного полноэкранного режима не видно.

#include <windows.h>
#include <d3d11.h>
#include <dwmapi.h>
#include <shellapi.h>
#include <xinput.h>

#include <imgui.h>
#include <imgui_impl_dx11.h>
#include <imgui_impl_win32.h>

#include <memory>
#include <string>

#include "client.hpp"
#include "input.hpp"
#include "model.hpp"
#include "nav.hpp"
#include "ui.hpp"

extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(HWND, UINT, WPARAM, LPARAM);

namespace {

constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTrayOpen = 1, kTrayExit = 2;
constexpr int kHotkeyId = 1;

struct Settings {
    std::wstring host = L"127.0.0.1";
    int port = 7871;
    UINT hotkey_vk = VK_F1;
    UINT hotkey_mod = MOD_SHIFT;
    bool gamepad = true;
    std::wstring font = L"C:\\Windows\\Fonts\\segoeui.ttf";
    float font_size = 19.0f;
};

struct App {
    Settings settings;
    HWND hwnd = nullptr;
    HWND game = nullptr;  // окно, которое было активным до открытия справки
    std::string game_exe;
    ID3D11Device* device = nullptr;
    ID3D11DeviceContext* context = nullptr;
    IDXGISwapChain* swapchain = nullptr;
    ID3D11RenderTargetView* rtv = nullptr;
    std::unique_ptr<gfg::Client> client;
    gfg::Nav nav;
    gfg::UiModel model;
    uint64_t model_version = 0;
    gfg::Combo combo;
    gfg::GamepadNav pad;
    bool scroll = false;
    bool running = true;
    NOTIFYICONDATAW tray{};
} app;

// ----- настройки: gfg-window.ini рядом с программой -----

std::wstring exe_dir() {
    wchar_t path[MAX_PATH] = {};
    GetModuleFileNameW(nullptr, path, MAX_PATH);
    std::wstring p(path);
    return p.substr(0, p.find_last_of(L"\\/"));
}

Settings load_settings() {
    Settings s;
    const std::wstring ini = exe_dir() + L"\\gfg-window.ini";
    wchar_t buf[512];
    GetPrivateProfileStringW(L"GuidForGames", L"Host", s.host.c_str(), buf, 512, ini.c_str());
    s.host = buf;
    s.port = int(GetPrivateProfileIntW(L"GuidForGames", L"Port", s.port, ini.c_str()));
    // Как в аддоне: код клавиши, Ctrl, Shift, Alt.
    GetPrivateProfileStringW(L"GuidForGames", L"Hotkey", L"112,0,1,0", buf, 512, ini.c_str());
    unsigned vk = 0, c = 0, sh = 0, a = 0;
    if (swscanf_s(buf, L"%u,%u,%u,%u", &vk, &c, &sh, &a) >= 1 && vk) {
        s.hotkey_vk = vk;
        s.hotkey_mod = (c ? MOD_CONTROL : 0) | (sh ? MOD_SHIFT : 0) | (a ? MOD_ALT : 0);
    }
    s.gamepad = GetPrivateProfileIntW(L"GuidForGames", L"GamepadCombo", 1, ini.c_str()) != 0;
    GetPrivateProfileStringW(L"GuidForGames", L"Font", s.font.c_str(), buf, 512, ini.c_str());
    s.font = buf;
    s.font_size = float(GetPrivateProfileIntW(L"GuidForGames", L"FontSize", int(s.font_size), ini.c_str()));
    return s;
}

std::string narrow(const std::wstring& w) {
    if (w.empty()) return {};
    const int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), int(w.size()), nullptr, 0, nullptr, nullptr);
    std::string out(size_t(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), int(w.size()), out.data(), n, nullptr, nullptr);
    return out;
}

// Имя exe процесса, которому принадлежит окно.
std::string exe_of(HWND w) {
    DWORD pid = 0;
    GetWindowThreadProcessId(w, &pid);
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!h) return {};
    wchar_t path[MAX_PATH];
    DWORD size = MAX_PATH;
    std::string out;
    if (QueryFullProcessImageNameW(h, 0, path, &size)) {
        std::wstring p(path, size);
        out = narrow(p.substr(p.find_last_of(L"\\/") + 1));
    }
    CloseHandle(h);
    return out;
}

// ----- DirectX 11 -----

void create_rtv() {
    ID3D11Texture2D* back = nullptr;
    app.swapchain->GetBuffer(0, IID_PPV_ARGS(&back));
    if (back) {
        app.device->CreateRenderTargetView(back, nullptr, &app.rtv);
        back->Release();
    }
}

void release_rtv() {
    if (app.rtv) {
        app.rtv->Release();
        app.rtv = nullptr;
    }
}

bool create_device() {
    DXGI_SWAP_CHAIN_DESC sd{};
    sd.BufferCount = 2;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = app.hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_0};
    D3D_FEATURE_LEVEL got;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, levels, 2,
                                               D3D11_SDK_VERSION, &sd, &app.swapchain, &app.device, &got, &app.context);
    if (hr == DXGI_ERROR_UNSUPPORTED)  // нет видеокарты с DX11 — программная отрисовка
        hr = D3D11CreateDeviceAndSwapChain(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, 0, levels, 2, D3D11_SDK_VERSION, &sd,
                                           &app.swapchain, &app.device, &got, &app.context);
    if (FAILED(hr)) return false;
    create_rtv();
    return true;
}

void destroy_device() {
    release_rtv();
    if (app.swapchain) app.swapchain->Release();
    if (app.context) app.context->Release();
    if (app.device) app.device->Release();
}

// ----- открыть / спрятать -----

void bring_to_front(HWND w) {
    // Фокус другому процессу Windows даёт не всегда (вызов с контроллера — не «ввод пользователя» для нас):
    // временно присоединяемся к потоку активного окна.
    const HWND fg = GetForegroundWindow();
    const DWORD fg_thread = fg ? GetWindowThreadProcessId(fg, nullptr) : 0;
    const DWORD me = GetCurrentThreadId();
    if (fg_thread && fg_thread != me) AttachThreadInput(fg_thread, me, TRUE);
    SetForegroundWindow(w);
    SetFocus(w);
    if (fg_thread && fg_thread != me) AttachThreadInput(fg_thread, me, FALSE);
}

// detect_game — вызов из игры (клавиша, контроллер): активное окно — игра. Из трея активна панель задач — игру не трогаем.
void show_help(bool detect_game = true) {
    if (app.nav.open) return;
    const HWND fg = GetForegroundWindow();
    if (detect_game && fg && fg != app.hwnd) {
        app.game = fg;
        const std::string exe = exe_of(fg);
        if (!exe.empty() && exe != app.game_exe) {
            app.game_exe = exe;
            app.client->set_hello(gfg::cmd_game(exe));  // и после переподключения
            app.client->send(gfg::cmd_game(exe));
        }
    }
    // На весь монитор игры.
    MONITORINFO mi{};
    mi.cbSize = sizeof(mi);
    GetMonitorInfoW(MonitorFromWindow(app.game ? app.game : app.hwnd, MONITOR_DEFAULTTOPRIMARY), &mi);
    const RECT r = mi.rcMonitor;
    SetWindowPos(app.hwnd, HWND_TOPMOST, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_SHOWWINDOW);
    bring_to_front(app.hwnd);
    gfg::apply(app.nav, gfg::Action::Toggle, app.model);
    app.scroll = true;
}

void hide_help() {
    app.nav.open = false;
    ShowWindow(app.hwnd, SW_HIDE);
    if (app.game && IsWindow(app.game)) bring_to_front(app.game);
}

void act(gfg::Action a) {
    if (a == gfg::Action::Toggle) {
        app.nav.open ? hide_help() : show_help();
        return;
    }
    if (auto cmd = gfg::apply(app.nav, a, app.model)) app.client->send(*cmd);
    if (!app.nav.open) hide_help();
    if (a == gfg::Action::Up || a == gfg::Action::Down || a == gfg::Action::TabPrev || a == gfg::Action::TabNext)
        app.scroll = true;
}

// ----- контроллер -----

using XInputGetStateFn = DWORD(WINAPI*)(DWORD, XINPUT_STATE*);
uint32_t gamepad_buttons() {
    static XInputGetStateFn get = [] {
        for (const wchar_t* dll : {L"xinput1_4.dll", L"xinput1_3.dll", L"xinput9_1_0.dll"})
            if (HMODULE m = LoadLibraryW(dll))
                if (auto f = reinterpret_cast<XInputGetStateFn>(reinterpret_cast<void*>(GetProcAddress(m, "XInputGetState"))))
                    return f;
        return XInputGetStateFn(nullptr);
    }();
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

void poll_gamepad() {
    if (!app.settings.gamepad) return;
    const uint64_t now = GetTickCount64();
    const uint32_t buttons = gamepad_buttons();
    if (app.combo.update(buttons, now)) act(gfg::Action::Toggle);
    const auto actions = app.pad.update(app.combo.holding() ? 0 : buttons, now);
    if (app.nav.open)
        for (auto a : actions) act(a);
}

// ----- значок в трее -----

void add_tray() {
    app.tray.cbSize = sizeof(app.tray);
    app.tray.hWnd = app.hwnd;
    app.tray.uID = 1;
    app.tray.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    app.tray.uCallbackMessage = kTrayMessage;
    app.tray.hIcon = LoadIconW(nullptr, IDI_INFORMATION);
    wcscpy_s(app.tray.szTip, L"Справка по игре (Shift+F1)");
    Shell_NotifyIconW(NIM_ADD, &app.tray);
}

void tray_menu() {
    HMENU menu = CreatePopupMenu();
    AppendMenuW(menu, MF_STRING, kTrayOpen, L"Открыть справку");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, kTrayExit, L"Выход");
    POINT pt;
    GetCursorPos(&pt);
    SetForegroundWindow(app.hwnd);
    const UINT cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x, pt.y, 0, app.hwnd, nullptr);
    DestroyMenu(menu);
    if (cmd == kTrayOpen) show_help(false);
    if (cmd == kTrayExit) app.running = false;
}

// ----- окно -----

gfg::Action key_action(WPARAM vk, bool* ok) {
    *ok = true;
    switch (vk) {
        case VK_UP: return gfg::Action::Up;
        case VK_DOWN: return gfg::Action::Down;
        case VK_LEFT: return gfg::Action::TabPrev;
        case VK_RIGHT: return gfg::Action::TabNext;
        case VK_RETURN:
        case VK_SPACE: return gfg::Action::Confirm;
        case VK_ESCAPE:
        case VK_BACK: return gfg::Action::Back;
        case VK_DELETE: return gfg::Action::Hide;
        default: *ok = false; return gfg::Action::Close;
    }
}

LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (ImGui_ImplWin32_WndProcHandler(hwnd, msg, wp, lp)) return 1;
    switch (msg) {
        case WM_HOTKEY:
            if (wp == kHotkeyId) act(gfg::Action::Toggle);
            return 0;
        case WM_KEYDOWN: {
            bool ok = false;
            const gfg::Action a = key_action(wp, &ok);
            if (ok && app.nav.open) act(a);
            return 0;
        }
        case WM_SIZE:
            if (app.device && wp != SIZE_MINIMIZED) {
                release_rtv();
                app.swapchain->ResizeBuffers(0, LOWORD(lp), HIWORD(lp), DXGI_FORMAT_UNKNOWN, 0);
                create_rtv();
            }
            return 0;
        case WM_ACTIVATE:
            // Переключились в другое окно (Alt+Tab) — справку прячем.
            if (LOWORD(wp) == WA_INACTIVE && app.nav.open) {
                app.nav.open = false;
                ShowWindow(hwnd, SW_HIDE);
            }
            return 0;
        case kTrayMessage:
            if (LOWORD(lp) == WM_RBUTTONUP) tray_menu();
            if (LOWORD(lp) == WM_LBUTTONUP) show_help(false);
            return 0;
        case WM_CLOSE: app.running = false; return 0;
        case WM_DESTROY: PostQuitMessage(0); return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

}  // namespace

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR cmdline, int) {
    // Один экземпляр.
    HANDLE mutex = CreateMutexW(nullptr, TRUE, L"GuidForGamesOverlayWindow");
    if (GetLastError() == ERROR_ALREADY_EXISTS) return 0;

    ImGui_ImplWin32_EnableDpiAwareness();
    app.settings = load_settings();

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = L"GuidForGamesOverlayWindow";
    RegisterClassExW(&wc);
    // Без рамки, поверх всех, без кнопки на панели задач.
    app.hwnd = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, wc.lpszClassName, L"Справка по игре", WS_POPUP, 0, 0,
                               1280, 720, nullptr, nullptr, inst, nullptr);
    ImGui_ImplWin32_EnableAlphaCompositing(app.hwnd);  // прозрачный фон через DWM
    if (!create_device()) {
        MessageBoxW(nullptr, L"Не удалось создать устройство DirectX 11.", L"GuidForGames", MB_ICONERROR);
        return 1;
    }

    if (!RegisterHotKey(app.hwnd, kHotkeyId, app.settings.hotkey_mod | MOD_NOREPEAT, app.settings.hotkey_vk))
        MessageBoxW(nullptr, L"Клавиша вызова уже занята другой программой: поменяйте Hotkey в gfg-window.ini.",
                    L"GuidForGames", MB_ICONWARNING);
    add_tray();

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = nullptr;
    // Навигацией управляет общий код (nav.cpp), своей навигации ImGui не нужно.
    io.ConfigFlags &= ~(ImGuiConfigFlags_NavEnableKeyboard | ImGuiConfigFlags_NavEnableGamepad);
    ImGui::StyleColorsDark();
    const float dpi = ImGui_ImplWin32_GetDpiScaleForHwnd(app.hwnd);
    ImGui::GetStyle().ScaleAllSizes(dpi);
    const std::string font = narrow(app.settings.font);
    if (!io.Fonts->AddFontFromFileTTF(font.c_str(), app.settings.font_size * dpi)) io.Fonts->AddFontDefault();
    ImGui_ImplWin32_Init(app.hwnd);
    ImGui_ImplDX11_Init(app.device, app.context);

    app.client = std::make_unique<gfg::Client>(narrow(app.settings.host), uint16_t(app.settings.port), std::string());
    app.client->start();
    // gfg-window.exe --open — сразу открыть справку (ярлык, проверка).
    if (cmdline && wcsstr(cmdline, L"--open")) show_help(false);

    while (app.running) {
        MSG msg;
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
            if (msg.message == WM_QUIT) app.running = false;
        }
        if (app.client->version() != app.model_version) {
            app.model = app.client->model(&app.model_version);
            gfg::sync(app.nav, app.model);
        }
        poll_gamepad();
        if (!app.nav.open) {
            Sleep(16);  // спрятано: только опрос контроллера и сообщений
            continue;
        }

        ImGui_ImplDX11_NewFrame();
        ImGui_ImplWin32_NewFrame();
        ImGui::NewFrame();
        gfg::UiView view{.model = app.model, .nav = app.nav};
        view.connected = app.client->connected();
        view.error = app.client->last_error();
        view.scroll_to_selected = &app.scroll;
        view.send = [](const std::string& c) { app.client->send(c); };
        view.note = "Игра — под окном. Esc / B / клик мимо справки — вернуться в игру.";
        gfg::draw_help_window(view);
        // Клик мимо справки — вернуться в игру.
        if (ImGui::IsMouseClicked(ImGuiMouseButton_Left) && !io.WantCaptureMouse)
            app.nav.open = false;
        ImGui::Render();
        if (!app.nav.open) {
            hide_help();
            continue;
        }

        // Лёгкое затемнение игры под справкой; DWM смешивает с premultiplied alpha.
        const float clear[4] = {0.0f, 0.0f, 0.0f, 0.35f};
        app.context->OMSetRenderTargets(1, &app.rtv, nullptr);
        app.context->ClearRenderTargetView(app.rtv, clear);
        ImGui_ImplDX11_RenderDrawData(ImGui::GetDrawData());
        app.swapchain->Present(1, 0);
    }

    app.client->stop();
    Shell_NotifyIconW(NIM_DELETE, &app.tray);
    UnregisterHotKey(app.hwnd, kHotkeyId);
    ImGui_ImplDX11_Shutdown();
    ImGui_ImplWin32_Shutdown();
    ImGui::DestroyContext();
    destroy_device();
    DestroyWindow(app.hwnd);
    ReleaseMutex(mutex);
    return 0;
}
