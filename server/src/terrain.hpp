#pragma once
// ============================================================
// terrain.hpp — Chunk height computation.
//
// Exactly mirrors the Python _compute_chunk_worker() logic:
//   bedrock  (seed+10, low freq)
//   elevation_scale(seed+20, low freq, log-scale)
//   elevation_shape(seed+50, base noise in [0,1])
//   detail_fgm(seed, multi-octave detail)
//   plateau zone          (seed+30, per-vertex)
//   plateau_base_height   (seed+40, per-vertex, coarse)
//   plateau_detail_height (seed+41, per-vertex, harmonic detail)
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
    // elevation_shape is normalized to [0,1] and used as shape only.
    double elevation_shape_frequency = 0.002; // 500 ft base wavelength
    // elevation_scale controls the magnitude in feet.
    double elevation_scale_frequency = 0.0002; // 5000 ft base wavelength
    double elevation_scale_min       = 0.1;
    double elevation_scale_max       = 20000.0;
    // detail_fgm is additive high-frequency detail in feet.
    double detail_fgm_frequency      = 0.04;
    int    detail_fgm_octaves        = 7;
    double detail_fgm_amplitude      = 1.0;
    // Reported height_amplitude is computed by the server as the maximum
    // expected absolute displacement for AABB / client shader hints.
    double height_amplitude     = 120.0;
    int    noise_seed           = 1337;
    double sea_level            = 0.0;
    // Base bedrock frequency tuned to ~5000 ft wavelength: 1/5000 = 0.0002
    double bedrock_frequency    = 0.0002;
    // World-space frequency for plateau mask. increased 10x => wavelength ~50000 ft.
    double plateau_zone_frequency  = 0.00002;
    double plateau_zone_threshold  = 0.25;
    // Plateau base height: coarse field, discretized to 1000 ft steps.
    // Range is between base and base+variation (feet). Lower end can be 0.0.
    double plateau_base_height_base      = 0.0;
    double plateau_base_height_variation = 4950.0; // -> base up to ~5000
    // Base wavelength ~1,000,000 ft => 1/1,000,000 = 0.000001
    double plateau_base_height_frequency = 0.000001;

    // Plateau detail height: additive fine field, centered at 0.
    // Base wavelength ~1000 ft => 1/1000 = 0.001
    double plateau_detail_height_frequency = 0.001;
    int    plateau_detail_height_octaves   = 5;
    double plateau_detail_height_amp_mul   = 0.5;
    // Detail range in feet: [-amplitude, +amplitude]
    double plateau_detail_height_amplitude = 100.0;
    // Explicit bedrock amplitude/range in feet: bedrock_min .. bedrock_min+bedrock_span
    double bedrock_min             = -90.0;
    double bedrock_span            = 120.0; // so bedrock_max = +30
    // Diagnostic layer-removal mode (cycle with backspace on client):
    //   0 = full terrain
    //   1 = no detail_FGM
    //   2 = + no plateau
    //   3 = + elevation_scale forced to 1.0 ft (reveals elevation_shape at tiny scale)
    //   4 = + no elevation_shape (pure bedrock)
    int    layer_mode              = 0;
};

// Thread-local SimplexNoise cache (each thread keeps its own instances to
// avoid any locking on the permutation tables).
struct SimplexCache {
    SimplexNoise elevation_shape;
    SimplexNoise bedrock;
    SimplexNoise elevation_scale;
    SimplexNoise detail_fgm;
    SimplexNoise plateau_zone;
    SimplexNoise plateau_base_height;
    SimplexNoise plateau_detail_height;

    explicit SimplexCache(const TerrainConfig& cfg)
        : elevation_shape(cfg.noise_seed + 50)
        , bedrock       (cfg.noise_seed + 10)
        , elevation_scale(cfg.noise_seed + 20)
        , detail_fgm    (cfg.noise_seed)
        , plateau_zone  (cfg.noise_seed + 30)
        , plateau_base_height(cfg.noise_seed + 40)
        , plateau_detail_height(cfg.noise_seed + 41)
    {}
};

