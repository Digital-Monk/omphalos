#include "tcp_server.hpp"

#include "simplex.hpp"

#include <arpa/inet.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <future>
#include <stdexcept>
#include <unordered_map>
#include <vector>

namespace {
inline bool write_header_u8(uint8_t* p, uint8_t type, uint32_t seq, uint32_t payload_len) {
    write_le_u32(p, NET_MAGIC);
    p[4] = NET_VERSION;
    p[5] = type;
    write_le_u32(p + 6, seq);
    write_le_u32(p + 10, payload_len);
    return true;
}
} // namespace

OmphalosTcpServer::OmphalosTcpServer(const std::string& host, uint16_t port, int num_workers)
    : port_(port)
    , pool_(static_cast<size_t>(std::max(1, num_workers)))
{
    cfg_.chunk_size               = 128.0;
    cfg_.chunk_resolution         = 128;
    // Elevation shaping model defaults.
    cfg_.elevation_shape_frequency = 0.002;   // 500 ft wavelength
    cfg_.elevation_scale_frequency = 0.0002;  // 5000 ft wavelength
    cfg_.elevation_scale_min       = 0.1;
    cfg_.elevation_scale_max       = 20000.0;
    cfg_.detail_fgm_frequency      = 0.04;
    cfg_.detail_fgm_octaves        = 7;
    cfg_.detail_fgm_amplitude      = 1.0;
    // height_amplitude will be computed below as the maximum expected
    // absolute displacement for AABB / client hints.
    cfg_.height_amplitude         = 120.0;
    cfg_.noise_seed               = 1337;
    cfg_.sea_level                = 0.0;
    cfg_.bedrock_frequency        = 0.0002;
    cfg_.plateau_zone_frequency   = 0.00002;
    cfg_.plateau_zone_threshold   = 0.25;
    cfg_.plateau_base_height_base = 0.0;
    cfg_.plateau_base_height_variation = 4950.0;
    cfg_.plateau_base_height_frequency = 0.000001;
    cfg_.plateau_detail_height_frequency = 0.001;
    cfg_.plateau_detail_height_octaves = 5;
    cfg_.plateau_detail_height_amp_mul = 0.5;
    cfg_.plateau_detail_height_amplitude = 100.0;
    cfg_.bedrock_min              = -90.0;
    cfg_.bedrock_span             = 120.0;

    // Compute a conservative reported height amplitude for clients.
    // Consider elevation_scale max, detail_fgm amplitude, plateau max, and bedrock depth.
    double max_up = cfg_.plateau_base_height_base + cfg_.plateau_base_height_variation + std::fabs(cfg_.plateau_detail_height_amplitude);
    double max_elevation = cfg_.elevation_scale_max + std::fabs(cfg_.detail_fgm_amplitude);
    double max_down = std::fabs(cfg_.bedrock_min);
    cfg_.height_amplitude = std::max(max_up, max_elevation);
    cfg_.height_amplitude = std::max(cfg_.height_amplitude, max_down);

    listen_fd_ = create_listen_socket(host, port);

    std::printf("Omphalos TCP chunk server started on port %u (%zu worker threads)\n",
                static_cast<unsigned>(port_), pool_.num_threads());
}

OmphalosTcpServer::~OmphalosTcpServer() {
    if (listen_fd_ >= 0) ::close(listen_fd_);
}

int OmphalosTcpServer::create_listen_socket(const std::string& host, uint16_t port) {
    int fd = ::socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) throw std::runtime_error(std::string("socket(): ") + strerror(errno));

    int opt = 1;
    ::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port   = htons(port);
    if (host == "0.0.0.0" || host.empty()) {
        addr.sin_addr.s_addr = INADDR_ANY;
    } else {
        if (::inet_pton(AF_INET, host.c_str(), &addr.sin_addr) != 1) {
            ::close(fd);
            throw std::runtime_error("inet_pton failed for host");
        }
    }

    if (::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        ::close(fd);
        throw std::runtime_error(std::string("bind(): ") + strerror(errno));
    }

    if (::listen(fd, 4) < 0) {
        ::close(fd);
        throw std::runtime_error(std::string("listen(): ") + strerror(errno));
    }

    return fd;
}

