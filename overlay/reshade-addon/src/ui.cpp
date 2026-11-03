#include "ui.hpp"

#ifdef GFG_RESHADE
#include <windows.h>
#endif
#include <imgui.h>
#ifdef GFG_RESHADE
// В аддоне функции ImGui вызываются через таблицу ReShade (reshade_overlay.hpp).
#include <reshade.hpp>
#endif

#include <cstdio>

namespace gfg {
namespace {

const ImVec4 kAccent(0.36f, 0.56f, 0.95f, 1.0f);
const ImVec4 kWarn(0.98f, 0.70f, 0.25f, 1.0f);
const char* const kLevelNames[] = {"Намёк", "Подробнее", "Ответ"};

// Название следующего уровня: последний — всегда «Ответ».
const char* next_level_name(int revealed, int levels) {
    if (levels > 1 && revealed + 1 == levels) return "Ответ";
    return revealed < 2 ? kLevelNames[revealed] : "Дальше";
}

const char* level_title(int i, int levels) {
    if (levels > 1 && i + 1 == levels) return "Ответ";
    return i < 2 ? kLevelNames[i] : "Ещё";
}

void muted(const char* text) {
    ImGui::PushTextWrapPos(0.0f);
    ImGui::TextDisabled("%s", text);
    ImGui::PopTextWrapPos();
}

void draw_card(UiView& v, const Item& it) {
    ImGui::PushTextWrapPos(0.0f);
    ImGui::TextUnformatted(it.title.ru.c_str());
    if (!it.title.en.empty() && it.title.en != it.title.ru) ImGui::TextDisabled("%s", it.title.en.c_str());
    if (it.location) ImGui::TextDisabled("%s", it.location->ru.c_str());
    if (it.missable)
        ImGui::TextColored(kWarn, "Можно пропустить%s%s", it.missable_note.empty() ? "" : ": ",
                           it.missable_note.c_str());
    ImGui::Separator();
    for (int i = 0; i < static_cast<int>(it.hints.size()); ++i) {
        ImGui::TextColored(kAccent, "%s", level_title(i, it.levels));
        ImGui::TextWrapped("%s", it.hints[i].c_str());
        ImGui::Spacing();
    }
    if (it.revealed < it.levels) {
        char label[96];
        std::snprintf(label, sizeof(label), "%s (%d из %d)", next_level_name(it.revealed, it.levels), it.revealed + 1,
                      it.levels);
        if (ImGui::Button(label) && v.send) {
            v.nav.detail = true;
            v.send(cmd_reveal(it.id));
        }
    } else {
        ImGui::TextDisabled("Всё раскрыто");
    }
    if (it.revealed > 0) {
        ImGui::SameLine();
        if (ImGui::SmallButton("Скрыть") && v.send) v.send(cmd_hide(it.id));
        if (!it.sources.empty()) {
            ImGui::Spacing();
            ImGui::TextDisabled("Источник: %s", it.sources.front().c_str());
        }
    } else if (!v.nav.detail) {
        ImGui::Spacing();
        ImGui::TextDisabled("A / Enter — открыть карточку");
    }
    ImGui::PopTextWrapPos();
}

void draw_tabs(UiView& v) {
    for (int t = 0; t < static_cast<int>(Tab::Count); ++t) {
        const auto tab = static_cast<Tab>(t);
        char label[96];
        std::snprintf(label, sizeof(label), "%s (%zu)###tab%d", tab_title(tab), visible(v.model, tab).size(), t);
        const bool cur = v.nav.tab == tab;
        if (t > 0) ImGui::SameLine();
        if (cur) ImGui::PushStyleColor(ImGuiCol_Button, kAccent);
        const bool clicked = ImGui::Button(label);
        if (cur) ImGui::PopStyleColor(1);
        if (clicked) {
            v.nav.tab = tab;
            v.nav.detail = false;
            v.nav.selected = 0;
            v.nav.selected_id.clear();
            sync(v.nav, v.model);
        }
    }
}

void draw_list(UiView& v, const std::vector<int>& vis) {
    if (vis.empty()) muted("Здесь сейчас пусто.");
    for (int i = 0; i < static_cast<int>(vis.size()); ++i) {
        const Item& it = v.model.items[vis[i]];
        std::string label = (it.missable ? "(!) " : "") + it.title.ru;
        if (it.revealed > 0) label += "  " + std::to_string(it.revealed) + "/" + std::to_string(it.levels);
        label += "###" + it.id;
        const bool sel = i == v.nav.selected;
        if (ImGui::Selectable(label.c_str(), sel, 0, ImVec2(0, 0))) {
            v.nav.selected = i;
            v.nav.selected_id = it.id;
            v.nav.detail = true;
        }
        if (sel && v.scroll_to_selected && *v.scroll_to_selected) {
            ImGui::SetScrollHereY(0.5f);
            *v.scroll_to_selected = false;
        }
    }
}

}  // namespace

void draw_help_window(UiView& v) {
    ImGuiIO& io = ImGui::GetIO();
    const ImVec2 size(io.DisplaySize.x * 0.62f, io.DisplaySize.y * 0.72f);
    ImGui::SetNextWindowPos(ImVec2((io.DisplaySize.x - size.x) * 0.5f, (io.DisplaySize.y - size.y) * 0.5f),
                            ImGuiCond_Appearing, ImVec2(0, 0));
    ImGui::SetNextWindowSize(size, ImGuiCond_Appearing);
    ImGui::SetNextWindowBgAlpha(0.95f);
    bool open = true;
    if (ImGui::Begin("Справка по игре###gfg-help", &open,
                     ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoSavedSettings)) {
        if (v.font_note) {
            ImGui::PushTextWrapPos(0.0f);
            ImGui::TextColored(kWarn,
                               "Russian text needs a font with Cyrillic: ReShade > Settings > Global font = "
                               "C:\\Windows\\Fonts\\segoeui.ttf (or set ReShade language to Russian), then restart.");
            ImGui::PopTextWrapPos();
        }
        const float footer = ImGui::GetTextLineHeightWithSpacing() * 2.3f;
        if (!v.connected) {
            muted("Нет связи с сервисом. Запустите gfg-service.exe — окно подключится само.");
            if (!v.error.empty()) muted(v.error.c_str());
        } else if (v.model.game.empty()) {
            muted("Сервис не знает эту игру или ещё не получил данных.");
            if (!v.error.empty()) muted(v.error.c_str());
        } else {
            ImGui::TextColored(kAccent, "%s", v.model.title.ru.c_str());
            if (!v.model.source.empty()) {
                ImGui::SameLine();
                ImGui::TextDisabled("%s", v.model.source == "mod" ? "· по моду-мосту" : "· по сохранению");
            }
            draw_tabs(v);
            ImGui::Separator();

            const ImVec2 avail = ImGui::GetContentRegionAvail();
            const float height = avail.y - footer > 50.0f ? avail.y - footer : 50.0f;
            const auto vis = visible(v.model, v.nav.tab);
            ImGui::BeginChild("list", ImVec2(avail.x * 0.42f, height), ImGuiChildFlags_Borders, 0);
            draw_list(v, vis);
            ImGui::EndChild();
            ImGui::SameLine();
            ImGui::BeginChild("card", ImVec2(0, height), ImGuiChildFlags_Borders, 0);
            if (const Item* it = selected_item(v.nav, v.model)) draw_card(v, *it);
            else if (v.model.items.empty())
                muted("Сейчас подсказок нет. Если мод-мост не установлен — запустите gfg-service install-mods.");
            ImGui::EndChild();
        }
        muted(v.nav.detail ? "A / Enter — раскрыть дальше · Y / Del — скрыть · B / Esc — к списку"
                           : "A / Enter — открыть · ↑↓ — выбор · LB RB / ←→ — вкладки · B / Esc — закрыть");
        muted("Контроллер в это время слышит и игра — лучше открывать справку на паузе.");
    }
    ImGui::End();
    if (!open) v.nav.open = false;
}

}  // namespace gfg
