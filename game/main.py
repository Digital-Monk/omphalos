"""Main game loop and rendering"""
import pygame
import numpy as np
import sys
from game.world.world import World
from game.world.player import Player
from game.magic.spells import Spell


class Game:
    """Main game class"""
    
    def __init__(self, width=800, height=600):
        """Initialize the game"""
        pygame.init()
        self.screen_width = width
        self.screen_height = height
        self.screen = pygame.display.set_mode((width, height))
        pygame.display.set_caption("Omphalos - Procedural Open World")
        self.clock = pygame.time.Clock()
        
        # Game state
        self.world = World(width=200, height=200)
        self.player = Player(x=100, y=100)
        
        # Camera
        self.camera_x = 0
        self.camera_y = 0
        self.zoom = 4  # Pixels per world unit
        
        # UI state
        self.show_debug = True
        self.selected_energy = "heat"
        self.font = pygame.font.Font(None, 24)
        self.small_font = pygame.font.Font(None, 18)
        
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
    
    def handle_events(self):
        """Handle input events"""
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                self.running = False
            
            elif event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    self.running = False
                elif event.key == pygame.K_BACKQUOTE:  # ~ key
                    self.show_debug = not self.show_debug
                elif event.key == pygame.K_1:
                    self.selected_energy = "heat"
                elif event.key == pygame.K_2:
                    self.selected_energy = "cold"
                elif event.key == pygame.K_3:
                    self.selected_energy = "magic"
                elif event.key == pygame.K_4:
                    self.selected_energy = "electricity"
                # Cast spells with Q, W, E
                elif event.key == pygame.K_q:
                    mouse_x, mouse_y = pygame.mouse.get_pos()
                    world_x, world_y = self.screen_to_world(mouse_x, mouse_y)
                    self.player.cast_spell(0, self.world, world_x, world_y)
                elif event.key == pygame.K_w:
                    mouse_x, mouse_y = pygame.mouse.get_pos()
                    world_x, world_y = self.screen_to_world(mouse_x, mouse_y)
                    self.player.cast_spell(1, self.world, world_x, world_y)
                elif event.key == pygame.K_e:
                    mouse_x, mouse_y = pygame.mouse.get_pos()
                    world_x, world_y = self.screen_to_world(mouse_x, mouse_y)
                    self.player.cast_spell(2, self.world, world_x, world_y)
            
            elif event.type == pygame.MOUSEBUTTONDOWN:
                mouse_x, mouse_y = pygame.mouse.get_pos()
                world_x, world_y = self.screen_to_world(mouse_x, mouse_y)
                
                if event.button == 1:  # Left click - push
                    self.player.start_evocation_push(self.selected_energy, world_x, world_y)
                elif event.button == 3:  # Right click - pull
                    self.player.start_evocation_pull(self.selected_energy, world_x, world_y)
            
            elif event.type == pygame.MOUSEBUTTONUP:
                if event.button in (1, 3):
                    self.player.stop_evocation()
        
        # Continuous keyboard input
        keys = pygame.key.get_pressed()
        move_speed = 2
        if keys[pygame.K_UP] or keys[pygame.K_w]:
            self.player.move(0, -move_speed, self.world)
        if keys[pygame.K_DOWN] or keys[pygame.K_s]:
            self.player.move(0, move_speed, self.world)
        if keys[pygame.K_LEFT] or keys[pygame.K_a]:
            self.player.move(-move_speed, 0, self.world)
        if keys[pygame.K_RIGHT] or keys[pygame.K_d]:
            self.player.move(move_speed, 0, self.world)
    
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
    
    def render_terrain(self):
        """Render the terrain"""
        # Calculate visible world bounds
        start_x = max(0, int(self.camera_x))
        start_y = max(0, int(self.camera_y))
        end_x = min(self.world.width, int(self.camera_x + self.screen_width / self.zoom) + 1)
        end_y = min(self.world.height, int(self.camera_y + self.screen_height / self.zoom) + 1)
        
        for y in range(start_y, end_y):
            for x in range(start_x, end_x):
                terrain_value = self.world.get_terrain_value(x, y)
                temp_value = self.world.temperature.get_value(x, y)
                
                # Color based on biome
                biome = self.world.get_biome(x, y)
                if biome == "mountain":
                    color = (100, 100, 100)
                elif biome == "water":
                    color = (50, 50, 200)
                elif biome == "desert":
                    color = (200, 180, 100)
                elif biome == "tundra":
                    color = (220, 220, 255)
                else:  # plains
                    color = (100, 180, 100)
                
                # Draw tile
                screen_x, screen_y = self.world_to_screen(x, y)
                pygame.draw.rect(
                    self.screen,
                    color,
                    (screen_x, screen_y, self.zoom, self.zoom)
                )
    
    def render_energy_overlay(self, energy_type):
        """Render energy field as overlay"""
        energy_field = self.world.energy_fields.get(energy_type)
        if not energy_field:
            return
        
        # Calculate visible world bounds
        start_x = max(0, int(self.camera_x))
        start_y = max(0, int(self.camera_y))
        end_x = min(self.world.width, int(self.camera_x + self.screen_width / self.zoom) + 1)
        end_y = min(self.world.height, int(self.camera_y + self.screen_height / self.zoom) + 1)
        
        for y in range(start_y, end_y):
            for x in range(start_x, end_x):
                energy = energy_field.get_value(x, y)
                if energy > 0.1:  # Only draw if significant
                    # Color based on energy type
                    if energy_type == "heat":
                        color = (255, int(100 * (1 - energy/50)), 0)
                    elif energy_type == "cold":
                        color = (0, int(100 * (1 - energy/50)), 255)
                    elif energy_type == "magic":
                        color = (200, 0, 200)
                    elif energy_type == "electricity":
                        color = (255, 255, 0)
                    else:
                        color = (255, 255, 255)
                    
                    alpha = min(255, int(energy * 5))
                    screen_x, screen_y = self.world_to_screen(x, y)
                    
                    # Create surface for alpha blending
                    surf = pygame.Surface((self.zoom, self.zoom))
                    surf.set_alpha(alpha)
                    surf.fill(color)
                    self.screen.blit(surf, (screen_x, screen_y))
    
    def render_player(self):
        """Render the player"""
        screen_x, screen_y = self.world_to_screen(self.player.x, self.player.y)
        pygame.draw.circle(
            self.screen,
            (255, 255, 0),
            (screen_x + self.zoom // 2, screen_y + self.zoom // 2),
            max(2, self.zoom // 2)
        )
    
    def render_ui(self):
        """Render UI elements"""
        # Background for UI
        ui_bg = pygame.Surface((self.screen_width, 120))
        ui_bg.set_alpha(200)
        ui_bg.fill((20, 20, 20))
        self.screen.blit(ui_bg, (0, self.screen_height - 120))
        
        # Player stats
        y_offset = self.screen_height - 110
        stats_text = [
            f"Position: ({int(self.player.x)}, {int(self.player.y)})",
            f"Magic: {int(self.player.stats.current_magic_reserve)}/{self.player.stats.max_magic_reserve}",
            f"Energy Type: {self.selected_energy} (1-4 to change)",
            f"Evocation: {'ACTIVE' if self.player.evocation.is_pushing or self.player.evocation.is_pulling else 'OFF'}",
        ]
        
        for i, text in enumerate(stats_text):
            surface = self.small_font.render(text, True, (255, 255, 255))
            self.screen.blit(surface, (10, y_offset + i * 20))
        
        # Spells
        spell_text = "Spells: "
        for i, spell in enumerate(self.player.spellbook.spells):
            spell_text += f"[{chr(81+i)}] {spell.name}  "
        surface = self.small_font.render(spell_text, True, (200, 200, 255))
        self.screen.blit(surface, (300, y_offset))
        
        # Controls help
        controls = self.small_font.render(
            "LMB: Push | RMB: Pull | WASD: Move | Q/W/E: Cast | ~: Debug",
            True, (180, 180, 180)
        )
        self.screen.blit(controls, (10, 5))
    
    def render(self):
        """Render the game"""
        self.screen.fill((0, 0, 0))
        
        # Render terrain
        self.render_terrain()
        
        # Render energy overlays if debug mode
        if self.show_debug:
            for energy_type in ["heat", "cold", "magic", "electricity"]:
                self.render_energy_overlay(energy_type)
        else:
            # Only show selected energy type
            self.render_energy_overlay(self.selected_energy)
        
        # Render player
        self.render_player()
        
        # Render UI
        self.render_ui()
        
        pygame.display.flip()
    
    def run(self):
        """Main game loop"""
        while self.running:
            dt = self.clock.tick(60) / 1000.0  # Delta time in seconds
            
            self.handle_events()
            self.update(dt)
            self.render()
        
        pygame.quit()
        sys.exit()


def main():
    """Entry point"""
    game = Game()
    game.run()


if __name__ == "__main__":
    main()