bool OmphalosTcpServer::send_all(int fd, const uint8_t* data, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = ::send(fd, data + sent, len - sent, 0);
        if (n <= 0) {
            if (errno == EINTR) continue;
            return false;
        }
        sent += static_cast<size_t>(n);
    }
    return true;
}

bool OmphalosTcpServer::recv_all(int fd, uint8_t* data, size_t len) {
    size_t got = 0;
    while (got < len) {
        ssize_t n = ::recv(fd, data + got, len - got, 0);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            return false;
        }
        got += static_cast<size_t>(n);
    }
    return true;
}

std::vector<uint8_t> OmphalosTcpServer::build_info_packet(uint32_t seq, uint32_t batch_n, const TerrainConfig& cfg, int view_dist) {
    // payload: [batch_n u32][chunk_size f32][chunk_res i32][view_dist i32][height_amp f32]
    constexpr uint32_t PAYLOAD = 4 + 4 + 4 + 4 + 4;
    std::vector<uint8_t> buf(HEADER_SIZE + PAYLOAD);
    write_header_u8(buf.data(), static_cast<uint8_t>(MsgType::Info), seq, PAYLOAD);
    uint8_t* p = buf.data() + HEADER_SIZE;
    write_le_u32(p, batch_n); p += 4;
    write_le_f32(p, static_cast<float>(cfg.chunk_size)); p += 4;
    write_le_i32(p, cfg.chunk_resolution); p += 4;
    write_le_i32(p, view_dist); p += 4;
    write_le_f32(p, static_cast<float>(cfg.height_amplitude));
    return buf;
}

std::vector<uint8_t> OmphalosTcpServer::build_batch_end_packet(uint32_t seq, uint32_t count) {
    // payload: [count u32]
    constexpr uint32_t PAYLOAD = 4;
    std::vector<uint8_t> buf(HEADER_SIZE + PAYLOAD);
    write_header_u8(buf.data(), static_cast<uint8_t>(MsgType::BatchEnd), seq, PAYLOAD);
    write_le_u32(buf.data() + HEADER_SIZE, count);
    return buf;
}

