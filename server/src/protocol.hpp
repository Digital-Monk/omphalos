#pragma once
// ============================================================
// protocol.hpp — Binary frame format for Omphalos networking.
//
// All integers are little-endian.
//
// Packet layout:
//   [0..3]  magic      uint32  0x4F4D5048 ('OMPH')
//   [4]     version    uint8   1
//   [5]     msg_type   uint8   see MsgType
//   [6..9]  seq        uint32
//   [10..13] payload_len uint32
//   [14..]  payload    bytes
//
// INPUT payload  (<ffffffB> = 25 bytes):
//   move_forward  float32
//   move_right    float32
//   move_up       float32
//   speed_scale   float32
//   look_yaw      float32
//   look_pitch    float32
//   jump          uint8
//
// STATE payload  (<qffffffiif> = 52 bytes):
//   server_time_ms int64
//   x,y,z          float32 x3
//   facing         float32
//   pitch          float32
//   chunk_size     float32
//   chunk_resolution int32
//   view_distance_chunks int32
//   height_amplitude float32
//
// CHUNK payload  (<iififfffffI> header + float32[] heights):
//   cx, cz         int32 x2
//   chunk_size     float32
//   chunk_resolution int32
//   height_amplitude float32
//   height_scale   float32   (always 1.0 — heights are raw float32 now)
//   sea00,10,01,11 float32 x4
//   num_heights    uint32
//   heights[]      float32 x num_heights
// ============================================================

#include <array>
#include <cstdint>
#include <cstring>
#include <optional>
#include <vector>

static constexpr uint32_t NET_MAGIC   = 0x4F4D5048u; // 'OMPH'
static constexpr uint8_t  NET_VERSION = 1;
static constexpr size_t   HEADER_SIZE = 14;

enum class MsgType : uint8_t {
    Hello = 1,
    Ping  = 2,
    Input = 3,
    State = 4,
    Chunk = 5,
    Want  = 6,  // client → server: "I need these chunks"

    // TCP lock-step streaming mode.
    Info     = 7,  // server → client: server capabilities + terrain config
    BatchEnd = 8,  // server → client: marks end of a chunk batch for request seq
};

// ── Want fragment layout ──────────────────────────────────────
// payload: [gen uint32][part uint8][total_parts uint8]
//          [pcx int32][pcz int32][count uint32]
//          [(dx int16, dz int16) × count]
// dx/dz are signed offsets from (pcx,pcz); decode: cx = pcx+dx.
// Note: The payload supports fragmentation (part/total_parts), but the
// TCP lock-step server expects a single fragment (part=0,total_parts=1).
static constexpr size_t WANT_HDR_SIZE        = 18; // 4+1+1+4+4+4

// Read helpers needed by parse_want (full set is repeated below for clarity).
inline uint32_t read_le_u32(const uint8_t* p) {
    return (uint32_t)p[0] | ((uint32_t)p[1]<<8) | ((uint32_t)p[2]<<16) | ((uint32_t)p[3]<<24);
}
inline int32_t read_le_i32(const uint8_t* p) { return (int32_t)read_le_u32(p); }

struct WantFragment {
    uint32_t gen;
    uint8_t  part;
    uint8_t  total_parts;
    int32_t  pcx;
    int32_t  pcz;
    uint32_t count;
    const uint8_t* entries; // points into original buffer; (dx int16, dz int16) pairs
};

inline bool parse_want(const uint8_t* p, size_t len, WantFragment& out) {
    if (len < WANT_HDR_SIZE) return false;
    out.gen         = read_le_u32(p);     p += 4;
    out.part        = *p++;
    out.total_parts = *p++;
    out.pcx         = read_le_i32(p);     p += 4;
    out.pcz         = read_le_i32(p);     p += 4;
    out.count       = read_le_u32(p);     p += 4;
    if (len < WANT_HDR_SIZE + static_cast<size_t>(out.count) * 4) return false;
    out.entries = p;
    return true;
}

// ── host-endian helpers ──────────────────────────────────────
inline void write_le_u32(uint8_t* p, uint32_t v) {
    p[0] = v & 0xFF; p[1] = (v>>8)&0xFF; p[2] = (v>>16)&0xFF; p[3] = (v>>24)&0xFF;
}
inline void write_le_u16(uint8_t* p, uint16_t v) {
    p[0] = v & 0xFF; p[1] = (v>>8)&0xFF;
}
inline void write_le_i16(uint8_t* p, int16_t v) {
    write_le_u16(p, static_cast<uint16_t>(v));
}
inline void write_le_i32(uint8_t* p, int32_t v) {
    write_le_u32(p, static_cast<uint32_t>(v));
}
inline void write_le_u64(uint8_t* p, uint64_t v) {
    write_le_u32(p,   static_cast<uint32_t>(v));
    write_le_u32(p+4, static_cast<uint32_t>(v>>32));
}
inline void write_le_f32(uint8_t* p, float v) {
    uint32_t bits; std::memcpy(&bits, &v, 4); write_le_u32(p, bits);
}

