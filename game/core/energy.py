"""Energy system for world mechanics"""
import numpy as np


class EnergyNode:
    """Represents an object or area that can store and transfer energy"""
    
    def __init__(self, capacity=100, current=0, flow_rate=1.0):
        """
        Initialize an energy node
        
        Args:
            capacity: Maximum energy storage
            current: Current energy level
            flow_rate: Rate of energy transfer
        """
        self.capacity = capacity
        self.current = min(current, capacity)
        self.flow_rate = flow_rate
        self.connections = []  # Connected nodes
    
    def add_energy(self, amount):
        """Add energy to this node"""
        old = self.current
        self.current = min(self.current + amount, self.capacity)
        return self.current - old  # Actual amount added
    
    def remove_energy(self, amount):
        """Remove energy from this node"""
        old = self.current
        self.current = max(self.current - amount, 0)
        return old - self.current  # Actual amount removed
    
    def connect(self, other_node):
        """Connect this node to another for energy flow"""
        if other_node not in self.connections:
            self.connections.append(other_node)
    
    def flow_to(self, other_node):
        """Transfer energy to another node based on gradient"""
        if self.current > other_node.current:
            # Energy flows from high to low
            gradient = (self.current - other_node.current) / 2
            transfer = min(gradient * self.flow_rate, self.current)
            actual = self.remove_energy(transfer)
            other_node.add_energy(actual)
            return actual
        return 0


class EnergyField:
    """Energy field overlay for spatial energy distribution"""
    
    def __init__(self, width, height, energy_type="heat", decay_rate=0.02):
        """
        Initialize an energy field
        
        Args:
            width: Field width
            height: Field height
            energy_type: Type of energy (heat, cold, magic, etc.)
            decay_rate: Energy dissipation rate
        """
        self.width = width
        self.height = height
        self.energy_type = energy_type
        self.decay_rate = decay_rate
        self.data = np.zeros((height, width), dtype=np.float32)
    
    def add_energy(self, x, y, amount, radius=5):
        """Add energy at a position with a radius"""
        for dy in range(-radius, radius + 1):
            for dx in range(-radius, radius + 1):
                px, py = int(x + dx), int(y + dy)
                if 0 <= px < self.width and 0 <= py < self.height:
                    distance = np.sqrt(dx*dx + dy*dy)
                    if distance <= radius:
                        falloff = 1 - (distance / radius)
                        self.data[py, px] += amount * falloff
    
    def remove_energy(self, x, y, amount, radius=5):
        """Remove energy at a position"""
        self.add_energy(x, y, -amount, radius)
    
    def update(self):
        """Update energy field (apply decay and diffusion)"""
        # Decay
        self.data *= (1 - self.decay_rate)
        
        # Simple diffusion (energy spreads to neighbors)
        # Create a copy for neighbor averaging
        diffused = np.copy(self.data)
        for y in range(1, self.height - 1):
            for x in range(1, self.width - 1):
                neighbors = (
                    self.data[y-1, x] + self.data[y+1, x] +
                    self.data[y, x-1] + self.data[y, x+1]
                ) / 4
                # Blend current with neighbors (simple diffusion)
                diffused[y, x] = self.data[y, x] * 0.8 + neighbors * 0.2
        
        self.data = diffused
    
    def get_value(self, x, y):
        """Get energy level at position"""
        if 0 <= x < self.width and 0 <= y < self.height:
            return self.data[int(y), int(x)]
        return 0