bool OmphalosTcpServer::handle_client(int client_fd) {
    // Send INFO immediately.  batch_n tells the client how many chunks to
    // request per WANT — set it high so the thread pool always has work queued.
    const uint32_t batch_n = 128;
    {
        auto pkt = build_info_packet(1, batch_n, cfg_, view_distance_chunks_);
        if (!send_all(client_fd, pkt.data(), pkt.size())) return false;
    }

    std::vector<uint8_t> hdr(HEADER_SIZE);
    std::vector<uint8_t> payload;

    for (;;) {
        if (stop_.load(std::memory_order_relaxed)) return false;

        if (!recv_all(client_fd, hdr.data(), hdr.size())) return false;

        PacketHeader ph{};
        const uint32_t magic = read_le_u32(hdr.data());
        if (magic != NET_MAGIC) return false;
        const uint8_t ver = hdr[4];
        if (ver != NET_VERSION) return false;

        ph.magic = magic;
        ph.version = ver;
        ph.msg_type = static_cast<MsgType>(hdr[5]);
        ph.seq = read_le_u32(hdr.data() + 6);
        ph.payload_len = read_le_u32(hdr.data() + 10);

        payload.resize(ph.payload_len);
        if (ph.payload_len > 0) {
            if (!recv_all(client_fd, payload.data(), payload.size())) return false;
        }

        const auto type_u8 = static_cast<uint8_t>(ph.msg_type);
        if (type_u8 == static_cast<uint8_t>(MsgType::Hello)) {
            // Re-send INFO on hello.
            auto pkt = build_info_packet(ph.seq, batch_n, cfg_, view_distance_chunks_);
            if (!send_all(client_fd, pkt.data(), pkt.size())) return false;
            continue;
        }

        if (type_u8 == static_cast<uint8_t>(MsgType::SetLayerMode)) {
            if (!payload.empty()) {
                cfg_.layer_mode = std::min(4, std::max(0, static_cast<int>(payload[0])));
                std::printf("TCP SetLayerMode: mode=%d\n", cfg_.layer_mode);
            }
            continue;
        }

        if (type_u8 != static_cast<uint8_t>(MsgType::Want)) {
            continue;
        }

        WantFragment frag{};
        if (!parse_want(payload.data(), payload.size(), frag)) continue;

        // Lock-step: single-fragment requests only.
        if (frag.total_parts != 1 || frag.part != 0) {
            continue;
        }

        std::printf("TCP WANT: seq=%u center=(%d,%d) count=%u scale=%u\n",
                    ph.seq,
                    frag.pcx,
                    frag.pcz,
                    frag.count,
                    static_cast<unsigned>(frag.scale));

        // Decode requested (dx,dz) entries into chunk coordinates and submit
        // each one to the thread pool immediately.  We keep the futures in
        // request order so we can send results as soon as they resolve —
        // pipelining generation and TCP transmission.
        struct PendingChunk {
            int32_t cx, cz;
            std::future<std::vector<float>> fut;
        };
        std::vector<PendingChunk> pending;
        pending.reserve(frag.count);

        const uint8_t* p = frag.entries;
        TerrainConfig cfg_snap = cfg_;          // snapshot config once
        // Mega-chunks: multiply chunk_size by scale (resolution stays the same,
        // so each vertex covers more ground).  Scale 1 = normal, 8 = mega.
        const int scale = std::max(1, static_cast<int>(frag.scale));
        if (scale > 1) {
            cfg_snap.chunk_size *= static_cast<double>(scale);
        }
        for (uint32_t i = 0; i < frag.count; ++i, p += 4) {
            int16_t dx, dz;
            std::memcpy(&dx, p, 2);
            std::memcpy(&dz, p + 2, 2);
            const int32_t cx = frag.pcx + dx;
            const int32_t cz = frag.pcz + dz;
            pending.push_back({cx, cz, pool_.submit([cx, cz, cfg_snap]() {
                thread_local std::unordered_map<int, SimplexCache> cache_map;
                auto it = cache_map.find(cfg_snap.noise_seed);
                if (it == cache_map.end())
                    it = cache_map.emplace(cfg_snap.noise_seed, SimplexCache(cfg_snap)).first;
                return compute_chunk(cx, cz, cfg_snap, it->second);
            })});
        }

        // Send each chunk as soon as its future resolves — later entries may
        // finish while earlier ones are still being written to the socket.
        uint32_t sent_count = 0;
        for (auto& pc : pending) {
            auto heights = pc.fut.get();
            auto pkt = build_chunk_packet(
                ph.seq,
                pc.cx, pc.cz,
                static_cast<float>(cfg_snap.chunk_size),
                cfg_snap.chunk_resolution,
                static_cast<float>(cfg_snap.height_amplitude),
                heights);
            if (!send_all(client_fd, pkt.data(), pkt.size())) return false;
            ++sent_count;
        }

        auto endpkt = build_batch_end_packet(ph.seq, sent_count);
        if (!send_all(client_fd, endpkt.data(), endpkt.size())) return false;
    }
}

void OmphalosTcpServer::run() {
    while (!stop_.load(std::memory_order_relaxed)) {
        sockaddr_in peer{};
        socklen_t sl = sizeof(peer);
        int cfd = ::accept(listen_fd_, reinterpret_cast<sockaddr*>(&peer), &sl);
        if (cfd < 0) {
            if (errno == EINTR) continue;
            std::perror("accept");
            continue;
        }

        char ipbuf[64];
        std::snprintf(ipbuf, sizeof(ipbuf), "%s", ::inet_ntoa(peer.sin_addr));
        std::printf("TCP client connected: %s:%u\n", ipbuf, static_cast<unsigned>(ntohs(peer.sin_port)));

        (void)handle_client(cfd);
        ::close(cfd);
        std::printf("TCP client disconnected.\n");
    }
}
