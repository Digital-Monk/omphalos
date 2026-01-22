"""Overlay system for modifying world properties"""
import numpy as np


class Overlay:
    """Represents a modification overlay that can be applied to noise fields"""
    
    def __init__(self, width, height, decay_rate=0.01):
        """
        Initialize an overlay
        
        Args:
            width: Width of the overlay
            height: Height of the overlay
            decay_rate: Rate at which the overlay fades (0-1 per update)
        """
        self.width = width
        self.height = height
        self.decay_rate = decay_rate
        # Overlay data: 0.5 = neutral, >0.5 = positive, <0.5 = negative
        self.data = np.full((height, width), 0.5, dtype=np.float32)
        self.active = True
    
    def apply_effect(self, x, y, radius, intensity):
        """
        Apply a circular effect to the overlay
        
        Args:
            x, y: Center position
            radius: Effect radius
            intensity: Effect strength (-0.5 to +0.5, added to 0.5 neutral)
        """
        for dy in range(-radius, radius + 1):
            for dx in range(-radius, radius + 1):
                px, py = int(x + dx), int(y + dy)
                if 0 <= px < self.width and 0 <= py < self.height:
                    distance = np.sqrt(dx*dx + dy*dy)
                    if distance <= radius:
                        # Falloff with distance
                        falloff = 1 - (distance / radius)
                        effect = 0.5 + (intensity * falloff)
                        # Blend with existing overlay
                        self.data[py, px] = np.clip(
                            self.data[py, px] * 0.5 + effect * 0.5,
                            0, 1
                        )
    
    def update(self):
        """Update overlay (apply decay)"""
        # Decay towards neutral (0.5)
        self.data = self.data * (1 - self.decay_rate) + 0.5 * self.decay_rate
        
        # Check if overlay is effectively neutral
        if np.allclose(self.data, 0.5, atol=0.01):
            self.active = False
    
    def combine_with_field(self, field):
        """
        Combine this overlay with a noise field
        
        Args:
            field: NoiseField to modify
            
        Returns:
            Modified field data
        """
        # Convert overlay deviation to multiplicative factor
        # 0.5 = 1x (no change), 0.0 = 0x (full negative), 1.0 = 2x (full positive)
        factor = self.data * 2
        result = field.data * factor
        return np.clip(result, 0, 1)
