// Связь с сервисом: TCP на localhost, JSON по строкам (service/README.md).
// Свой поток: подключается, при обрыве переподключается каждые 2 с, хранит последнюю модель UI.
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>

#include "model.hpp"

namespace gfg {

class Client {
public:
    // hello — команда, которая отправляется после каждого подключения (обычно cmd_game(exe)).
    Client(std::string host, uint16_t port, std::string hello);
    ~Client();
    Client(const Client&) = delete;
    Client& operator=(const Client&) = delete;

    void start();
    void stop();  // ждёт завершения потока

    void send(std::string line);
    // Заменить команду, которая уходит после каждого подключения.
    void set_hello(std::string hello);

    bool connected() const { return connected_; }
    // Последняя модель и её номер (растёт с каждой новой моделью).
    UiModel model(uint64_t* version = nullptr) const;
    uint64_t version() const { return version_; }
    std::string last_error() const;

private:
    void run();
    bool wait(int ms);  // false — пора выходить

    std::string host_;
    uint16_t port_;
    std::string hello_;

    std::thread thread_;
    std::atomic<bool> stopping_{false};
    std::atomic<bool> connected_{false};
    std::atomic<uint64_t> version_{0};

    mutable std::mutex mutex_;
    std::condition_variable cv_;
    UiModel model_;
    std::string error_;
    std::deque<std::string> outbox_;
};

}  // namespace gfg
