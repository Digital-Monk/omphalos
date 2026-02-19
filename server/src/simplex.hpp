#pragma once
// ============================================================
// simplex.hpp — Seeded 2D Simplex noise, header-only.
//
// Based on Stefan Gustavson's public-domain implementation
// (https://weber.itn.liu.se/~stegu/simplexnoise/simplexnoise.pdf)
// with per-seed Knuth/Fisher-Yates permutation shuffle.
//
// Output range: approximately [-1, +1].
// noise2array() computes an outer-product grid in one call,
// matching OpenSimplex's noise2array(xs, ys) → (len(ys), len(xs)).
// ============================================================

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <numeric>
#include <random>
#include <vector>

class SimplexNoise {
public:
    explicit SimplexNoise(int seed) {
        // Build permutation table for this seed.
        std::iota(p_.begin(), p_.end(), 0);
        std::mt19937 rng(static_cast<uint32_t>(seed));
        std::shuffle(p_.begin(), p_.end(), rng);
        // Mirror for wrapping lookup.
        for (int i = 0; i < 256; ++i) perm_[i] = perm_[i+256] = p_[i];
    }

    // Single-point 2D simplex noise → [-1, 1].
    double noise2(double xin, double yin) const noexcept {
        // Skew input space to simplex grid.
        static constexpr double F2 = 0.5 * (1.7320508075688772 - 1.0); // (sqrt3-1)/2
        static constexpr double G2 = (3.0 - 1.7320508075688772) / 6.0;

        const double s  = (xin + yin) * F2;
        const int    i  = fast_floor(xin + s);
        const int    j  = fast_floor(yin + s);
        const double t  = (i + j) * G2;
        const double X0 = i - t;
        const double Y0 = j - t;
        const double x0 = xin - X0;
        const double y0 = yin - Y0;

        // Simplex traversal order.
        const int i1 = (x0 > y0) ? 1 : 0;
        const int j1 = (x0 > y0) ? 0 : 1;

        const double x1 = x0 - i1 + G2;
        const double y1 = y0 - j1 + G2;
        const double x2 = x0 - 1.0 + 2.0 * G2;
        const double y2 = y0 - 1.0 + 2.0 * G2;

        const int ii = i & 255;
        const int jj = j & 255;
        const int gi0 = perm_[ii +      perm_[jj     ]] % 12;
        const int gi1 = perm_[ii + i1 + perm_[jj + j1]] % 12;
        const int gi2 = perm_[ii + 1  + perm_[jj + 1 ]] % 12;

        double n0, n1, n2;

        double t0 = 0.5 - x0*x0 - y0*y0;
        if (t0 < 0.0) { n0 = 0.0; }
        else { t0 *= t0; n0 = t0 * t0 * grad_dot(gi0, x0, y0); }

        double t1 = 0.5 - x1*x1 - y1*y1;
        if (t1 < 0.0) { n1 = 0.0; }
        else { t1 *= t1; n1 = t1 * t1 * grad_dot(gi1, x1, y1); }

        double t2 = 0.5 - x2*x2 - y2*y2;
        if (t2 < 0.0) { n2 = 0.0; }
        else { t2 *= t2; n2 = t2 * t2 * grad_dot(gi2, x2, y2); }

        return 70.0 * (n0 + n1 + n2);
    }

    // Batch: xs[nx] × ys[ny] outer product → out[ny * nx] (row-major, y outer).
    // Matches Python opensimplex.noise2array(xs, ys) layout.
    void noise2array(const double* xs, int nx,
                     const double* ys, int ny,
                     double* out) const noexcept {
        for (int iy = 0; iy < ny; ++iy) {
            for (int ix = 0; ix < nx; ++ix) {
                out[iy * nx + ix] = noise2(xs[ix], ys[iy]);
            }
        }
    }

    // Convenience: std::vector overload.
    std::vector<double> noise2array(const std::vector<double>& xs,
                                    const std::vector<double>& ys) const {
        const int nx = static_cast<int>(xs.size());
        const int ny = static_cast<int>(ys.size());
        std::vector<double> out(static_cast<size_t>(nx * ny));
        noise2array(xs.data(), nx, ys.data(), ny, out.data());
        return out;
    }

private:
    std::array<int, 256> p_{};
    std::array<int, 512> perm_{};

    static int fast_floor(double x) noexcept {
        return (x >= 0.0) ? static_cast<int>(x) : static_cast<int>(x) - 1;
    }

    // 2D gradient directions (unit vectors scaled to avoid normalisation).
    static constexpr double GRAD[12][2] = {
        { 1, 1}, {-1, 1}, { 1,-1}, {-1,-1},
        { 1, 0}, {-1, 0}, { 1, 0}, {-1, 0},
        { 0, 1}, { 0,-1}, { 0, 1}, { 0,-1},
    };

    static double grad_dot(int gi, double x, double y) noexcept {
        return GRAD[gi][0] * x + GRAD[gi][1] * y;
    }
};
