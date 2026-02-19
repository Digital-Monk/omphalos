#pragma once
// ============================================================
// terrain.hpp — Chunk height computation.
//
// Exactly mirrors the Python _compute_chunk_worker() logic:
//   bedrock  (seed+10, low freq)
//   bumpiness(seed+20, low freq, log-scale)
//   detail   (seed,    FBM, mid freq)
//   plateau zone  (seed+30, per-chunk single sample)
//   plateau height(seed+40, per-chunk single sample)
//
// compute_chunk() is pure and thread-safe; call it from any thread.
// ============================================================

#include "simplex.hpp"
#include <cmath>
#include <vector>
#include <unordered_map>
#include <mutex>

struct TerrainConfig {
    double chunk_size           = 128.0;
    int    chunk_resolution     = 128;       // verts = resolution+1 per side
    double height_amplitude     = 120.0;
    int    noise_seed           = 1337;
    double sea_level            = 0.0;
    double bedrock_frequency    = 0.0025;
    double bumpiness_frequency  = 0.06;
    double bumpiness_min        = 0.2;
    double bumpiness_max        = 2.2;
    double detail_frequency     = 0.02;
    int    detail_octaves       = 4;
    double plateau_zone_frequency  = 0.04;
    double plateau_zone_threshold  = 0.25;
    double plateau_height_base     = 90.0;
    double plateau_height_variation= 60.0;
    double plateau_height_frequency= 0.2;
};

// Thread-local SimplexNoise cache (each thread keeps its own instances to
// avoid any locking on the permutation tables).
struct SimplexCache {
    SimplexNoise detail;
    SimplexNoise bedrock;
    SimplexNoise bumpiness;
    SimplexNoise plateau_zone;
    SimplexNoise plateau_height;

    explicit SimplexCache(const TerrainConfig& cfg)
        : detail        (cfg.noise_seed)
        , bedrock       (cfg.noise_seed + 10)
        , bumpiness     (cfg.noise_seed + 20)
        , plateau_zone  (cfg.noise_seed + 30)
        , plateau_height(cfg.noise_seed + 40)
    {}
};

// ── Main entry point ──────────────────────────────────────────
// Returns (chunk_resolution+1)² heights in row-major z-first order.
inline std::vector<float> compute_chunk(int cx, int cz, const TerrainConfig& cfg,
                                         SimplexCache& sc) {
    const int    n    = cfg.chunk_resolution + 1;  // 33
    const double step = cfg.chunk_size / static_cast<double>(cfg.chunk_resolution);
    const double bedrock_min  = -0.75 * cfg.height_amplitude;
    const double bedrock_span =  cfg.height_amplitude;
    const double lo = std::max(0.0001, cfg.bumpiness_min);
    const double hi = std::max(lo + 0.0001, cfg.bumpiness_max);
    const double lo_hi_ratio = hi / lo;

    // Build world-space coordinate arrays for this chunk.
    std::vector<double> xs(n), zs(n);
    for (int i = 0; i < n; ++i) {
        xs[i] = cx * cfg.chunk_size + i * step;
        zs[i] = cz * cfg.chunk_size + i * step;
    }

    // ── Plateau zone: single scalar sample per chunk ──────────
    const double t_pz = (sc.plateau_zone.noise2(
                             cx * cfg.plateau_zone_frequency,
                             cz * cfg.plateau_zone_frequency) + 1.0) * 0.5;
    const bool plateau_zone = (t_pz > (1.0 - cfg.plateau_zone_threshold));
    double plateau_h = 0.0;
    if (plateau_zone) {
        const double cx_w = cx * cfg.chunk_size + cfg.chunk_size * 0.5;
        const double cz_w = cz * cfg.chunk_size + cfg.chunk_size * 0.5;
        const double t_ph = (sc.plateau_height.noise2(
                                 cx_w * cfg.plateau_height_frequency,
                                 cz_w * cfg.plateau_height_frequency) + 1.0) * 0.5;
        plateau_h = cfg.plateau_height_base + t_ph * cfg.plateau_height_variation;
    }

    // ── Scale xs/zs by frequency for each layer ───────────────
    std::vector<double> xs_bed(n), zs_bed(n);
    std::vector<double> xs_bump(n), zs_bump(n);
    for (int i = 0; i < n; ++i) {
        xs_bed[i]  = xs[i] * cfg.bedrock_frequency;
        zs_bed[i]  = zs[i] * cfg.bedrock_frequency;
        xs_bump[i] = xs[i] * cfg.bumpiness_frequency;
        zs_bump[i] = zs[i] * cfg.bumpiness_frequency;
    }

    // ── Batch noise evaluations (one C++ call per layer) ──────
    std::vector<double> t_bed (static_cast<size_t>(n*n));
    std::vector<double> t_bump(static_cast<size_t>(n*n));
    sc.bedrock  .noise2array(xs_bed .data(), n, zs_bed .data(), n, t_bed .data());
    sc.bumpiness.noise2array(xs_bump.data(), n, zs_bump.data(), n, t_bump.data());

    // ── Detail FBM (detail_octaves octave-doubled sums) ───────
    std::vector<double> detail(static_cast<size_t>(n*n), 0.0);
    {
        double amp = 1.0, freq = 1.0, total_amp = 0.0;
        std::vector<double> xs_d(n), zs_d(n), layer(static_cast<size_t>(n*n));
        for (int oct = 0; oct < cfg.detail_octaves; ++oct) {
            const double df = cfg.detail_frequency * freq;
            for (int i = 0; i < n; ++i) { xs_d[i] = xs[i] * df; zs_d[i] = zs[i] * df; }
            sc.detail.noise2array(xs_d.data(), n, zs_d.data(), n, layer.data());
            for (int k = 0; k < n*n; ++k) detail[k] += amp * layer[k];
            total_amp += amp;
            amp  *= 0.5;
            freq *= 2.0;
        }
        for (double& v : detail) v /= total_amp;
    }

    // ── Combine layers → final heights ────────────────────────
    std::vector<float> heights(static_cast<size_t>(n*n));
    for (int k = 0; k < n*n; ++k) {
        const double tb  = (t_bed [k] + 1.0) * 0.5;
        const double tbp = (t_bump[k] + 1.0) * 0.5;

        const double bedrock = bedrock_min + tb * bedrock_span;
        const double bump    = lo * std::pow(lo_hi_ratio, tbp);
        const double h       = cfg.sea_level + detail[k] * cfg.height_amplitude * bump;

        double elevation;
        const double ab = h - bedrock;
        if (ab <= 0.0) {
            elevation = bedrock;
        } else {
            elevation = bedrock + std::sqrt(ab);
        }

        if (plateau_zone) {
            // Plateau acts as a ceiling, not a floor: only compress values above plateau_h.
            const double ap = elevation - plateau_h;
            if (ap > 0.0) {
                elevation = plateau_h + std::log10(std::max(1.0, ap));
            }
        }

        heights[k] = static_cast<float>(elevation);
    }

    return heights;
}
