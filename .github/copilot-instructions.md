# Copilot instructions for Omphalos

## Mission
- Omphalos is a headless Python prototype of a procedurally generated open world where energy overlays and magic systems drive every interaction. Keep the focus on how noise fields, overlays, and energy types flow through each other rather than designing a full renderer; rendering is handled by Godot via `game.main`.
- Surface the reasons behind decisions in `game/main.py` and `game/world/*`: the project is split into core systems (noise, overlay, energy), a magic stack (evocation, spells, thaumaturgy, stats), and a slim player/world orchestrator that keeps Godot in sync.

## Architecture highlights
- `game/world/world.py` stitches the noise fields (terrain, population, temperature), energy_fields dict (heat, cold, magic, electricity), and the overlay queue; `World.update` drives energy decay, overlay fading, and pruning of inactive overlays while `get_biome` simply thresholds terrain and temperature.
- `game/core/energy.py` contains EnergyNode (capacity + flow gradients) and EnergyField (numpy grids, radius-based add/remove, simple diffusion by averaging neighbors, global decay). All player effects hit one of these fields.
- `game/core/overlay.py` keeps overlay data centered at 0.5 (neutral). `apply_effect` blends intensities in [-0.5, +0.5] with distance falloff, and `combine_with_field` multiplies noise_field.data by 2x factors before clipping—expect overlays to deactivate once they decay close to neutral.
- `game/magic/*` models stat-tuned magic: PlayerStats drives cost multipliers and complexity caps, Evocation pushes/pulls energy (surge doubles rate & cost), Spellbook/Scroll handle reusable vs one-shot casts, and Thaumaturgy composes spells limited by intelligence and charges additional magic to design scrolls/enchantments.

## Key workflows
- Always install the Python deps with `pip install -r requirements.txt` (numpy, noise, matplotlib) before running anything; matplotlib is only required for example visuals.
- Tests: run `python test_game.py` for the automated coverage suite, `python integration_test.py` for the demo script that prints every subsystem, and `python -m game.main` to exercise the headless Game class before handing state to Godot.
- Examples live under `examples/` and mutate sys.path to reach the root; run them from the repo root (or with `cd examples` and `python test_noise.py` etc.). They output PNGs (`noise_visualization.png`, `energy_diffusion.png`, `omphalos_game_demo.png`, `omphalos_magic_demo.png`) and demonstrate how overlays/energy/spells work without a renderer.
- Custom spells persist via Spellbook.save_to_file; example scripts write to `worlds/custom_spells.json`, so ensure the `worlds/` directory exists when touching persistence.
- `create_demo_images.py` is the canonical visualization script: it instantiates World + Player, simulates some evocation/spell effects, and saves `omphalos_game_demo.png` plus `omphalos_magic_demo.png`. Keep its matplotlib usage limited to main so headless imports stay light.

## Project conventions
- Overlay values always orbit 0.5; intensities are additive falloffs, and `combine_with_field` multiplies the underlying field, so additive tweaks should stay subtle to avoid clipping.
- EnergyFields operate on numpy arrays via loops that expect every interior cell to be updated each frame; avoid replacing `self.data` unless rebuilding the world because updates rely on persistent numpy buffers.
- Player movement and energy interactions are bounded by `world.width`/`height`; `Player.move` short-circuits movement that would escape the grid.
- Magic costs always go through PlayerStats.use_magic, which multiplies the cost by `get_spell_cost_multiplier`. When adding new spells or scroll creation, double-check whether the action should drain `current_magic_reserve` up-front or over time.
- `Spell.effect_type` currently supports "radius" and "drain"; extensions need to update `Spell.cast` along with any UI that lists effect type names.

## Files to consult when touching each concern
- Core systems: `game/core/noise_field.py`, `game/core/overlay.py`, `game/core/energy.py`.
- Magic: `game/magic/spells.py`, `game/magic/evocation.py`, `game/magic/thaumaturgy.py`, `game/magic/stats.py`.
- World & player orchestration: `game/world/world.py`, `game/world/player.py`, and the headless driver in `game/main.py` (Godot hooks here).
- Workflow docs: HOWTO.md explains controls/commands; IMPLEMENTATION.md recaps completed features; README.md describes the narrative mission.
- Visual demos: `create_demo_images.py` plus everything under `examples/` so you can point Copilot toward the intended output artifacts.

## Communication guidance for Copilot tasks
- When asked to modify gameplay or magic logic, describe how data flows from `Player` → `Evocation`/`Spellbook` → `World.energy_fields` → overlays/noise, citing the relevant files above.
- For UI or visualization requests, remind the user that the Python code is headless and is meant to be consumed by Godot; reference `game/main.py` and the example scripts when suggesting new debug views.
- Mention the presence of integration_test.py whenever you suggest verifying multiple subsystems, since it prints the key commands and outcomes for each system.
- Point the user to HOWTO.md/IMPLEMENTATION.md when they need controls or rationale for a subsystem; they are kept up to date with the play/testing workflow.

## Terrain streaming — ABSOLUTE RULES (do NOT violate)
The Godot client (`main.gd`) and C++ server (`server/src/tcp_server.cpp`) use a strict **request→response→build** cycle over TCP. The following rules are hard-won lessons from multiple failed attempts at "optimization" that actually destroyed performance:

### NEVER queue or pipeline terrain chunks
- The system is **strictly synchronous**: request N chunks → receive N chunks → build all N → repeat.
- There must be **zero queued/pending chunks** between cycles. `_pending_chunks` must be empty before the next batch response arrives.
- **1 batch in flight. Always.** Never increase `_tcp_max_batches_in_flight` above 1.
- Never add "backlog detection", "throttling", or "drain budgets" — these are symptoms of queueing, and queueing is the bug.
- Never cap the number of chunks built per frame below what was requested. `_drain_chunk_queue` builds ALL pending chunks, then clears. No FIFO, no partial drain, no "save some for next frame."
- `target_n` (chunks requested) must always be ≤ `_max_mesh_builds_per_frame` so that every response can be fully built in one frame.

### Want list construction
- The want list is rebuilt from scratch every request. No cursor, no resumption from a previous position.
- Step 1: check the 3×3 grid around the player. Missing chunks go first (full circle, no FOV filter).
- Step 2: sweep the distance-sorted offset table outward, FOV-filtered (±60° of facing). Append missing chunks until the list reaches `target_n`.
- The result is naturally priority-sorted (nearest first) because the offset table is distance-sorted. **No scoring. No sorting.**
- If the player moves, the next request instantly reflects the new position. There is no stale work.

### Why no queues — the lesson
Queues cause chunks requested from position A to be built at position B, producing "fill from the edge inward" artifacts. Pipelining (>1 batch in flight) means old batches' chunks sit in a FIFO behind new near chunks. The FIFO then drains old-far before new-near, making the terrain appear to fill inward from the horizon. The fix is not "smarter queue management" — it is **no queue at all**.