// ── Main entry point ──────────────────────────────────────────
// Returns (chunk_resolution+1)² * 2 floats in row-major z-first order:
//   first  n*n floats: heights
//   second n*n floats: biome tags (0.0=bedrock, 0.5=normal, 1.0=plateau)
inline std::vector<float> compute_chunk(int cx, int cz, const TerrainConfig& cfg,
                                         SimplexCache& sc) {
    const int    n    = cfg.chunk_resolution + 1;  // 33
    const double step = cfg.chunk_size / static_cast<double>(cfg.chunk_resolution);
    const double bedrock_min  = cfg.bedrock_min;
    const double bedrock_span = cfg.bedrock_span;
    const double lo = std::max(0.0001, cfg.elevation_scale_min);
    const double hi = std::max(lo + 0.0001, cfg.elevation_scale_max);
    const double lo_hi_ratio = hi / lo;

    // Build world-space coordinate arrays for this chunk.
    std::vector<double> xs(n), zs(n);
    for (int i = 0; i < n; ++i) {
        xs[i] = cx * cfg.chunk_size + i * step;
        zs[i] = cz * cfg.chunk_size + i * step;
    }

    // ── Plateau zone: sample per-vertex (previously single sample per chunk)
    // Enforce no harmonics with wavelength < 600 ft for coarse layers.
    const double max_world_freq = 1.0 / 600.0; // per-foot frequency
    const double bedrock_freq = std::min(cfg.bedrock_frequency, max_world_freq);
    const double scale_freq   = std::min(cfg.elevation_scale_frequency, max_world_freq);
    // plateau_zone_frequency is world-space per-foot frequency.
    const double pz_freq = std::min(cfg.plateau_zone_frequency, max_world_freq);

    // Per-vertex plateau arrays (sampled at vertex world positions).
    std::vector<double> t_pz(static_cast<size_t>(n*n), 0.0);
    std::vector<double> t_ph_base(static_cast<size_t>(n*n), 0.0);
    std::vector<double> t_ph_detail(static_cast<size_t>(n*n), 0.0);
    {
        // plateau zone still sampled as a single-frequency field (per-vertex)
        std::vector<double> xs_pz(n), zs_pz(n);
        for (int i = 0; i < n; ++i) {
            xs_pz[i] = xs[i] * pz_freq;
            zs_pz[i] = zs[i] * pz_freq;
        }
        sc.plateau_zone.noise2array(xs_pz.data(), n, zs_pz.data(), n, t_pz.data());

        // plateau base height: single-frequency coarse field (no harmonics)
        std::vector<double> xs_ph_base(n), zs_ph_base(n);
        for (int i = 0; i < n; ++i) {
            xs_ph_base[i] = xs[i] * cfg.plateau_base_height_frequency;
            zs_ph_base[i] = zs[i] * cfg.plateau_base_height_frequency;
        }
        sc.plateau_base_height.noise2array(xs_ph_base.data(), n, zs_ph_base.data(), n, t_ph_base.data());

        // plateau detail height: normal harmonic stack from ~1000 ft downward.
        std::vector<double> plateau_detail_noise(static_cast<size_t>(n*n), 0.0);
        double amplitude = 1.0;
        double freq_mul = 1.0;
        double total_amplitude = 0.0;
        std::vector<double> xs_ph(n), zs_ph(n), layer(static_cast<size_t>(n*n));
        int octaves = std::max(1, cfg.plateau_detail_height_octaves);
        for (int oct = 0; oct < octaves; ++oct) {
            const double f = cfg.plateau_detail_height_frequency * freq_mul;
            for (int i = 0; i < n; ++i) { xs_ph[i] = xs[i] * f; zs_ph[i] = zs[i] * f; }
            sc.plateau_detail_height.noise2array(xs_ph.data(), n, zs_ph.data(), n, layer.data());
            for (int k = 0; k < n*n; ++k) plateau_detail_noise[k] += amplitude * layer[k];
            total_amplitude += amplitude;
            amplitude *= cfg.plateau_detail_height_amp_mul;
            freq_mul *= 2.0;
        }
        if (total_amplitude > 0.0) {
            for (int k = 0; k < n*n; ++k) t_ph_detail[k] = plateau_detail_noise[k] / total_amplitude;
        } else {
            for (int k = 0; k < n*n; ++k) t_ph_detail[k] = 0.0;
        }
    }

    // ── Scale xs/zs by frequency for each layer ───────────────
    std::vector<double> xs_bed(n), zs_bed(n);
    std::vector<double> xs_scale(n), zs_scale(n);
    for (int i = 0; i < n; ++i) {
        xs_bed[i]  = xs[i] * bedrock_freq;
        zs_bed[i]  = zs[i] * bedrock_freq;
        xs_scale[i] = xs[i] * scale_freq;
        zs_scale[i] = zs[i] * scale_freq;
    }

    // ── Batch noise evaluations (one C++ call per layer) ──────
    std::vector<double> t_bed  (static_cast<size_t>(n*n));
    std::vector<double> t_scale(static_cast<size_t>(n*n));
    sc.bedrock  .noise2array(xs_bed .data(), n, zs_bed .data(), n, t_bed .data());
    sc.elevation_scale.noise2array(xs_scale.data(), n, zs_scale.data(), n, t_scale.data());

    // ── Elevation shape base noise only (normalized to [0,1]) ───────────────
    std::vector<double> elevation_shape(static_cast<size_t>(n*n), 0.0);
    {
        std::vector<double> xs_e(n), zs_e(n);
        for (int i = 0; i < n; ++i) {
            xs_e[i] = xs[i] * cfg.elevation_shape_frequency;
            zs_e[i] = zs[i] * cfg.elevation_shape_frequency;
        }
        sc.elevation_shape.noise2array(xs_e.data(), n, zs_e.data(), n, elevation_shape.data());
    }

    // ── Detail FGM (multi-octave additive noise) ───────────────────────────
    std::vector<double> detail_fgm(static_cast<size_t>(n*n), 0.0);
    {
        double amplitude = 1.0;
        double frequency = 1.0;
        double total_amplitude = 0.0;
        std::vector<double> xs_d(n), zs_d(n), layer(static_cast<size_t>(n*n));
        for (int oct = 0; oct < std::max(1, cfg.detail_fgm_octaves); ++oct) {
            const double df = cfg.detail_fgm_frequency * frequency;
            for (int i = 0; i < n; ++i) {
                xs_d[i] = xs[i] * df;
                zs_d[i] = zs[i] * df;
            }
            sc.detail_fgm.noise2array(xs_d.data(), n, zs_d.data(), n, layer.data());
            for (int k = 0; k < n*n; ++k) detail_fgm[k] += amplitude * layer[k];
            total_amplitude += amplitude;
            amplitude *= 0.75;
            frequency *= 2.0;
        }
        if (total_amplitude > 0.0) {
            for (double& v : detail_fgm) v = (v / total_amplitude) * cfg.detail_fgm_amplitude;
        }
    }

    // ── Combine layers → final heights + biome tags ─────────────
    // Biome tags: 0.0 = sitting at bedrock, 0.5 = normal, 1.0 = plateau-capped.
    std::vector<float> out(static_cast<size_t>(n*n * 2));
    float* heights = out.data();
    float* biomes  = out.data() + n*n;
    for (int k = 0; k < n*n; ++k) {
        const double tb  = (t_bed[k] + 1.0) * 0.5;
        const double t_scale01 = (t_scale[k] + 1.0) * 0.5;
        const double shape01 = std::min(1.0, std::max(0.0, (elevation_shape[k] + 1.0) * 0.5));

        const double bedrock = bedrock_min + tb * bedrock_span;

        // layer_mode peels layers away for visual diagnostics:
        //   0=full  1=no detail  2=+no plateau  3=+scale→1ft  4=bedrock only
        double effective_scale;
        if (cfg.layer_mode >= 4) {
            effective_scale = 0.0;                              // bedrock only
        } else if (cfg.layer_mode == 3) {
            effective_scale = 1.0;                              // show shape at 1-ft scale
        } else {
            effective_scale = lo * std::pow(lo_hi_ratio, t_scale01);
        }
        // Build base elevation first; detail_fgm is applied at the very end as fine +/- feet.
        double elevation = bedrock + shape01 * effective_scale;

        bool plateau_capped = false;
        float biome = 0.5f;  // normal terrain
        if (elevation <= bedrock) biome = 0.0f;    // at/below bedrock

        // per-vertex plateau check (disabled when layer_mode >= 2)
        const double t_pz01 = std::min(1.0, std::max(0.0, (t_pz[k] + 1.0) * 0.5));
        const bool is_plateau = (cfg.layer_mode <= 1) && (t_pz01 > (1.0 - cfg.plateau_zone_threshold));
        if (is_plateau) {
            const double t_ph_base01 = std::min(1.0, std::max(0.0, (t_ph_base[k] + 1.0) * 0.5));
            double plateau_base_h_k = cfg.plateau_base_height_base + t_ph_base01 * cfg.plateau_base_height_variation;
            // Discretize plateau_base_height to 1000 ft increments
            plateau_base_h_k = std::round(plateau_base_h_k / 1000.0) * 1000.0;

            // Detail is centered around 0 in [-amplitude, +amplitude]
            double plateau_detail_h_k = std::max(-1.0, std::min(1.0, t_ph_detail[k])) * cfg.plateau_detail_height_amplitude;
            // Discretize plateau_detail_height to 5 ft increments
            plateau_detail_h_k = std::round(plateau_detail_h_k / 5.0) * 5.0;

            const double plateau_h_k = plateau_base_h_k + plateau_detail_h_k;
            const double ap = elevation - plateau_h_k;
            if (ap > 0.0) {
                // Put "above plateau" back inside a log10 shaper.
                elevation = plateau_h_k + std::log10(std::max(1.0, ap));
                plateau_capped = true;
            }
        }

        // detail_fgm is fine additive noise (feet) applied after all shaping.
        const double effective_detail = (cfg.layer_mode >= 1) ? 0.0 : detail_fgm[k];
        elevation += effective_detail;

        // Enforce bedrock floor after adding detail.
        if (elevation <= bedrock) {
            elevation = bedrock;
            biome = 0.0f;
        } else if (plateau_capped) {
            biome = 1.0f;
        }

        heights[k] = static_cast<float>(elevation);
        biomes[k]  = biome;
    }

    return out;
}