// read_le_u32 / read_le_i32 are forward-declared near WantFragment above.
inline uint8_t read_u8(const uint8_t* p) { return *p; }
inline float read_le_f32(const uint8_t* p) {
    uint32_t bits = read_le_u32(p); float v; std::memcpy(&v, &bits, 4); return v;
}

// ── Header ───────────────────────────────────────────────────
struct PacketHeader {
    uint32_t magic;
    uint8_t  version;
    MsgType  msg_type;
    uint32_t seq;
    uint32_t payload_len;
};

inline bool parse_header(const uint8_t* data, size_t len, PacketHeader& out) {
    if (len < HEADER_SIZE) return false;
    out.magic       = read_le_u32(data);
    out.version     = read_u8(data+4);
    out.msg_type    = static_cast<MsgType>(read_u8(data+5));
    out.seq         = read_le_u32(data+6);
    out.payload_len = read_le_u32(data+10);
    if (out.magic != NET_MAGIC || out.version != NET_VERSION) return false;
    if (len < HEADER_SIZE + out.payload_len) return false;
    return true;
}

inline void write_header(uint8_t* p, MsgType type, uint32_t seq, uint32_t payload_len) {
    write_le_u32(p,    NET_MAGIC);
    p[4] = NET_VERSION;
    p[5] = static_cast<uint8_t>(type);
    write_le_u32(p+6,  seq);
    write_le_u32(p+10, payload_len);
}

// ── Input payload ─────────────────────────────────────────────
struct InputPayload {
    float   move_forward;
    float   move_right;
    float   move_up;
    float   speed_scale;
    float   look_yaw;
    float   look_pitch;
    bool    jump;
};

inline bool parse_input(const uint8_t* p, size_t len, InputPayload& out) {
    if (len < 25) return false;
    out.move_forward = read_le_f32(p);
    out.move_right   = read_le_f32(p+4);
    out.move_up      = read_le_f32(p+8);
    out.speed_scale  = read_le_f32(p+12);
    out.look_yaw     = read_le_f32(p+16);
    out.look_pitch   = read_le_f32(p+20);
    out.jump         = (p[24] != 0);
    float s = out.speed_scale;
    if (s < 1.f)   s = 1.f;
    if (s > 100.f) s = 100.f;
    out.speed_scale = s;
    return true;
}

// ── State payload builder ────────────────────────────────────
// Returns a heap buffer with the full packet (header + payload).
inline std::vector<uint8_t> build_state_packet(
    uint32_t seq,
    int64_t  server_time_ms,
    float x, float y, float z,
    float facing, float pitch,
    float chunk_size, int32_t chunk_res,
    int32_t view_dist, float height_amp)
{
    constexpr size_t PAYLOAD = 52; // qffffffiif
    std::vector<uint8_t> buf(HEADER_SIZE + PAYLOAD);
    write_header(buf.data(), MsgType::State, seq, PAYLOAD);
    uint8_t* p = buf.data() + HEADER_SIZE;
    write_le_u64(p,    static_cast<uint64_t>(server_time_ms)); p += 8;
    write_le_f32(p, x); p += 4;
    write_le_f32(p, y); p += 4;
    write_le_f32(p, z); p += 4;
    write_le_f32(p, facing); p += 4;
    write_le_f32(p, pitch);  p += 4;
    write_le_f32(p, chunk_size); p += 4;
    write_le_i32(p, chunk_res);  p += 4;
    write_le_i32(p, view_dist);  p += 4;
    write_le_f32(p, height_amp);
    return buf;
}

// ── Chunk packet builder ──────────────────────────────────────
// heights[] = raw float heights, sent as float32 (no quantisation).
inline std::vector<uint8_t> build_chunk_packet(
    uint32_t seq,
    int32_t cx, int32_t cz,
    float chunk_size, int32_t chunk_res,
    float height_amp,
    const std::vector<float>& heights)
{
    const uint32_t n       = static_cast<uint32_t>(heights.size());

    // Header: iififfffffI  = 4+4+4+4+4+4+4+4+4+4+4 = 44 bytes
    constexpr size_t CHUNK_HEADER = 44;
    const size_t     heights_bytes = n * 4;  // float32
    const size_t     payload_size  = CHUNK_HEADER + heights_bytes;

    std::vector<uint8_t> buf(HEADER_SIZE + payload_size);
    write_header(buf.data(), MsgType::Chunk, seq, static_cast<uint32_t>(payload_size));
    uint8_t* p = buf.data() + HEADER_SIZE;

    write_le_i32(p, cx);          p += 4;
    write_le_i32(p, cz);          p += 4;
    write_le_f32(p, chunk_size);  p += 4;
    write_le_i32(p, chunk_res);   p += 4;
    write_le_f32(p, height_amp);  p += 4;
    write_le_f32(p, 1.0f);       p += 4; // height_scale (1.0 — raw float32)
    write_le_f32(p, 0.f); p += 4; // sea00
    write_le_f32(p, 0.f); p += 4; // sea10
    write_le_f32(p, 0.f); p += 4; // sea01
    write_le_f32(p, 0.f); p += 4; // sea11
    write_le_u32(p, n);   p += 4;

    // Write heights as raw float32 (little-endian on x86/x64).
    std::memcpy(p, heights.data(), heights_bytes);

    return buf;
}
