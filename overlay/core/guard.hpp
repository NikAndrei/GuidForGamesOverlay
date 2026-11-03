// Где оверлею можно работать: белый список игр и блок-лист античитов (CLAUDE.md, «Правила»).
#pragma once

#include <string>
#include <vector>

namespace gfg {

struct GuardInput {
    std::string exe;                       // имя exe игры
    std::vector<std::string> allowed_exe;  // белый список
    std::vector<std::string> modules;      // загруженные в процесс модули (имена файлов)
    std::vector<std::string> game_files;   // файлы и папки рядом с exe
};

struct GuardResult {
    bool allowed = false;
    std::string reason;  // по-английски: показывается в журнале ReShade
};

// Античит в процессе или рядом с exe — запрет без исключений; игра не в белом списке — запрет.
GuardResult check(const GuardInput& in);

// Список "a.exe, b.exe" → {"a.exe", "b.exe"}.
std::vector<std::string> split_list(const std::string& s);

extern const std::vector<std::string> kDefaultAllowedExe;

}  // namespace gfg
