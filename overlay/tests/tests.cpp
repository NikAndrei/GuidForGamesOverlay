// Тесты ядра аддона (без Windows и ReShade): ctest или ./gfg_tests.
#include <cstdio>
#include <string>

#include "guard.hpp"
#include "input.hpp"
#include "model.hpp"
#include "nav.hpp"

static int failures = 0;
#define CHECK(cond)                                                          \
    do {                                                                     \
        if (!(cond)) {                                                       \
            std::printf("%s:%d: FAILED: %s\n", __FILE__, __LINE__, #cond);   \
            ++failures;                                                      \
        }                                                                    \
    } while (0)

using namespace gfg;

static const char* kUi = R"json({"type":"ui","ui":{
  "game":"re4-remake","title":{"ru":"Resident Evil 4 (ремейк)","en":"Resident Evil 4"},
  "source":"mod","updatedAt":"2026-11-03T08:00:00Z","items":[
   {"id":"wv-1","kind":"quest","title":{"ru":"Найти ключ","en":"Find the key"},"location":{"ru":"Деревня","en":"Village"},
    "levels":3,"revealed":1,"hints":["Намёк"],"sources":["https://example.com"]},
   {"id":"pz-1","kind":"puzzle","title":{"ru":"Загадка","en":"Puzzle"},"levels":2,"revealed":0,"hints":[]},
   {"id":"tr-1","kind":"secret","title":{"ru":"Сокровище"},"levels":1,"revealed":0,"hints":[],
    "missable":true,"missableNote":"До главы 3"}
  ]}})json";

static void test_parse() {
    Message m = parse_message(kUi);
    CHECK(m.type == MessageType::Ui);
    CHECK(m.ui.game == "re4-remake");
    CHECK(m.ui.items.size() == 3);
    CHECK(m.ui.items[0].location && m.ui.items[0].location->ru == "Деревня");
    CHECK(m.ui.items[0].hints.size() == 1);
    CHECK(m.ui.items[2].missable && m.ui.items[2].missable_note == "До главы 3");
    CHECK(m.ui.items[2].title.en.empty());

    CHECK(parse_message(R"({"type":"hello","protocol":1})").protocol == 1);
    Message e = parse_message(R"({"type":"error","message":"нет подсказки x"})");
    CHECK(e.type == MessageType::Error && e.error == "нет подсказки x");
    CHECK(parse_message("not json").type == MessageType::Unknown);
    CHECK(parse_message(R"({"type":"other"})").type == MessageType::Unknown);

    CHECK(cmd_reveal("wv-1") == R"({"cmd":"reveal","item":"wv-1"})");
    CHECK(cmd_game("DD2.exe") == R"({"cmd":"game","exe":"DD2.exe"})");
}

static void test_nav() {
    UiModel model = parse_message(kUi).ui;
    Nav nav;
    CHECK(!apply(nav, Action::Down, model));  // закрыто — ничего не происходит
    CHECK(nav.selected == 0);
    apply(nav, Action::Toggle, model);
    CHECK(nav.open && !nav.detail);
    CHECK(nav.selected_id == "wv-1");

    apply(nav, Action::Down, model);
    apply(nav, Action::Down, model);
    apply(nav, Action::Down, model);  // упирается в конец
    CHECK(nav.selected == 2 && nav.selected_id == "tr-1");
    apply(nav, Action::Up, model);
    CHECK(nav.selected_id == "pz-1");

    // Confirm: открыть карточку, затем раскрыть уровень.
    CHECK(!apply(nav, Action::Confirm, model));
    CHECK(nav.detail);
    auto cmd = apply(nav, Action::Confirm, model);
    CHECK(cmd && *cmd == cmd_reveal("pz-1"));
    CHECK(!apply(nav, Action::Hide, model));  // нечего скрывать
    apply(nav, Action::Back, model);
    CHECK(!nav.detail && nav.open);

    // Вкладки: «Загадки» — одна запись; по кругу назад от «Всё» — «Советы».
    apply(nav, Action::TabNext, model);
    CHECK(nav.tab == Tab::Walkthrough && visible(model, nav.tab).size() == 1);
    apply(nav, Action::TabNext, model);
    CHECK(nav.tab == Tab::Puzzles && selected_item(nav, model)->id == "pz-1");
    apply(nav, Action::TabPrev, model);
    apply(nav, Action::TabPrev, model);
    apply(nav, Action::TabPrev, model);
    CHECK(nav.tab == Tab::Tips && selected_item(nav, model) == nullptr);
    CHECK(!apply(nav, Action::Confirm, model));  // пустая вкладка

    // Раскрытый уровень: Hide даёт команду.
    nav.tab = Tab::All;
    nav.selected = 0;
    nav.selected_id = "wv-1";
    nav.detail = true;
    cmd = apply(nav, Action::Hide, model);
    CHECK(cmd && *cmd == cmd_hide("wv-1"));

    apply(nav, Action::Back, model);
    apply(nav, Action::Back, model);
    CHECK(!nav.open);
}

