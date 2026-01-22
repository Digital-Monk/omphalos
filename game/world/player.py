"""Player character and interaction"""
from game.magic.stats import PlayerStats
from game.magic.evocation import Evocation
from game.magic.spells import Spellbook
from game.magic.thaumaturgy import Thaumaturgy


class Player:
    """Player character"""
    
    def __init__(self, x=100, y=100):
        """
        Initialize player
        
        Args:
            x, y: Starting position
        """
        self.x = x
        self.y = y
        self.stats = PlayerStats()
        
        # Magic systems
        self.evocation = Evocation(self.stats)
        self.spellbook = Spellbook()
        self.thaumaturgy = Thaumaturgy(self.stats)
        
        # Inventory
        self.scrolls = []
    
    def move(self, dx, dy, world):
        """Move player"""
        new_x = self.x + dx
        new_y = self.y + dy
        
        # Bounds check
        if 0 <= new_x < world.width and 0 <= new_y < world.height:
            self.x = new_x
            self.y = new_y
    
    def start_evocation_push(self, energy_type, target_x, target_y):
        """Start pushing energy"""
        self.evocation.start_push(energy_type, target_x, target_y)
    
    def start_evocation_pull(self, energy_type, target_x, target_y):
        """Start pulling energy"""
        self.evocation.start_pull(energy_type, target_x, target_y)
    
    def stop_evocation(self):
        """Stop evocation"""
        self.evocation.stop()
    
    def cast_spell(self, spell_index, world, target_x, target_y):
        """Cast a spell from spellbook"""
        energy_field = world.energy_fields.get("magic")
        if energy_field:
            return self.spellbook.cast_spell(
                spell_index, self.stats, energy_field, target_x, target_y
            )
        return False
    
    def use_scroll(self, scroll_index, world, target_x, target_y):
        """Use a scroll"""
        if 0 <= scroll_index < len(self.scrolls):
            scroll = self.scrolls[scroll_index]
            energy_field = world.energy_fields.get("magic")
            if energy_field and scroll.cast(self.stats, energy_field, target_x, target_y):
                self.scrolls.pop(scroll_index)
                return True
        return False
    
    def update(self, world, dt):
        """Update player state"""
        # Update evocation
        if self.evocation.is_pushing or self.evocation.is_pulling:
            energy_type = self.evocation.energy_type
            if energy_type in world.energy_fields:
                self.evocation.update(world.energy_fields[energy_type], dt)
        
        # Restore magic slowly over time
        self.stats.restore_magic(0.5 * dt)
