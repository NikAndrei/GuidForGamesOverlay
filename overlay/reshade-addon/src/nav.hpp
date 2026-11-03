// Навигация по окну справки: вкладки, список, карточка. Не зависит от ImGui и ReShade.
#pragma once

#include <optional>
#include <string>
#include <vector>

#include "model.hpp"

namespace gfg {

enum class Tab { All, Walkthrough, Puzzles, Collect, Tips, Count };

const char* tab_title(Tab tab);  // по-русски, UTF-8
bool in_tab(const Item& item, Tab tab);

enum class Action {
    Toggle,   // открыть / закрыть окно
    Close,
    Up,
    Down,
    TabPrev,
    TabNext,
    Confirm,  // в списке — открыть карточку, в карточке — раскрыть следующий уровень
    Back,     // из карточки — в список, из списка — закрыть окно
    Hide,     // скрыть раскрытые уровни
};

struct Nav {
    bool open = false;
    Tab tab = Tab::All;
    int selected = 0;      // индекс в visible()
    bool detail = false;   // открыта карточка
    std::string selected_id;  // чтобы выбор не прыгал, когда список обновился
};

// Индексы элементов модели, видимых на вкладке.
std::vector<int> visible(const UiModel& model, Tab tab);

// Выбранный элемент (или nullptr).
const Item* selected_item(const Nav& nav, const UiModel& model);

// Применить действие. Возвращает команду для сервиса, если нужна.
std::optional<std::string> apply(Nav& nav, Action action, const UiModel& model);

// Модель обновилась: сохранить выбор по id, иначе удержать индекс в границах.
void sync(Nav& nav, const UiModel& model);

}  // namespace gfg
