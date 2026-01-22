# **Procedural Open World: Omphalos**
*A dynamic, player-driven world where actions shape history, energy flows like rivers, and magic is the art of bending the world to your will.*

## **🌍 Overview**
This project implements a **procedurally generated open world** with a **reactive energy system**, **spatial-time branching overlays**, and a **player-driven magic simulation** that modifies the world in real-time. Players interact with the world by shaping **structured noise fields** (terrain, population, energy) and overlaying their actions onto the world like **bump maps**.

At its core, the world is a **computationally generated canvas** where:
- **Base properties** (terrain, population, resources) are generated via **structured noise**.
- **Player actions** create **modifiable overlays** that alter these properties dynamically.
- **Magic systems** (Evocation, Magic Use, Thaumaturgy) manipulate **energy fields**, which in turn modify the world.

---

## **🎮 Core Gameplay Pillars**
### **1. Procedural Generation with Structured Noise**
- **Base World**: Terrain, population, and resources are generated using **Perlin/Simplex noise** to create coherent, replayable worlds.
- **Noise Fields**: Each property (e.g., elevation, temperature, population density) is a separate noise field, allowing for granular control.
- **Example**: A "population density" field might have peaks in valley areas and sparse populations in mountains.

### **2. Overlay System: Bump Maps for World Modification**
- **Player Actions** modify the world by **overlaying** changes onto noise fields.
  - **Format**: Grayscale images (or arrays) where:
    - 50% gray = neutral (no change).
    - >50% = positive deviation (e.g., +20% population).
    - <50% = negative deviation (e.g., -30% population).
  - **Decay**: Overlays fade over time unless maintained (e.g., by magic).
  - **Stacking**: Multiple overlays can combine (e.g., fire + water → steam explosion).
- **Visualization**: Players **only see the result** (e.g., more people, hotter terrain), not the underlying fields.

### **3. Energy as a World Mechanic**
- **Energy Types**: Heat, cold, electricity, magic, etc., are **separate noise fields** that can be manipulated.
  - **Evocation**: Directly push/pull energy between objects.
  - **Spells**: Apply predefined energy overlays (e.g., "Fireball" increases heat energy in a radius).
- **Dynamics**:
  - **Capacity**: Objects/areas have min/max energy storage.
  - **Flow**: Energy moves passively/actively between connected objects.
  - **Decay**: Energy dissipates over time (e.g., heat cools, magic fades).

### **4. Magic Systems**
#### **A. Evocation**
- **Push/Pull Mechanics**:
  - Select an energy type (e.g., heat) and **push** it into a target or **pull** it from a target into yourself.
  - **Magic Reserve**: Your Willpower/Charisma determines how long/sustained you can push/pull.
  - **Surges**: Hold + button to surge (drains reserves). Risky to adjust mid-combat!
- **Stats**: Willpower (or Charisma) improves efficiency and surge power.

#### **B. Magic Use**
- **Scrolls**: Single-use spells that consume your magic reserve when cast.
- **Spellbook**: Hang spells here to cast later. Costs magic on use.
- **Stats**: Wisdom reduces spell costs and unlocks more complex spells.

#### **C. Thaumaturgy**
- **Design Spells**: Combine energy types to create custom effects (e.g., "Lightning Bolt" = electricity + sound).
- **Outputs**:
  - **Scrolls**: Embed magic into a scroll (drained when cast).
  - **Spellbook Pages**: No magic cost; others pay the original cost.
  - **Enchanted Objects**: Spells baked into items (e.g., a sword that siphons heat on impact).
- **Stats**: Intelligence allows more effects in spells and reduces design costs.

#### **D. Common: Dexterity**
- **Evocation**: Faster push/pull response.
- **Magic Use**: Faster spell casting.
- **Thaumaturgy**: Finer control over spell design.

---

## **🏗️ Technical Architecture**
### **1. Engine & Tools**
- **Base Engine**: Godot 4.x (or Unity/Unreal with custom plugins for noise/overlay systems).
- **Procedural Generation**:
  - OpenSimplex2 for noise.
  - Custom shaders for overlay blending (e.g., combining noise + player overlays).
