#include "guard.hpp"

#include <algorithm>
#include <cctype>

namespace gfg {

const std::vector<std::string> kDefaultAllowedExe = {"DD2.exe", "re4.exe"};

namespace {

// Признаки античитов: части имён модулей, файлов и папок (без учёта регистра).
const char* const kAntiCheat[] = {
    "easyanticheat", "eac_launcher", "eaanticheat", "beclient", "battleye", "bedaisy", "vgk", "vanguard",
    "xigncode", "gameguard", "npggnt", "nprotect", "faceit", "mhyprot", "anticheatexpert", "ace-base",
    "punkbuster", "pnkbstr", "equ8", "ricochet", "hackshield", "wellbia", "xhunter",
};

std::string lower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return char(std::tolower(c)); });
    return s;
}

const char* anticheat_in(const std::string& name) {
    const std::string n = lower(name);
    for (const char* a : kAntiCheat)
        if (n.find(a) != std::string::npos) return a;
    return nullptr;
}

}  // namespace

GuardResult check(const GuardInput& in) {
    for (const auto* list : {&in.modules, &in.game_files})
        for (const auto& m : *list)
            if (anticheat_in(m)) return {false, "anti-cheat detected (" + m + "), overlay disabled"};
    const std::string exe = lower(in.exe);
    for (const auto& a : in.allowed_exe)
        if (lower(a) == exe) return {true, {}};
    return {false, in.exe + " is not in the allowed games list ([GuidForGames] AllowedExe in ReShade.ini)"};
}

std::vector<std::string> split_list(const std::string& s) {
    std::vector<std::string> out;
    std::string cur;
    auto flush = [&] {
        const auto b = cur.find_first_not_of(" \t");
        const auto e = cur.find_last_not_of(" \t");
        if (b != std::string::npos) out.push_back(cur.substr(b, e - b + 1));
        cur.clear();
    };
    for (char c : s) {
        if (c == ',' || c == ';') flush();
        else cur += c;
    }
    flush();
    return out;
}

}  // namespace gfg
