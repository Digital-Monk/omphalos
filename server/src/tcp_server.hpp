#pragma once

#include "protocol.hpp"
#include "terrain.hpp"
#include "threadpool.hpp"

#include <atomic>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

// ── Chunk key helpers (mirrors server.hpp) ───────────────────
inline uint64_t chunk_key(int cx, int cz) noexcept {
    return (static_cast<uint64_t>(static_cast<uint32_t>(cx)) << 32)
         |  static_cast<uint64_t>(static_cast<uint32_t>(cz));
}
inline int cx_from_key(uint64_t k) noexcept { return static_cast<int>(k >> 32); }
inline int cz_from_key(uint64_t k) noexcept { return static_cast<int>(static_cast<uint32_t>(k)); }

class OmphalosTcpServer {
public:
    OmphalosTcpServer(const std::string& host, uint16_t port, int num_workers = 12);
    ~OmphalosTcpServer();

    void run();
    void request_stop() { stop_.store(true); }

private:
    int      listen_fd_ = -1;
    uint16_t port_;

    TerrainConfig cfg_{};
    int view_distance_chunks_ = 15;

    ThreadPool pool_;

    std::atomic<bool> stop_{false};

    static int create_listen_socket(const std::string& host, uint16_t port);
    static bool send_all(int fd, const uint8_t* data, size_t len);
    static bool recv_all(int fd, uint8_t* data, size_t len);

    bool handle_client(int client_fd);

    static std::vector<uint8_t> build_info_packet(uint32_t seq, uint32_t batch_n, const TerrainConfig& cfg, int view_dist);
    static std::vector<uint8_t> build_batch_end_packet(uint32_t seq, uint32_t count);
};
