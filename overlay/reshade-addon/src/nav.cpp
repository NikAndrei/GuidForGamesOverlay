#include "nav.hpp"

#include <algorithm>

namespace gfg {

const char* tab_title(Tab tab) {
    switch (tab) {
        case Tab::All: return "Всё";
        case Tab::Walkthrough: return "Прохождение";
        case Tab::Puzzles: return "Загадки";
        case Tab::Collect: return "Собирательство";
        case Tab::Tips: return "Советы";
        default: return "";
    }
}

bool in_tab(const Item& item, Tab tab) {
    const std::string& k = item.kind;
    switch (tab) {
        case Tab::All: return true;
        case Tab::Walkthrough: return k == "quest" || k == "boss" || k == "ending";
        case Tab::Puzzles: return k == "puzzle";
        case Tab::Collect:
            return k == "secret" || k == "chest" || k == "file" || k == "seeker-token" || k == "achievement";
        case Tab::Tips: return k == "tip";
        default: return false;
    }
}

std::vector<int> visible(const UiModel& model, Tab tab) {
    std::vector<int> out;
    for (int i = 0; i < static_cast<int>(model.items.size()); ++i)
        if (in_tab(model.items[i], tab)) out.push_back(i);
    return out;
}

const Item* selected_item(const Nav& nav, const UiModel& model) {
    const auto vis = visible(model, nav.tab);
    if (nav.selected < 0 || nav.selected >= static_cast<int>(vis.size())) return nullptr;
    return &model.items[vis[nav.selected]];
}

namespace {

void remember(Nav& nav, const UiModel& model) {
    const Item* it = selected_item(nav, model);
    nav.selected_id = it ? it->id : std::string();
}

void select(Nav& nav, const UiModel& model, int index) {
    const int n = static_cast<int>(visible(model, nav.tab).size());
    nav.selected = n == 0 ? 0 : std::clamp(index, 0, n - 1);
    remember(nav, model);
}

void switch_tab(Nav& nav, const UiModel& model, int delta) {
    const int count = static_cast<int>(Tab::Count);
    nav.tab = static_cast<Tab>((static_cast<int>(nav.tab) + delta + count) % count);
    nav.detail = false;
    select(nav, model, 0);
}

}  // namespace

std::optional<std::string> apply(Nav& nav, Action action, const UiModel& model) {
    if (action == Action::Toggle) {
        nav.open = !nav.open;
        nav.detail = false;
        sync(nav, model);
        return std::nullopt;
    }
    if (!nav.open) return std::nullopt;

    switch (action) {
        case Action::Close: nav.open = false; break;
        case Action::Up: select(nav, model, nav.selected - 1); break;
        case Action::Down: select(nav, model, nav.selected + 1); break;
        case Action::TabPrev: switch_tab(nav, model, -1); break;
        case Action::TabNext: switch_tab(nav, model, +1); break;
        case Action::Confirm: {
            const Item* it = selected_item(nav, model);
            if (!it) break;
            if (!nav.detail) {
                nav.detail = true;
                break;
            }
            if (it->revealed < it->levels) return cmd_reveal(it->id);
            break;
        }
        case Action::Back:
            if (nav.detail) nav.detail = false;
            else nav.open = false;
            break;
        case Action::Hide: {
            const Item* it = selected_item(nav, model);
            if (it && nav.detail && it->revealed > 0) return cmd_hide(it->id);
            break;
        }
        default: break;
    }
    return std::nullopt;
}

void sync(Nav& nav, const UiModel& model) {
    const auto vis = visible(model, nav.tab);
    if (!nav.selected_id.empty()) {
        for (int i = 0; i < static_cast<int>(vis.size()); ++i) {
            if (model.items[vis[i]].id == nav.selected_id) {
                nav.selected = i;
                return;
            }
        }
        // Выбранное пропало (сделано в игре): карточку закрываем, остаёмся на том же месте списка.
        nav.detail = false;
    }
    select(nav, model, nav.selected);
}

}  // namespace gfg
