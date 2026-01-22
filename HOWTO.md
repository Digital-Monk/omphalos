# How to Run and Play Omphalos

This guide explains how to set up, run, and play the Omphalos procedural open world game.

## Installation

### Prerequisites
- Python 3.8 or higher
- pip (Python package manager)

### Setup
1. Clone the repository:
```bash
git clone https://github.com/Digital-Monk/omphalos.git
cd omphalos
```

2. Install dependencies:
```bash
pip install -r requirements.txt
```

## Running the Game

### Main Game
To launch the main game with the visual interface:
```bash
python -m game.main
```

### Example Scripts
The `examples/` directory contains demonstration scripts:

#### Test Noise Generation
Generates and visualizes procedural noise fields:
```bash
cd examples
python test_noise.py
```
This creates `noise_visualization.png` showing terrain, temperature, and population fields.

#### Test Energy System
Demonstrates energy flow and diffusion:
```bash
cd examples
python test_energy.py
```
This creates `energy_diffusion.png` showing how energy spreads over time.

#### Create Custom Spells
Design custom spells using the Thaumaturgy system:
```bash
cd examples
python create_spells.py
```
This creates `worlds/custom_spells.json` with example spell definitions.

## Game Controls

### Movement
- **WASD** or **Arrow Keys**: Move your character around the world
- **Mouse**: Position cursor for targeting spells and evocation

### Magic Systems

#### Evocation (Direct Energy Manipulation)
- **Left Mouse Button (Hold)**: Push selected energy type into the world at cursor position
- **Right Mouse Button (Hold)**: Pull selected energy type from the world at cursor position
- **1-4 Keys**: Select energy type
  - **1**: Heat
  - **2**: Cold
  - **3**: Magic
  - **4**: Electricity

#### Magic Use (Spellcasting)
- **Q**: Cast first spell (Fireball)
- **W**: Cast second spell (Ice Blast)
- **E**: Cast third spell (Magic Bolt)

Spells consume magic reserve and create energy effects at the cursor position.

### Debug & UI
- **~ (Tilde)**: Toggle debug overlay visualization
  - When ON: Shows all energy fields overlaid on terrain
  - When OFF: Shows only selected energy type
- **ESC**: Exit game

## Understanding the Game

### The World
The world is procedurally generated using Perlin noise to create:
- **Terrain**: Mountains (gray), water (blue), plains (green)
- **Temperature**: Affects biomes (desert=hot, tundra=cold)
- **Population**: Density of settlements (not visually shown in prototype)

### Energy System
Four types of energy can be manipulated:
1. **Heat** (Red/Orange): Fire, warmth, combustion
2. **Cold** (Blue): Ice, freezing effects
3. **Magic** (Purple): Raw magical energy
4. **Electricity** (Yellow): Lightning, electrical effects

Energy:
- Spreads naturally to nearby areas (diffusion)
- Decays over time
- Can be pushed/pulled using Evocation
- Can be added in bursts using spells

### Magic Reserve
- Your character has a magic reserve (shown in UI)
- All magic actions consume this reserve
- Reserve regenerates slowly over time
- If reserve is empty, you cannot cast spells or use evocation

### Player Stats
The prototype includes basic stats that affect magic:
- **Willpower**: Improves evocation efficiency
- **Wisdom**: Reduces spell costs
- **Intelligence**: Allows more complex spells
- **Dexterity**: Increases casting speed

## Tips for Playing

1. **Experiment with Evocation**: Hold left-click to continuously add heat energy and watch it spread and decay
2. **Combine Energy Types**: Try using different spells in the same area to see effects
3. **Watch Your Magic**: Don't spam spells - you need time to regenerate
4. **Use Debug Mode**: Press ~ to see all energy fields at once
5. **Explore Different Biomes**: Move around to see mountains, water, deserts, and tundra

## Technical Details

### Project Structure
```
omphalos/
├── game/
│   ├── core/          # Core systems (noise, overlays, energy)
│   ├── magic/         # Magic systems (evocation, spells, thaumaturgy)
│   ├── world/         # World and player management
│   └── main.py        # Main game loop
├── examples/          # Example scripts
├── worlds/            # Saved world data
└── requirements.txt   # Python dependencies
```

### Key Concepts

#### Noise Fields
- Base properties generated with Perlin noise
- Each property (terrain, temp, population) is a separate field
- Values range from 0.0 to 1.0

#### Overlays
- Modifications applied on top of noise fields
- 0.5 = neutral (no change)
- >0.5 = positive deviation
- <0.5 = negative deviation
- Decay over time unless maintained

#### Energy Fields
- Spatial distribution of energy types
- Support diffusion (spreading)
- Support decay (dissipation)
- Can be manipulated by player actions

## Extending the Game

Want to add more features? Check out these files:

- **Add new spells**: Edit `game/magic/spells.py` or use `examples/create_spells.py`
- **Modify energy types**: Edit `game/world/world.py` to add new energy fields
- **Change world generation**: Edit `game/core/noise_field.py` to adjust noise parameters
- **Add new biomes**: Edit `game/world/world.py` `get_biome()` method

## Troubleshooting

### Import Errors
If you get module import errors, make sure you're running from the repository root:
```bash
cd /path/to/omphalos
python -m game.main
```

### Display Issues
If the game window doesn't appear or crashes, ensure Pygame is installed:
```bash
pip install pygame --upgrade
```

### Performance Issues
If the game runs slowly:
- Try reducing the world size in `game/main.py` (line 23: `World(width=200, height=200)`)
- Reduce the zoom level (line 25: `self.zoom = 4`)
- Turn off debug mode (press ~)

## Next Steps

This prototype implements the core concepts from the README:
- ✅ Procedural noise generation
- ✅ Overlay system for world modification
- ✅ Energy system with capacity and flow
- ✅ Evocation (push/pull mechanics)
- ✅ Magic Use (spellcasting)
- ✅ Thaumaturgy (spell design)
- ✅ Player stats and magic reserve

Future enhancements could include:
- More complex spell effects (lines, cones, etc.)
- Persistent world saves
- NPC interactions
- Advanced enchanting system
- Particle effects and better graphics
- Sound effects and music
- Multiplayer support

Enjoy exploring your procedurally generated world!
