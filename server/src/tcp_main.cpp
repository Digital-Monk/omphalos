// ============================================================
// tcp_main.cpp — Omphalos TCP lock-step chunk server entry point.
// ============================================================

#include "tcp_server.hpp"

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>

static OmphalosTcpServer* g_server = nullptr;

static void signal_handler(int sig) {
    std::printf("\nReceived signal %d — shutting down.\n", sig);
    if (g_server) g_server->request_stop();
}

int main(int argc, char* argv[]) {
    // Ensure logs flush promptly even when redirected to a file.
    std::setvbuf(stdout, nullptr, _IOLBF, 0);
    std::setvbuf(stderr, nullptr, _IONBF, 0);

    const char* host = "0.0.0.0";
    uint16_t port = 7778;
    int num_workers = 12;

    // Simple CLI: [port] [num_workers]
    if (argc > 1) port = static_cast<uint16_t>(std::atoi(argv[1]));
    if (argc > 2) num_workers = std::atoi(argv[2]);

    std::printf("Omphalos TCP server: port=%u  workers=%d\n",
                static_cast<unsigned>(port), num_workers);

    std::signal(SIGINT, signal_handler);
    std::signal(SIGTERM, signal_handler);
    std::signal(SIGPIPE, SIG_IGN);

    try {
        OmphalosTcpServer server(host, port, num_workers);
        g_server = &server;
        server.run();
        g_server = nullptr;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "Fatal: %s\n", e.what());
        return 1;
    }

    std::printf("TCP server stopped cleanly.\n");
    return 0;
}
