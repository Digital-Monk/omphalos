"""Spell system - Scrolls and Spellbooks"""
import json


class Spell:
    """Represents a spell effect"""
    
    def __init__(self, name, energy_type, effect_type, radius, power, cost):
        """
        Initialize a spell
        
        Args:
            name: Spell name
            energy_type: Type of energy (heat, cold, magic, etc.)
            effect_type: Effect pattern (radius, line, cone, etc.)
            radius: Effect radius
            power: Effect strength
            cost: Magic cost to cast
        """
        self.name = name
        self.energy_type = energy_type
        self.effect_type = effect_type
        self.radius = radius
        self.power = power
        self.cost = cost
    
    def cast(self, energy_field, x, y):
        """
        Cast the spell at a location
        
        Args:
            energy_field: EnergyField to modify
            x, y: Target location
        """
        if self.effect_type == "radius":
            energy_field.add_energy(x, y, self.power, self.radius)
        elif self.effect_type == "drain":
            energy_field.remove_energy(x, y, self.power, self.radius)
    
    def to_dict(self):
        """Convert spell to dictionary"""
        return {
            "name": self.name,
            "energy_type": self.energy_type,
            "effect_type": self.effect_type,
            "radius": self.radius,
            "power": self.power,
            "cost": self.cost
        }
    
    @classmethod
    def from_dict(cls, data):
        """Create spell from dictionary"""
        return cls(
            data["name"],
            data["energy_type"],
            data["effect_type"],
            data["radius"],
            data["power"],
            data["cost"]
        )


class Scroll:
    """Single-use spell scroll"""
    
    def __init__(self, spell):
        """Initialize scroll with a spell"""
        self.spell = spell
        self.used = False
    
    def cast(self, player_stats, energy_field, x, y):
        """Cast the scroll"""
        if self.used:
            return False
        
        if player_stats.use_magic(self.spell.cost):
            self.spell.cast(energy_field, x, y)
            self.used = True
            return True
        return False


class Spellbook:
    """Collection of spells that can be cast multiple times"""
    
    def __init__(self):
        """Initialize empty spellbook"""
        self.spells = []
    
    def add_spell(self, spell):
        """Add a spell to the spellbook"""
        self.spells.append(spell)
    
    def remove_spell(self, index):
        """Remove a spell from the spellbook"""
        if 0 <= index < len(self.spells):
            return self.spells.pop(index)
        return None
    
    def cast_spell(self, index, player_stats, energy_field, x, y):
        """Cast a spell from the spellbook"""
        if 0 <= index < len(self.spells):
            spell = self.spells[index]
            if player_stats.use_magic(spell.cost):
                spell.cast(energy_field, x, y)
                return True
        return False
    
    def save_to_file(self, filename):
        """Save spellbook to file"""
        data = [spell.to_dict() for spell in self.spells]
        with open(filename, 'w') as f:
            json.dump(data, f, indent=2)
    
    def load_from_file(self, filename):
        """Load spellbook from file"""
        with open(filename, 'r') as f:
            data = json.load(f)
        self.spells = [Spell.from_dict(spell_data) for spell_data in data]
