"""Example: Create and save custom spells using Thaumaturgy"""
from game.magic.stats import PlayerStats
from game.magic.spells import Spellbook
from game.magic.thaumaturgy import Thaumaturgy


def main():
    """Create example spells"""
    # Create player stats
    stats = PlayerStats()
    stats.intelligence = 20  # Higher intelligence for complex spells
    stats.wisdom = 15
    
    # Create thaumaturgy system
    thaumaturgy = Thaumaturgy(stats)
    
    # Create a spellbook
    spellbook = Spellbook()
    
    # Design some custom spells
    print("Designing custom spells...\n")
    
    # Lightning bolt - electricity
    lightning = thaumaturgy.design_spell(
        name="Lightning Bolt",
        energy_types=["electricity"],
        effect_type="radius",
        radius=3,
        power=60
    )
    if lightning:
        print(f"Created: {lightning.name}")
        print(f"  Energy: {lightning.energy_type}")
        print(f"  Radius: {lightning.radius}")
        print(f"  Power: {lightning.power}")
        print(f"  Cost: {lightning.cost}")
        thaumaturgy.add_to_spellbook(lightning, spellbook)
        print()
    
    # Inferno - heat magic
    inferno = thaumaturgy.design_spell(
        name="Inferno",
        energy_types=["heat", "magic"],
        effect_type="radius",
        radius=8,
        power=100
    )
    if inferno:
        print(f"Created: {inferno.name}")
        print(f"  Energy: {inferno.energy_type}")
        print(f"  Radius: {inferno.radius}")
        print(f"  Power: {inferno.power}")
        print(f"  Cost: {inferno.cost}")
        thaumaturgy.add_to_spellbook(inferno, spellbook)
        print()
    
    # Ice wall - cold
    ice_wall = thaumaturgy.design_spell(
        name="Ice Wall",
        energy_types=["cold"],
        effect_type="radius",
        radius=5,
        power=80
    )
    if ice_wall:
        print(f"Created: {ice_wall.name}")
        print(f"  Energy: {ice_wall.energy_type}")
        print(f"  Radius: {ice_wall.radius}")
        print(f"  Power: {ice_wall.power}")
        print(f"  Cost: {ice_wall.cost}")
        thaumaturgy.add_to_spellbook(ice_wall, spellbook)
        print()
    
    # Save spellbook
    spellbook.save_to_file("worlds/custom_spells.json")
    print(f"Saved {len(spellbook.spells)} spells to worlds/custom_spells.json")


if __name__ == "__main__":
    main()
