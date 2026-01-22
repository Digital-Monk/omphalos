#!/usr/bin/env python
"""Create visual demonstrations of the game world"""
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))

import numpy as np
import matplotlib.pyplot as plt
from game.world.world import World
from game.world.player import Player


def visualize_world():
    """Create a comprehensive visualization of the game world"""
    print("Generating world visualization...")
    
    # Create world
    world = World(150, 150, seed=42)
    player = Player(75, 75)
    
    # Simulate some magic usage
    player.start_evocation_push("heat", 90, 90)
    heat_field = world.energy_fields["heat"]
    for _ in range(5):
        player.evocation.update(heat_field, 0.1)
    player.stop_evocation()
    
    # Add some spell effects
    world.energy_fields["cold"].add_energy(50, 50, 80, radius=8)
    world.energy_fields["magic"].add_energy(100, 100, 60, radius=6)
    world.energy_fields["electricity"].add_energy(40, 120, 70, radius=5)
    
    # Create visualization
    fig = plt.figure(figsize=(20, 12))
    
    # Terrain
    ax1 = plt.subplot(2, 4, 1)
    terrain_data = world.terrain.data
    im1 = ax1.imshow(terrain_data, cmap='terrain', origin='lower')
    ax1.plot(player.x, player.y, 'yo', markersize=10, markeredgecolor='red', markeredgewidth=2)
    ax1.set_title('Terrain (Procedurally Generated)', fontsize=14, fontweight='bold')
    ax1.set_xlabel('X Position')
    ax1.set_ylabel('Y Position')
    plt.colorbar(im1, ax=ax1, label='Elevation')
    
    # Temperature
    ax2 = plt.subplot(2, 4, 2)
    temp_data = world.temperature.data
    im2 = ax2.imshow(temp_data, cmap='coolwarm', origin='lower')
    ax2.plot(player.x, player.y, 'yo', markersize=10, markeredgecolor='red', markeredgewidth=2)
    ax2.set_title('Temperature Field', fontsize=14, fontweight='bold')
    ax2.set_xlabel('X Position')
    ax2.set_ylabel('Y Position')
    plt.colorbar(im2, ax=ax2, label='Temperature')
    
    # Population
    ax3 = plt.subplot(2, 4, 3)
    pop_data = world.population.data
    im3 = ax3.imshow(pop_data, cmap='viridis', origin='lower')
    ax3.plot(player.x, player.y, 'yo', markersize=10, markeredgecolor='red', markeredgewidth=2)
    ax3.set_title('Population Density', fontsize=14, fontweight='bold')
    ax3.set_xlabel('X Position')
    ax3.set_ylabel('Y Position')
    plt.colorbar(im3, ax=ax3, label='Density')
    
    # Biome map
    ax4 = plt.subplot(2, 4, 4)
    biome_map = np.zeros((world.height, world.width))
    biome_colors = {
        "mountain": 4,
        "water": 1,
        "desert": 3,
        "tundra": 2,
        "plains": 0
    }
    for y in range(world.height):
        for x in range(world.width):
            biome = world.get_biome(x, y)
            biome_map[y, x] = biome_colors.get(biome, 0)
    
    im4 = ax4.imshow(biome_map, cmap='tab10', origin='lower')
    ax4.plot(player.x, player.y, 'yo', markersize=10, markeredgecolor='red', markeredgewidth=2)
    ax4.set_title('Biome Map', fontsize=14, fontweight='bold')
    ax4.set_xlabel('X Position')
    ax4.set_ylabel('Y Position')
    
    # Energy fields
    ax5 = plt.subplot(2, 4, 5)
    heat_data = world.energy_fields["heat"].data
    im5 = ax5.imshow(heat_data, cmap='hot', origin='lower', vmin=0, vmax=50)
    ax5.plot(player.x, player.y, 'co', markersize=10, markeredgecolor='white', markeredgewidth=2)
    ax5.set_title('Heat Energy (Evocation)', fontsize=14, fontweight='bold')
    ax5.set_xlabel('X Position')
    ax5.set_ylabel('Y Position')
    plt.colorbar(im5, ax=ax5, label='Heat Level')
    
    ax6 = plt.subplot(2, 4, 6)
    cold_data = world.energy_fields["cold"].data
    im6 = ax6.imshow(cold_data, cmap='Blues', origin='lower', vmin=0, vmax=80)
    ax6.plot(player.x, player.y, 'yo', markersize=10, markeredgecolor='red', markeredgewidth=2)
    ax6.set_title('Cold Energy (Spell Effect)', fontsize=14, fontweight='bold')
    ax6.set_xlabel('X Position')
    ax6.set_ylabel('Y Position')
    plt.colorbar(im6, ax=ax6, label='Cold Level')
    
    ax7 = plt.subplot(2, 4, 7)
    magic_data = world.energy_fields["magic"].data
    im7 = ax7.imshow(magic_data, cmap='Purples', origin='lower', vmin=0, vmax=60)
    ax7.plot(player.x, player.y, 'yo', markersize=10, markeredgecolor='red', markeredgewidth=2)
    ax7.set_title('Magic Energy', fontsize=14, fontweight='bold')
    ax7.set_xlabel('X Position')
    ax7.set_ylabel('Y Position')
    plt.colorbar(im7, ax=ax7, label='Magic Level')
    
    ax8 = plt.subplot(2, 4, 8)
    elec_data = world.energy_fields["electricity"].data
    im8 = ax8.imshow(elec_data, cmap='YlOrBr', origin='lower', vmin=0, vmax=70)
    ax8.plot(player.x, player.y, 'mo', markersize=10, markeredgecolor='white', markeredgewidth=2)
    ax8.set_title('Electricity Energy', fontsize=14, fontweight='bold')
    ax8.set_xlabel('X Position')
    ax8.set_ylabel('Y Position')
    plt.colorbar(im8, ax=ax8, label='Electricity Level')
    
    # Add main title
    fig.suptitle('OMPHALOS - Procedural Open World with Magic System', 
                 fontsize=18, fontweight='bold', y=0.98)
    
    # Add legend
    legend_text = (
        "Yellow dot = Player position\n"
        "• Procedural noise generates terrain, temperature, and population\n"
        "• Magic systems overlay energy on the world\n"
        "• Energy spreads (diffusion) and decays over time"
    )
    fig.text(0.5, 0.02, legend_text, ha='center', fontsize=11, 
             bbox=dict(boxstyle='round', facecolor='wheat', alpha=0.5))
    
    plt.tight_layout(rect=[0, 0.05, 1, 0.96])
    plt.savefig('omphalos_game_demo.png', dpi=150, bbox_inches='tight')
    print("✓ Saved visualization to omphalos_game_demo.png")
    plt.close()


