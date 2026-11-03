#include "client.hpp"

#include <chrono>
#include <cstring>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
using socket_t = SOCKET;
static constexpr socket_t kBad = INVALID_SOCKET;
static void close_socket(socket_t s) { closesocket(s); }
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>
using socket_t = int;
static constexpr socket_t kBad = -1;
static void close_socket(socket_t s) { ::close(s); }
#endif

#ifdef MSG_NOSIGNAL
static constexpr int kSendFlags = MSG_NOSIGNAL;  // обрыв связи — ошибка send, а не SIGPIPE
#else
static constexpr int kSendFlags = 0;
#endif

namespace gfg {

Client::Client(std::string host, uint16_t port, std::string hello)
    : host_(std::move(host)), port_(port), hello_(std::move(hello)) {}

Client::~Client() { stop(); }

void Client::start() {
    if (thread_.joinable()) return;
    stopping_ = false;
    thread_ = std::thread([this] { run(); });
}

void Client::stop() {
    stopping_ = true;
    cv_.notify_all();
    if (thread_.joinable()) thread_.join();
}

void Client::send(std::string line) {
    std::lock_guard lock(mutex_);
    if (outbox_.size() < 64) outbox_.push_back(std::move(line));
}

UiModel Client::model(uint64_t* version) const {
    std::lock_guard lock(mutex_);
    if (version) *version = version_;
    return model_;
}

std::string Client::last_error() const {
    std::lock_guard lock(mutex_);
    return error_;
}

bool Client::wait(int ms) {
    std::unique_lock lock(mutex_);
    cv_.wait_for(lock, std::chrono::milliseconds(ms), [this] { return stopping_.load(); });
    return !stopping_;
}

void Client::run() {
#ifdef _WIN32
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
#endif
    while (!stopping_) {
        socket_t s = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(port_);
        inet_pton(AF_INET, host_.c_str(), &addr.sin_addr);
        if (s == kBad || ::connect(s, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
            if (s != kBad) close_socket(s);
            {
                std::lock_guard lock(mutex_);
                error_ = "service is not running (" + host_ + ":" + std::to_string(port_) + ")";
            }
            if (!wait(2000)) break;
            continue;
        }
        int one = 1;
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&one), sizeof(one));
        connected_ = true;
        {
            std::lock_guard lock(mutex_);
            error_.clear();
            // Команды, накопленные без связи, устарели: модель придёт заново.
            outbox_.clear();
            if (!hello_.empty()) outbox_.push_front(hello_);
        }

        std::string buffer;
        bool alive = true;
        while (alive && !stopping_) {
            // Отправить накопленное.
            std::deque<std::string> out;
            {
                std::lock_guard lock(mutex_);
                out.swap(outbox_);
            }
            for (auto& line : out) {
                line += '\n';
                const char* p = line.data();
                size_t left = line.size();
                while (left > 0) {
                    const int n = ::send(s, p, static_cast<int>(left), kSendFlags);
                    if (n <= 0) {
                        alive = false;
                        break;
                    }
                    p += n;
                    left -= static_cast<size_t>(n);
                }
                if (!alive) break;
            }
            if (!alive) break;

            // Ждать данные до 50 мс, чтобы команды уходили без задержки.
            fd_set set;
            FD_ZERO(&set);
            FD_SET(s, &set);
            timeval tv{0, 50 * 1000};
            const int ready = ::select(static_cast<int>(s) + 1, &set, nullptr, nullptr, &tv);
            if (ready < 0) break;
            if (ready == 0) continue;
            char chunk[16384];
            const int n = ::recv(s, chunk, sizeof(chunk), 0);
            if (n <= 0) break;
            buffer.append(chunk, static_cast<size_t>(n));
            size_t pos;
            while ((pos = buffer.find('\n')) != std::string::npos) {
                const std::string line = buffer.substr(0, pos);
                buffer.erase(0, pos + 1);
                if (line.empty()) continue;
                Message msg = parse_message(line);
                std::lock_guard lock(mutex_);
                if (msg.type == MessageType::Ui) {
                    model_ = std::move(msg.ui);
                    ++version_;
                } else if (msg.type == MessageType::Hello && msg.protocol != kProtocol) {
                    error_ = "protocol " + std::to_string(msg.protocol) + ", expected " + std::to_string(kProtocol);
                } else if (msg.type == MessageType::Error) {
                    error_ = msg.error;
                }
            }
        }
        close_socket(s);
        connected_ = false;
        if (!wait(500)) break;
    }
#ifdef _WIN32
    WSACleanup();
#endif
}

}  // namespace gfg
