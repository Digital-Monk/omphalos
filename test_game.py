#!/usr/bin/env python
"""Test runner for Omphalos - runs automated tests of all systems"""
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))

def test_noise_generation():
    """Test noise field generation"""
    print("\n=== Testing Noise Generation ===")
    from game.core.noise_field import NoiseField
    
    field = NoiseField(100, 100, seed=42)
    assert field.width == 100
    assert field.height == 100
    assert 0 <= field.get_value(50, 50) <= 1
    print("✓ Noise generation working")
    return True

def test_overlay_system():
    """Test overlay system"""
    print("\n=== Testing Overlay System ===")
    from game.core.overlay import Overlay
    from game.core.noise_field import NoiseField
    
    overlay = Overlay(100, 100)
    overlay.apply_effect(50, 50, radius=10, intensity=0.3)
    
    field = NoiseField(100, 100)
    combined = overlay.combine_with_field(field)
    
    assert combined.shape == (100, 100)
    print("✓ Overlay system working")
    return True

def test_energy_system():
    """Test energy system"""
    print("\n=== Testing Energy System ===")
    from game.core.energy import EnergyNode, EnergyField
    
    # Test nodes
    source = EnergyNode(capacity=100, current=80)
    sink = EnergyNode(capacity=100, current=20)
    source.connect(sink)
    
    initial_diff = source.current - sink.current
    source.flow_to(sink)
    final_diff = source.current - sink.current
    
    assert final_diff < initial_diff, "Energy should flow from high to low"
    print("✓ Energy nodes working")
    
    # Test fields
    field = EnergyField(50, 50, "heat")
    field.add_energy(25, 25, 100, radius=5)
    assert field.get_value(25, 25) > 0
    print("✓ Energy fields working")
    return True

def test_magic_systems():
    """Test magic systems"""
    print("\n=== Testing Magic Systems ===")
    from game.magic.stats import PlayerStats
    from game.magic.evocation import Evocation
    from game.magic.spells import Spell, Spellbook
    from game.magic.thaumaturgy import Thaumaturgy
    
    # Test stats
    stats = PlayerStats()
    assert stats.current_magic_reserve == 100
    print("✓ Player stats working")
    
    # Test evocation
    evocation = Evocation(stats)
    evocation.start_push("heat", 10, 10)
    assert evocation.is_pushing
    print("✓ Evocation working")
    
    # Test spells
    spell = Spell("Test", "heat", "radius", 5, 50, 10)
    spellbook = Spellbook()
    spellbook.add_spell(spell)
    assert len(spellbook.spells) == 1
    print("✓ Spells and spellbook working")
    
    # Test thaumaturgy
    thaumaturgy = Thaumaturgy(stats)
    custom_spell = thaumaturgy.design_spell("Custom", ["heat"], "radius", 3, 30)
    assert custom_spell is not None
    print("✓ Thaumaturgy working")
    return True

def test_world_system():
    """Test world and player"""
    print("\n=== Testing World System ===")
    from game.world.world import World
    from game.world.player import Player
    
    # Test world
    world = World(100, 100, seed=42)
    assert world.width == 100
    assert world.height == 100
    terrain = world.get_terrain_value(50, 50)
    assert 0 <= terrain <= 1
    biome = world.get_biome(50, 50)
    assert biome in ["mountain", "water", "desert", "tundra", "plains"]
    print(f"✓ World generation working (biome at center: {biome})")
    
    # Test player
    player = Player(50, 50)
    assert player.x == 50
    assert player.y == 50
    player.move(5, 0, world)
    assert player.x == 55
    print("✓ Player working")
    
    # Test player magic
    player.start_evocation_push("heat", 60, 60)
    assert player.evocation.is_pushing
    player.update(world, 0.016)
    print("✓ Player magic integration working")
    return True

def test_game_loop():
    """Test that game can be imported and initialized"""
    print("\n=== Testing Game Loop ===")
    
    # We can't actually run the game in headless mode, but we can test imports
    import game.main
    print("✓ Game module imports successfully")
    
    # Test that Game class exists
    assert hasattr(game.main, 'Game')
    print("✓ Game class defined")
    return True

def run_all_tests():
    """Run all tests"""
    print("=" * 60)
    print("OMPHALOS AUTOMATED TEST SUITE")
    print("=" * 60)
    
    tests = [
        test_noise_generation,
        test_overlay_system,
        test_energy_system,
        test_magic_systems,
        test_world_system,
        test_game_loop,
    ]
    
    passed = 0
    failed = 0
    
    for test in tests:
        try:
            if test():
                passed += 1
        except Exception as e:
            failed += 1
            print(f"✗ Test failed: {test.__name__}")
            print(f"  Error: {e}")
            import traceback
            traceback.print_exc()
    
    print("\n" + "=" * 60)
    print(f"RESULTS: {passed} passed, {failed} failed")
    print("=" * 60)
    
    if failed == 0:
        print("\n🎉 All tests passed! The game is ready to play.")
        print("\nTo run the game:")
        print("  python -m game.main")
        print("\nTo run examples:")
        print("  python examples/create_spells.py")
        print("  python examples/test_noise.py")
        print("  python examples/test_energy.py")
        return 0
    else:
        print(f"\n❌ {failed} test(s) failed. Please fix before running.")
        return 1

if __name__ == "__main__":
    sys.exit(run_all_tests())
