"""Planet terrain sampling using wrapped noise."""
import math

from noise import pnoise2

MIN_SCALE = 1e-6


class PlanetTerrain:
    """Provides deterministic terrain sampling on a spherical planet."""

    def __init__(
        self,
        radius=1000.0,
        seed=0,
        scale=1.0,
        octaves=6,
        persistence=0.5,
        lacunarity=2.0,
        altitude_scale=1.0,
        wrap=256,
    ):
        """
        Initialize planet terrain sampling.

        Args:
            radius: Base planet radius.
            seed: Noise seed.
            scale: Noise scale.
            octaves: Noise octaves.
            persistence: Noise persistence.
            lacunarity: Noise lacunarity.
            altitude_scale: Scale applied to noise value.
            wrap: Seamless noise wrap size for longitude/latitude.
        """
        self.radius = radius
        self.seed = seed
        self.scale = max(MIN_SCALE, scale)
        self.octaves = octaves
        self.persistence = persistence
        self.lacunarity = lacunarity
        self.altitude_scale = altitude_scale
        self.wrap = max(1, int(round(wrap)))
        # Scale repeat to align wrap length with noise scale for seamless sampling.
        self._repeat = max(1, int(round(self.wrap * self.scale)))
        self._wrap_scale = float(self._repeat)

    def _normalize_lat_lon(self, latitude, longitude):
        latitude = max(-math.pi / 2, min(math.pi / 2, latitude))
        longitude = (longitude + math.pi) % (2 * math.pi) - math.pi
        return latitude, longitude

    def _noise_coords(self, latitude, longitude):
        latitude, longitude = self._normalize_lat_lon(latitude, longitude)
        u = (longitude + math.pi) / (2 * math.pi)
        v = (latitude + math.pi / 2) / math.pi
        return u * self._wrap_scale, v * self._wrap_scale

    def sample_altitude(self, latitude, longitude):
        """Return the altitude offset for a given latitude/longitude."""
        noise_x, noise_y = self._noise_coords(latitude, longitude)
        value = pnoise2(
            noise_x,
            noise_y,
            octaves=self.octaves,
            persistence=self.persistence,
            lacunarity=self.lacunarity,
            repeatx=self._repeat,
            repeaty=self._repeat,
            base=self.seed,
        )
        return value * self.altitude_scale

    def surface_point(self, latitude, longitude):
        """Return x, y, z for a surface point at latitude/longitude."""
        latitude, longitude = self._normalize_lat_lon(latitude, longitude)
        altitude = self.sample_altitude(latitude, longitude)
        radius = self.radius + altitude
        cos_lat = math.cos(latitude)
        x = radius * cos_lat * math.cos(longitude)
        y = radius * cos_lat * math.sin(longitude)
        z = radius * math.sin(latitude)
        return x, y, z
