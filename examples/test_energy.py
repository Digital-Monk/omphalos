"""Example: Test energy system"""
from game.core.energy import EnergyNode, EnergyField
import matplotlib.pyplot as plt


def test_energy_nodes():
    """Test energy node connections and flow"""
    print("Testing energy nodes...\n")
    
    # Create some energy nodes
    source = EnergyNode(capacity=100, current=80, flow_rate=1.0)
    sink = EnergyNode(capacity=100, current=20, flow_rate=1.0)
    
    print(f"Initial - Source: {source.current}, Sink: {sink.current}")
    
    # Connect nodes
    source.connect(sink)
    
    # Simulate energy flow over time
    for i in range(10):
        transferred = source.flow_to(sink)
        print(f"Step {i+1} - Source: {source.current:.2f}, Sink: {sink.current:.2f}, Transfer: {transferred:.2f}")
        
        if abs(source.current - sink.current) < 0.1:
            print("Equilibrium reached!")
            break


def test_energy_field():
    """Test energy field with diffusion"""
    print("\nTesting energy field...\n")
    
    # Create energy field
    field = EnergyField(50, 50, "heat", decay_rate=0.02)
    
    # Add energy at center
    field.add_energy(25, 25, 100, radius=5)
    
    # Simulate over time
    snapshots = []
    for i in range(20):
        snapshots.append(field.data.copy())
        field.update()
        total_energy = field.data.sum()
        print(f"Step {i+1} - Total energy: {total_energy:.2f}")
    
    # Visualize
    fig, axes = plt.subplots(2, 3, figsize=(15, 10))
    timesteps = [0, 4, 9, 14, 19]
    
    for idx, t in enumerate(timesteps):
        row = idx // 3
        col = idx % 3
        if idx < len(timesteps):
            axes[row, col].imshow(snapshots[t], cmap='hot', vmin=0, vmax=100)
            axes[row, col].set_title(f'Step {t+1}')
    
    # Hide unused subplot
    axes[1, 2].axis('off')
    
    plt.tight_layout()
    plt.savefig('energy_diffusion.png')
    print("\nSaved energy diffusion visualization to energy_diffusion.png")
    plt.close()


if __name__ == "__main__":
    test_energy_nodes()
    test_energy_field()
