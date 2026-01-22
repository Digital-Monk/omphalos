"""Main game logic - to be integrated with Godot"""
import numpy as np
import sys
from game.world.world import World
from game.world.player import Player
from game.magic.spells import Spell


class Game:
    """Main game class - game logic without rendering (to be integrated with Godot)"""
    
    def __init__(self, width=800, height=600):
        """Initialize the game"""
        self.screen_width = width
        self.screen_height = height
        
        # Game state
        self.world = World(width=200, height=200)
        self.player = Player(x=100, y=100)
        
        # Camera
        self.camera_x = 0
        self.camera_y = 0
        self.zoom = 4  # Pixels per world unit
        
        # UI state - these will be used by Godot for rendering decisions
        self.show_debug = True  # Controls whether to show all energy overlays or just selected
        self.selected_energy = "heat"  # Currently selected energy type for evocation
        
        # Add some starter spells
        self._setup_starter_spells()
        
        self.running = True
    
    def _setup_starter_spells(self):
        """Add some starter spells to the player"""
        fireball = Spell("Fireball", "heat", "radius", 5, 50, 10)
        ice_blast = Spell("Ice Blast", "cold", "radius", 4, 40, 8)
        magic_bolt = Spell("Magic Bolt", "magic", "radius", 3, 30, 5)
        
        self.player.spellbook.add_spell(fireball)
        self.player.spellbook.add_spell(ice_blast)
        self.player.spellbook.add_spell(magic_bolt)
    
    def screen_to_world(self, screen_x, screen_y):
        """Convert screen coordinates to world coordinates"""
        world_x = (screen_x / self.zoom) + self.camera_x
        world_y = (screen_y / self.zoom) + self.camera_y
        return int(world_x), int(world_y)
    
    def world_to_screen(self, world_x, world_y):
        """Convert world coordinates to screen coordinates"""
        screen_x = (world_x - self.camera_x) * self.zoom
        screen_y = (world_y - self.camera_y) * self.zoom
        return int(screen_x), int(screen_y)
    
    def update(self, dt):
        """Update game state"""
        # Update camera to follow player
        self.camera_x = self.player.x - (self.screen_width / self.zoom / 2)
        self.camera_y = self.player.y - (self.screen_height / self.zoom / 2)
        
        # Update world
        self.world.update(dt)
        
        # Update player
        self.player.update(self.world, dt)


def main():
    """Entry point - game logic is ready to be integrated with Godot"""
    print("Omphalos game logic initialized.")
    print("This module contains the core game logic and should be integrated with Godot for rendering.")
    print("The game is now a Godot-based game - PyGame has been removed.")
    game = Game()
    print(f"World created: {game.world.width}x{game.world.height}")
    print(f"Player position: ({game.player.x}, {game.player.y})")


if __name__ == "__main__":
    main()
