"""World state and management"""
from game.core.noise_field import NoiseField
from game.core.overlay import Overlay
from game.core.energy import EnergyField


class World:
    """Represents the game world with all its systems"""
    
    def __init__(self, width=200, height=200, seed=42):
        """
        Initialize the world
        
        Args:
            width: World width
            height: World height
            seed: Random seed for procedural generation
        """
        self.width = width
        self.height = height
        self.seed = seed
        
        # Noise fields for base properties
        self.terrain = NoiseField(width, height, seed=seed, scale=0.05, octaves=6)
        self.population = NoiseField(width, height, seed=seed+1, scale=0.1, octaves=4)
        self.temperature = NoiseField(width, height, seed=seed+2, scale=0.08, octaves=5)
        
        # Energy fields
        self.energy_fields = {
            "heat": EnergyField(width, height, "heat", decay_rate=0.02),
            "cold": EnergyField(width, height, "cold", decay_rate=0.02),
            "magic": EnergyField(width, height, "magic", decay_rate=0.01),
            "electricity": EnergyField(width, height, "electricity", decay_rate=0.05)
        }
        
        # Overlays for modifications
        self.overlays = []
    
    def add_overlay(self, overlay):
        """Add a new overlay to the world"""
        self.overlays.append(overlay)
    
    def get_terrain_value(self, x, y):
        """Get terrain value with overlays applied"""
        base = self.terrain.get_value(x, y)
        # Apply all active overlays
        result = base
        for overlay in self.overlays:
            if overlay.active:
                combined = overlay.combine_with_field(self.terrain)
                # Blend the overlay effect
                result = (result + combined[int(y), int(x)]) / 2
        return result
    
    def get_energy_value(self, x, y, energy_type):
        """Get energy value at a position"""
        if energy_type in self.energy_fields:
            return self.energy_fields[energy_type].get_value(x, y)
        return 0
    
    def update(self, dt):
        """
        Update world state
        
        Args:
            dt: Delta time in seconds
        """
        # Update energy fields
        for energy_field in self.energy_fields.values():
            energy_field.update()
        
        # Update overlays
        for overlay in self.overlays:
            if overlay.active:
                overlay.update()
        
        # Remove inactive overlays
        self.overlays = [o for o in self.overlays if o.active]
    
    def get_biome(self, x, y):
        """Determine biome based on terrain and temperature"""
        terrain = self.get_terrain_value(x, y)
        temp = self.temperature.get_value(x, y)
        
        # Simple biome classification
        if terrain > 0.7:
            return "mountain"
        elif terrain < 0.3:
            return "water"
        elif temp > 0.7:
            return "desert"
        elif temp < 0.3:
            return "tundra"
        else:
            return "plains"