- **Physics**: Custom energy flow simulation (e.g., heat spreading via diffusion algorithms).
- **Save System**: Serializes noise seeds + overlays for replayability.

### **2. Data Structures**
| **Concept**          | **Implementation**                          | **Example**                          |
|----------------------|---------------------------------------------|--------------------------------------|
| Noise Field          | 2D/3D array of floats                       | `population_field[x][y] = 0.7`       |
| Overlay              | Grayscale image or delta array              | `heat_overlay[x][y] = 0.8`           |
| Energy Node          | Object with capacity, flow, current energy  | `fire_pit = {capacity: 100, current: 30}` |
| Spell                | JSON-like structure                         | `{name: "Fireball", energy: "heat", effect: "radius(3)"}` |

### **3. Workflow**
1. **Generation**:
   - Player enters the world → noise fields generate chunks as needed.
   - Overlays load from save files (or are empty if new world).
2. **Interaction**:
   - Player casts a spell → creates an energy overlay.
   - Overlay modifies the noise field → world reacts (e.g., fire melts ice).
3. **Persistence**:
   - Overlays decay or are saved with world snapshots.

---

## **🎨 Art & Design**
### **Visual Style**
- **Procedural Aesthetics**: Noise fields should look "handcrafted" despite being generated (e.g., jagged mountains, organic settlements).
- **Overlay Effects**:
  - Heat: Glowing embers, steam.
  - Cold: Frost patterns, ice shards.
  - Magic: Glowing runes, floating particles.
- **UI**:
  - Debug tools for designers (e.g., overlay heatmaps).
  - Player-facing tools are abstract (e.g., a "magic gauge" for Evocation).

### **Sound Design**
- **Ambient**: Energy fields have subtle sounds (e.g., crackling heat, humming magic).
- **Dynamic**: World reactions trigger sound (e.g., ice cracking when melted).

---

## **📦 Project Structure**
```
project_root/
├── assets/
│   ├── noise_shaders/          # Overlay blending shaders
│   ├── sprites/                # UI and world sprites
│   └── sounds/                 # Ambient and dynamic sounds
├── scripts/
│   ├── core/                   # Noise generation, overlay system
│   ├── magic/                  # Evocation, Magic Use, Thaumaturgy
│   └── world/                  # Chunk loading, energy simulation
├── tools/
│   ├── noise_editor/           # Design noise fields visually
│   └── overlay_inspector/      # Debug overlays
├── worlds/                     # Saved world seeds + overlays
└── README.md                   # You are here!
```

---

## **🚀 Development Roadmap**
| **Phase**        | **Goal**                                  | **Tools**                          |
|------------------|-------------------------------------------|------------------------------------|
| **Prototype**    | Basic noise + overlay system              | Godot, Python for testing          |
| **Core Systems** | Magic, energy flow, world reactivity      | C#/GDScript                        |
| **Content**      | Spells, biomes, overlay effects           | Blender, Audacity                  |
| **Polish**       | UI/UX, optimization, bug fixing           | Profiler, QA tools                 |

---

## **📜 License**
This project is licensed under **[MIT](LICENSE)** (or [your preferred license]). Contributions welcome!

---

## **🙌 Acknowledgments**
- Inspired by *Elder Scrolls games*, *Dwarf Fortress*, *Caves of Qud*, and *No Man's Sky*.
- Uses [OpenSimplex2](https://github.com/KdotJPG/OpenSimplex2) for noise.
- Built with ❤️ and caffeine by Mac Reiter.

---

## **🎲 How to Play**
1. Clone the repo: `git clone https://github.com/your/repo.git`.
2. Install dependencies (see `requirements.txt` or `project.godot`).
3. Run the game:
   - Godot: Open `project.godot` and press F5.
   - Command line: `python -m game.main`.
4. Explore, cast spells, and reshape the world!

**Controls**:
- **Evocation**: `Left Mouse` (push), `Right Mouse` (pull).
- **Magic Use**: `Q` to open spellbook.
- **Thaumaturgy**: `E` to design spells (requires a workbench).
- **Debug**: `~` to toggle overlay heatmaps.

