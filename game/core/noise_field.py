"""Noise field generation using Perlin/Simplex noise"""
import numpy as np
from noise import pnoise2


class NoiseField:
    """Represents a procedurally generated noise field for world properties"""
    
    def __init__(self, width, height, seed=0, scale=0.1, octaves=6, persistence=0.5, lacunarity=2.0):
        """
        Initialize a noise field
        
        Args:
            width: Width of the field
            height: Height of the field
            seed: Random seed for reproducibility
            scale: Scale of the noise (smaller = more detail)
            octaves: Number of noise layers
            persistence: How much each octave contributes
            lacunarity: Frequency multiplier between octaves
        """
        self.width = width
        self.height = height
        self.seed = seed
        self.scale = scale
        self.octaves = octaves
        self.persistence = persistence
        self.lacunarity = lacunarity
        self.data = self._generate()
    
    def _generate(self):
        """Generate the noise field"""
        field = np.zeros((self.height, self.width))
        for y in range(self.height):
            for x in range(self.width):
                value = pnoise2(
                    x * self.scale,
                    y * self.scale,
                    octaves=self.octaves,
                    persistence=self.persistence,
                    lacunarity=self.lacunarity,
                    base=self.seed
                )
                # Normalize to 0-1 range
                field[y, x] = (value + 1) / 2
        return field
    
    def get_value(self, x, y):
        """Get the value at a specific position"""
        if 0 <= x < self.width and 0 <= y < self.height:
            return self.data[int(y), int(x)]
        return 0.5
    
    def set_value(self, x, y, value):
        """Set the value at a specific position"""
        if 0 <= x < self.width and 0 <= y < self.height:
            self.data[int(y), int(x)] = np.clip(value, 0, 1)
