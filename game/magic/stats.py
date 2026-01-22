"""Player statistics and attributes"""


class PlayerStats:
    """Player character statistics"""
    
    def __init__(self):
        """Initialize player stats"""
        # Core attributes
        self.willpower = 10  # Evocation efficiency and surge power
        self.wisdom = 10     # Spell cost reduction
        self.intelligence = 10  # Spell complexity
        self.dexterity = 10  # Casting speed and control
        self.charisma = 10   # Alternative to willpower
        
        # Magic reserve
        self.max_magic_reserve = 100
        self.current_magic_reserve = 100
        
        # Experience
        self.experience = 0
        self.level = 1
    
    def get_evocation_efficiency(self):
        """Calculate evocation efficiency (0-1)"""
        return min(1.0, (self.willpower + self.charisma) / 40)
    
    def get_spell_cost_multiplier(self):
        """Calculate spell cost multiplier"""
        return max(0.5, 1.0 - (self.wisdom / 100))
    
    def get_spell_complexity(self):
        """Get maximum spell complexity"""
        return 1 + (self.intelligence // 5)
    
    def get_casting_speed(self):
        """Get casting speed multiplier"""
        return 1.0 + (self.dexterity / 50)
    
    def use_magic(self, cost):
        """Use magic reserve"""
        actual_cost = cost * self.get_spell_cost_multiplier()
        if self.current_magic_reserve >= actual_cost:
            self.current_magic_reserve -= actual_cost
            return True
        return False
    
    def restore_magic(self, amount):
        """Restore magic reserve"""
        self.current_magic_reserve = min(
            self.current_magic_reserve + amount,
            self.max_magic_reserve
        )