static void test_sync() {
    UiModel model = parse_message(kUi).ui;
    Nav nav;
    apply(nav, Action::Toggle, model);
    apply(nav, Action::Down, model);  // pz-1
    nav.detail = true;
    // Новая модель: сверху добавилась запись — выбор остаётся на pz-1.
    UiModel m2 = model;
    m2.items.insert(m2.items.begin(), Item{"new", "quest", {"Новое", ""}, {}, 1, 0, {}, false, "", {}});
    sync(nav, m2);
    CHECK(nav.selected == 2 && nav.detail);
    // pz-1 сделан в игре и пропал — карточка закрывается, индекс в границах.
    UiModel m3 = m2;
    m3.items.erase(m3.items.begin() + 2);
    m3.items.pop_back();
    sync(nav, m3);
    CHECK(!nav.detail && nav.selected == 1);
    // Пустая модель.
    sync(nav, UiModel{});
    CHECK(nav.selected == 0 && selected_item(nav, UiModel{}) == nullptr);
}

static void test_input() {
    Combo combo;  // View + R3, 500 мс
    CHECK(!combo.update(View, 100));
    CHECK(!combo.update(View | R3, 200));
    CHECK(combo.holding());
    CHECK(!combo.update(View | R3, 600));
    CHECK(combo.update(View | R3, 700));   // 500 мс прошло
    CHECK(!combo.update(View | R3, 2000));  // один раз до отпускания
    CHECK(!combo.update(0, 2100));
    CHECK(!combo.holding());
    CHECK(!combo.update(View | R3, 3000));
    CHECK(combo.update(View | R3, 3500));

    GamepadNav pad;
    auto a = pad.update(A | RB, 0);
    CHECK(a.size() == 2 && a[0] == Action::Confirm && a[1] == Action::TabNext);
    CHECK(pad.update(A | RB, 10).empty());  // держат — не повторяется
    a = pad.update(DpadDown, 100);
    CHECK(a.size() == 1 && a[0] == Action::Down);
    CHECK(pad.update(DpadDown, 300).empty());
    CHECK(pad.update(DpadDown, 500).size() == 1);  // автоповтор после 400 мс
    CHECK(pad.update(DpadDown, 550).empty());
    CHECK(pad.update(DpadDown, 620).size() == 1);
    CHECK(pad.update(0, 700).empty());

    CHECK(stick_to_dpad(0, 30000) == DpadUp);
    CHECK(stick_to_dpad(0, -30000) == DpadDown);
    CHECK(stick_to_dpad(30000, 20000) == DpadRight);
    CHECK(stick_to_dpad(1000, -1000) == 0);
}

static void test_guard() {
    GuardInput in{"DD2.exe", kDefaultAllowedExe, {"kernel32.dll", "dxgi.dll"}, {"reframework", "DD2.exe"}};
    CHECK(check(in).allowed);
    in.exe = "dd2.EXE";
    CHECK(check(in).allowed);
    in.exe = "eldenring.exe";
    CHECK(!check(in).allowed);
    in.exe = "re4.exe";
    in.modules.push_back("EasyAntiCheat_EOS.dll");
    GuardResult r = check(in);
    CHECK(!r.allowed && r.reason.find("anti-cheat") != std::string::npos);
    in.modules.pop_back();
    in.game_files.push_back("BattlEye");
    CHECK(!check(in).allowed);

    auto l = split_list(" DD2.exe, re4.exe ;; game.exe ");
    CHECK(l.size() == 3 && l[0] == "DD2.exe" && l[2] == "game.exe");
}

int main() {
    test_parse();
    test_nav();
    test_sync();
    test_input();
    test_guard();
    if (failures) {
        std::printf("%d failure(s)\n", failures);
        return 1;
    }
    std::printf("all tests passed\n");
    return 0;
}
