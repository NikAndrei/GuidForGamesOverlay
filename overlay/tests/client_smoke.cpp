// Проверка связи с запущенным сервисом: gfg_client_smoke <порт> <exe> [reveal-id]
// Печатает модель UI, при reveal-id раскрывает уровень и ждёт обновления.
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <thread>

#include "client.hpp"

int main(int argc, char** argv) {
    if (argc < 3) {
        std::printf("usage: gfg_client_smoke <port> <exe> [reveal-id]\n");
        return 2;
    }
    gfg::Client client("127.0.0.1", static_cast<uint16_t>(std::atoi(argv[1])), gfg::cmd_game(argv[2]));
    client.start();
    auto wait_version = [&](uint64_t after) {
        for (int i = 0; i < 100 && client.version() <= after; ++i)
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        return client.version() > after;
    };
    if (!wait_version(0)) {
        std::printf("no model: %s\n", client.last_error().c_str());
        return 1;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(300));  // команда game могла прислать ещё одну модель
    uint64_t v = 0;
    gfg::UiModel m = client.model(&v);
    std::printf("game=%s source=%s items=%zu\n", m.game.c_str(), m.source.c_str(), m.items.size());
    for (size_t i = 0; i < m.items.size() && i < 5; ++i)
        std::printf("  [%s] %s %d/%d\n", m.items[i].kind.c_str(), m.items[i].title.ru.c_str(), m.items[i].revealed,
                    m.items[i].levels);
    if (argc > 3) {
        client.send(gfg::cmd_reveal(argv[3]));
        if (!wait_version(v)) {
            std::printf("no update after reveal: %s\n", client.last_error().c_str());
            return 1;
        }
        m = client.model();
        for (const auto& it : m.items)
            if (it.id == argv[3]) std::printf("revealed %s: %d/%d, first hint: %s\n", it.id.c_str(), it.revealed,
                                              it.levels, it.hints.empty() ? "" : it.hints[0].c_str());
    }
    client.stop();
    return 0;
}