def visualize_magic_systems():
    """Create visualization of magic system in action"""
    print("Generating magic system visualization...")
    
    world = World(100, 100, seed=123)
    
    # Simulate a magic battle sequence
    fig, axes = plt.subplots(2, 3, figsize=(18, 12))
    
    timesteps = [
        "Initial State",
        "Fireball Cast (Heat)",
        "Ice Blast Response (Cold)",
        "Lightning Strike (Electricity)",
        "Magic Surge",
        "Energy Diffusion"
    ]
    
    # Initial
    heat = world.energy_fields["heat"]
    cold = world.energy_fields["cold"]
    magic = world.energy_fields["magic"]
    elec = world.energy_fields["electricity"]
    
    for idx, (ax, title) in enumerate(zip(axes.flat, timesteps)):
        if idx == 0:
            # Initial state
            pass
        elif idx == 1:
            # Fireball
            heat.add_energy(50, 50, 100, radius=8)
        elif idx == 2:
            # Ice blast
            cold.add_energy(70, 70, 80, radius=7)
        elif idx == 3:
            # Lightning
            elec.add_energy(30, 30, 90, radius=5)
        elif idx == 4:
            # Magic surge
            magic.add_energy(50, 70, 70, radius=6)
        
        # Update world
        world.update(0.1)
        
        # Combine all energies for visualization
        combined = heat.data + cold.data + magic.data + elec.data
        
        im = ax.imshow(combined, cmap='plasma', origin='lower', vmin=0, vmax=100)
        ax.set_title(title, fontsize=12, fontweight='bold')
        ax.set_xlabel('X Position')
        ax.set_ylabel('Y Position')
        plt.colorbar(im, ax=ax, label='Total Energy')
    
    fig.suptitle('Magic System Evolution - Energy Over Time', 
                 fontsize=16, fontweight='bold')
    plt.tight_layout()
    plt.savefig('omphalos_magic_demo.png', dpi=150, bbox_inches='tight')
    print("✓ Saved magic visualization to omphalos_magic_demo.png")
    plt.close()


if __name__ == "__main__":
    visualize_world()
    visualize_magic_systems()
    print("\n✅ All visualizations generated successfully!")
    print("\nVisualization files created:")
    print("  - omphalos_game_demo.png (comprehensive world view)")
    print("  - omphalos_magic_demo.png (magic system in action)")
