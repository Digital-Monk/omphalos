"""Evocation - Push/Pull energy mechanics"""
from game.core.energy import EnergyField


class Evocation:
    """Evocation magic system - direct energy manipulation"""
    
    def __init__(self, player_stats):
        """
        Initialize evocation system
        
        Args:
            player_stats: PlayerStats object
        """
        self.player_stats = player_stats
        self.is_pushing = False
        self.is_pulling = False
        self.target_x = 0
        self.target_y = 0
        self.energy_type = "heat"
        self.surge_active = False
    
    def start_push(self, energy_type, target_x, target_y):
        """Start pushing energy to target"""
        self.is_pushing = True
        self.is_pulling = False
        self.energy_type = energy_type
        self.target_x = target_x
        self.target_y = target_y
    
    def start_pull(self, energy_type, target_x, target_y):
        """Start pulling energy from target"""
        self.is_pulling = True
        self.is_pushing = False
        self.energy_type = energy_type
        self.target_x = target_x
        self.target_y = target_y
    
    def stop(self):
        """Stop evocation"""
        self.is_pushing = False
        self.is_pulling = False
        self.surge_active = False
    
    def activate_surge(self):
        """Activate surge for more power"""
        self.surge_active = True
    
    def update(self, energy_field, dt):
        """
        Update evocation state
        
        Args:
            energy_field: EnergyField to modify
            dt: Delta time
            
        Returns:
            Energy amount transferred
        """
        if not (self.is_pushing or self.is_pulling):
            return 0
        
        # Calculate base transfer rate
        efficiency = self.player_stats.get_evocation_efficiency()
        base_rate = 5 * efficiency * dt
        
        # Apply surge multiplier
        if self.surge_active:
            rate = base_rate * 2
            magic_cost = 2 * dt
        else:
            rate = base_rate
            magic_cost = 1 * dt
        
        # Check if we have enough magic before attempting transfer
        if self.player_stats.current_magic_reserve < magic_cost:
            self.stop()
            return 0
        
        # Drain magic reserve
        if not self.player_stats.use_magic(magic_cost):
            self.stop()
            return 0
        
        # Apply energy transfer
        if self.is_pushing:
            energy_field.add_energy(self.target_x, self.target_y, rate, radius=3)
            return rate
        elif self.is_pulling:
            energy_field.remove_energy(self.target_x, self.target_y, rate, radius=3)
            return -rate
        
        return 0
