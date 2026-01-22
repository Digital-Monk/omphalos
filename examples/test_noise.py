"""Example: Test noise field generation"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import numpy as np
import matplotlib.pyplot as plt
from game.core.noise_field import NoiseField
from game.core.overlay import Overlay


def visualize_noise_field():
    """Create and visualize noise fields"""
    print("Generating noise fields...")
    
    # Create terrain field
    terrain = NoiseField(100, 100, seed=42, scale=0.05, octaves=6)
    
    # Create temperature field
    temperature = NoiseField(100, 100, seed=43, scale=0.08, octaves=5)
    
    # Create population field
    population = NoiseField(100, 100, seed=44, scale=0.1, octaves=4)
    
    # Create an overlay
    overlay = Overlay(100, 100, decay_rate=0.01)
    overlay.apply_effect(50, 50, radius=15, intensity=0.3)  # Positive effect
    overlay.apply_effect(25, 75, radius=10, intensity=-0.2)  # Negative effect
    
    # Combine overlay with terrain
    modified_terrain = overlay.combine_with_field(terrain)
    
    # Visualize
    fig, axes = plt.subplots(2, 3, figsize=(15, 10))
    
    axes[0, 0].imshow(terrain.data, cmap='terrain')
    axes[0, 0].set_title('Terrain (Base)')
    
    axes[0, 1].imshow(temperature.data, cmap='coolwarm')
    axes[0, 1].set_title('Temperature')
    
    axes[0, 2].imshow(population.data, cmap='viridis')
    axes[0, 2].set_title('Population Density')
    
    axes[1, 0].imshow(overlay.data, cmap='RdBu')
    axes[1, 0].set_title('Overlay (0.5 = neutral)')
    
    axes[1, 1].imshow(modified_terrain, cmap='terrain')
    axes[1, 1].set_title('Terrain + Overlay')
    
    # Show difference
    difference = modified_terrain - terrain.data
    axes[1, 2].imshow(difference, cmap='RdBu', vmin=-0.5, vmax=0.5)
    axes[1, 2].set_title('Difference')
    
    plt.tight_layout()
    plt.savefig('noise_visualization.png')
    print("Saved visualization to noise_visualization.png")
    plt.close()


if __name__ == "__main__":
    visualize_noise_field()
