# How to Run and Play Omphalos

This guide explains how to set up, run, and play the Omphalos procedural open world game.

## Installation

### Prerequisites
- Python 3.8 or higher
- pip (Python package manager)

### Setup
1. Clone the repository:
```bash
git clone <repository-url>
cd omphalos
```

2. Install dependencies:
```bash
pip install -r requirements.txt
```

## Running the Game

### Godot Client + C++ Server (TCP)
The current end-to-end path is:
- Godot runs the client + renderer.
- A C++ server streams terrain chunks over **TCP** using a lock-step “WANT batch → CHUNK frames → BATCH_END” protocol.

From the repo root, the simplest way to run it is:
```bash
./rungame.sh
```

This script:
- Configures/builds the C++ server in `server/build/`.
- Launches the TCP server on port `7778`.
- Launches Godot with `OMPH_TCP=1` so the client uses TCP.

### Python Headless Prototype (No Renderer)
To exercise the headless Python `Game` class (logic only; Godot consumes state separately):
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
- **W/S**: Move forward/backward
- **A/D**: Strafe left/right
- **E**: Jump (also treated as "up" while flying)
- **R**: Fly up
- **F**: Fly down
- **SHIFT**: Sprint (3x)
- **CTRL**: Hyper-sprint (100x)
- **Mouse X**: Yaw (turn character)
- **Mouse Y**: Pitch camera (mouse forward pitches up, mouse back pitches down)
- **ESC**: Release mouse capture
- **TAB**: Re-capture mouse

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

Note: The game is currently in a state where the core logic has been implemented, but rendering will be done through Godot. The above command will initialize the game logic but won't display a window.

### Future Integration
The game is being transitioned to Godot for rendering. The core Python logic can be integrated with Godot through:
- GDScript calling Python modules
- Or rewriting the rendering layer in Godot while keeping the game logic structure

### TCP Lock-Step Protocol (Godot <-> C++ Server)
Terrain streaming uses compact framed binary messages over **TCP**.

Packet framing (little-endian):
- `u32 magic` = `0x4F4D5048` (`OMPH`)
- `u8 version` = `1`
- `u8 type`
- `u32 seq`
- `u32 payload_len`
- `payload_len` bytes payload

Message types:
- `1` = `HELLO` (client -> server, empty payload)
- `5` = `CHUNK` (server -> client)
- `6` = `WANT` (client -> server: request a batch of chunks)
- `7` = `INFO` (server -> client: server capabilities + terrain config)
- `8` = `BATCH_END` (server -> client: marks completion of the batch for a given request seq)

`INFO` payload:
- `u32 batch_n` (server-advertised batch size; typically worker thread count)
- `f32 chunk_size`
- `i32 chunk_resolution`
- `i32 view_distance_chunks`
- `f32 height_amplitude`

`WANT` payload (single fragment in TCP mode):
- `u32 gen`
- `u8 part` (always `0`)
- `u8 total_parts` (always `1`)
- `i32 pcx, pcz` (center chunk coords)
- `u32 count`
- `count` × (`i16 dx`, `i16 dz`) signed offsets from `(pcx,pcz)`

`BATCH_END` payload:
- `u32 count` (chunks sent in this batch)

`CHUNK` payload:
- `i32 cx, cz`
- `f32 chunk_size`
- `i32 chunk_resolution`
- `f32 height_amplitude`
- `f32 height_scale`
- `f32 sea00, sea10, sea01, sea11` (sea level sampled at the four chunk corners)
- `u32 height_count`
- `i16[height_count] quantized_heights`

Height decode:
- `height = quantized_height * height_scale`
- Current server quantization is `q16` scaled by terrain amplitude.

Note:
- Sea level is currently fixed at `y = 0.0` everywhere and the Godot client renders a single global water plane.
- The old sea-level noise has been repurposed into a low-frequency **bedrock** field; terrain height is derived from bedrock + log-compressed elevation.

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
