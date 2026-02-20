extends Node3D

const NET_MAGIC: int = 0x4F4D5048 # 'OMPH'
const NET_VERSION: int = 1
const MSG_HELLO: int = 1
const MSG_CHUNK: int = 5
const MSG_WANT: int = 6   # client → server: demand list
const MSG_INFO: int = 7   # server → client: batch/terrain config
const MSG_BATCH_END: int = 8
const MSG_SET_LAYER_MODE: int = 9
const LAYER_MODE_NAMES: Array[String] = [
	"Full", "No Detail", "No Plateau", "No Elev.Scale", "Bedrock Only"
]

@export var server_host: String = "127.0.0.1"
@export var server_tcp_port: int = 7778

@export var player_scale: float = 1.0
@export var turn_speed: float = 2.5

@export var camera_distance: float = 8.0
@export var camera_height: float = 5.5
@export var camera_look_ahead: float = 2.0
@export var camera_shoulder_offset: float = 1.2
@export var view_distance_chunks: int = 15
@export var camera_yaw_speed: float = 6.0
@export var mouse_sensitivity: float = 0.0035
@export var mouse_pitch_sensitivity: float = 0.0035
@export var min_camera_pitch: float = -PI * 0.5 + 0.001
@export var max_camera_pitch: float = PI * 0.5 - 0.001

var _tcp := StreamPeerTCP.new()
var _tcp_rx: PackedByteArray = PackedByteArray()
var _tcp_seq: int = 0
var _tcp_batch_n: int = 0
var _tcp_waiting_batch: int = 0
var _tcp_max_batches_in_flight: int = 1
var _tcp_connected: bool = false
var _tcp_hello_sent: bool = false
var _tcp_reconnect_timer: float = 0.0
var _tcp_reconnect_interval: float = 1.0

var _player_node: Node3D
var _camera: Camera3D
var _player_label: Label3D
# Human figure pivot nodes (built by _build_human_figure)
var _figure_root: Node3D     # body-lean pivot, at y=3.0 in player_node space
var _l_hip_pivot: Node3D
var _r_hip_pivot: Node3D
var _l_knee_pivot: Node3D
var _r_knee_pivot: Node3D
var _l_shoulder_pivot: Node3D
var _r_shoulder_pivot: Node3D
var _l_elbow_pivot: Node3D
var _r_elbow_pivot: Node3D
# Animation
var _anim_phase: float = 0.0
# Terrain physics
var _vertical_velocity: float = 0.0   # ft/s (positive = up)
var _is_grounded: bool = false
const GRAVITY_ACCEL: float = 32.0     # ft/s²
const TERRAIN_SNAP_DIST: float = 2.5  # ft: (unused) legacy snap distance
# CPU-side heights for terrain sampling (Vector2i(cx,cz) → PackedFloat32Array)
var _terrain_heights: Dictionary = {}
var _facing_angle := 0.0
var _chunks: Dictionary = {}
# Chunks whose height data has arrived but whose mesh hasn't been built yet.
# We drain at most _max_mesh_builds_per_frame per _process() to avoid
# holding the main thread for a spike when dozens of packets arrive at once.
var _pending_chunks: Array = []
# Raw chunk payloads received from TCP. We decode a limited number per frame
# to avoid spikes when a batch arrives.
var _pending_chunk_packets: Array = []
var _max_chunk_decodes_per_frame: int = 48
var _max_mesh_builds_per_frame: int = 48
# All chunks whose data has arrived from the server (superset of _chunks).
# Used by the want list so we never re-request data we already have.
var _received_chunks: Dictionary = {}
# GPU-side terrain: one shared flat grid mesh + per-chunk heightmap texture + shader.
var _terrain_shader: Shader
# LOD mesh pools — 5 resolution tiers.  The vertex shader samples the heightmap
# via UV * chunk_resolution → texelFetch, so meshes at any resolution produce
# correct heights automatically.  Index 0 = full res, 4 = coarsest.
var _lod_meshes: Array = []          # Array[ArrayMesh]
var _lod_meshes_chunk_size: float = -1.0
# Distance thresholds (chunk-size multiples) for each LOD transition.
# LOD 0 when dist < 5×, LOD 1 < 20×, LOD 2 < 60×, LOD 3 < 120×, LOD 4 beyond.
const LOD_DIST_MULTS: Array[float] = [5.0, 20.0, 60.0, 120.0]
var _lod_last_update_pos: Vector3 = Vector3(INF, INF, INF)
var _want_outstanding: int = 0   # cached count of unreceived visible chunks
var _want_cursor: int = 0
var _want_offsets_r: int = -1
var _want_offsets: PackedInt32Array = PackedInt32Array() # packed (dx_u16<<16 | dz_u16), sorted by dist asc
# ── Mega-chunks: larger tiles at distance to reduce draw-call count ──────────
const MEGA_CHUNK_SCALE: int = 8          # 8 × 128 ft = 1024 ft per mega-chunk
const GIGA_CHUNK_SCALE: int = 64         # 64 × 128 ft = 8192 ft per giga-chunk
@export var view_distance_mega_chunks: int = 15  # 15 × 1024 = 15,360 ft
@export var view_distance_giga_chunks: int = 5   # 5 × 8192 = 40,960 ft
var _mega_chunk_size: float = 1024.0     # recomputed when INFO arrives
var _mega_chunks: Dictionary = {}        # Vector2i(mcx,mcz) → MeshInstance3D
var _received_mega_chunks: Dictionary = {}
var _terrain_mega_heights: Dictionary = {}  # Vector2i → PackedFloat32Array
var _pending_mega_chunks: Array = []
var _mega_lod_meshes: Array = []         # coarse LOD meshes at mega scale
var _mega_lod_meshes_size: float = -1.0
var _mega_want_offsets_r: int = -1
var _mega_want_offsets: PackedInt32Array = PackedInt32Array()
# ── Giga-chunks: even larger tiles at far distance ──────────────────────────
var _giga_chunk_size: float = 8192.0     # recomputed when INFO arrives
var _giga_chunks: Dictionary = {}        # Vector2i(gcx,gcz) → MeshInstance3D
var _received_giga_chunks: Dictionary = {}
var _terrain_giga_heights: Dictionary = {}
var _pending_giga_chunks: Array = []
var _giga_lod_meshes: Array = []
var _giga_lod_meshes_size: float = -1.0
var _giga_want_offsets_r: int = -1
var _giga_want_offsets: PackedInt32Array = PackedInt32Array()
# Pending-removal tracking: coarse chunks marked for removal once finer chunks cover them.
var _mega_pending_removal: Dictionary = {}   # Vector2i → true
var _giga_pending_removal: Dictionary = {}   # Vector2i → true
var _game_time: float = 0.0             # seconds since start (for tide/waves)
var _water_plane: MeshInstance3D
var _sun_light: DirectionalLight3D
var _world_env_node: WorldEnvironment
var _world_env: Environment
var _sky_material: ProceduralSkyMaterial
var _sky: Sky
var _is_underwater: bool = false
var _chunk_size := 32.0
var _chunk_resolution := 32
var _chunk_height_amplitude := 8.0
var _terrain_layer_mode: int = 0
var _hud_layer: CanvasLayer
var _hud_label: Label
var _packet_count := 0
var _send_count := 0
var _last_send_time_ms := 0
var _has_server := false
var _prev_player_pos: Vector3 = Vector3(INF, INF, INF)
var _camera_move_epsilon: float = 0.001
var _prev_facing_angle: float = INF
var _pending_mouse_yaw: float = 0.0
var _camera_pitch: float = 0.25
var _prev_camera_pitch: float = INF

func _ready() -> void:
	_setup_scene()
	# Start with visible mouse; capture on first click for reliability.
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_connect_tcp()
	_hud_label.text = "Click left mouse to capture input"

func _process(delta: float) -> void:
	_apply_local_input(delta)
	_poll_tcp(delta)
	if _tcp_connected and not _tcp_hello_sent:
		_tcp_send_control(MSG_HELLO)
		_tcp_hello_sent = true
	_drain_chunk_packets()
	_drain_chunk_queue()
	_prune_chunks()
	_update_chunk_lods()
	_update_water_level(delta)
	_apply_terrain_physics(delta)
	_maybe_send_want_batch_tcp()
	_update_camera()
	_update_underwater_lighting()
	_update_hud()

func _connect_tcp() -> void:
	_tcp = StreamPeerTCP.new()
	_tcp_connected = false
	_tcp_rx = PackedByteArray()
	_tcp_seq = 0
	_tcp_batch_n = 0
	_tcp_waiting_batch = 0
	_has_server = false
	_tcp_reconnect_timer = 0.0
	_tcp_hello_sent = false
	var err := _tcp.connect_to_host(server_host, server_tcp_port)
	if err != OK:
		push_warning("TCP connect failed: " + str(err))

func _tcp_send_packet(msg_type: int, seq: int, payload: PackedByteArray) -> void:
	var spb := StreamPeerBuffer.new()
	spb.big_endian = false
	spb.put_u32(NET_MAGIC)
	spb.put_u8(NET_VERSION)
	spb.put_u8(msg_type)
	spb.put_u32(seq)
	spb.put_u32(payload.size())
	if payload.size() > 0:
		spb.put_data(payload)
	var err := _tcp.put_data(spb.data_array)
	if err == OK:
		_send_count += 1
		_last_send_time_ms = Time.get_ticks_msec()

func _tcp_send_control(msg_type: int) -> void:
	_tcp_seq += 1
	_tcp_send_packet(msg_type, _tcp_seq, PackedByteArray())

func _read_le_u32(bytes: PackedByteArray, offset: int) -> int:
	if offset + 4 > bytes.size():
		return 0
	return (int(bytes[offset])
		| (int(bytes[offset + 1]) << 8)
		| (int(bytes[offset + 2]) << 16)
		| (int(bytes[offset + 3]) << 24))

func _read_le_i32(bytes: PackedByteArray, offset: int) -> int:
	if offset + 4 > bytes.size():
		return 0
	var v: int = (int(bytes[offset])
		| (int(bytes[offset + 1]) << 8)
		| (int(bytes[offset + 2]) << 16)
		| (int(bytes[offset + 3]) << 24))
	# Sign-extend to 32-bit.
	if v & 0x80000000:
		v -= 0x100000000
	return v

func _poll_tcp(delta: float) -> void:
	# Godot requires polling StreamPeerTCP regularly to update status/buffers.
	_tcp.poll()
	var st := _tcp.get_status()
	if st == StreamPeerTCP.STATUS_CONNECTED:
		_tcp_connected = true
		_tcp_reconnect_timer = 0.0
	elif st == StreamPeerTCP.STATUS_CONNECTING:
		return
	else:
		_tcp_connected = false
		_has_server = false
		_tcp_waiting_batch = 0
		_tcp_reconnect_timer += delta
		if _tcp_reconnect_timer >= _tcp_reconnect_interval:
			_tcp_reconnect_timer = 0.0
			_connect_tcp()
		return

	var avail := _tcp.get_available_bytes()
	if avail > 0:
		var res := _tcp.get_data(avail)
		if int(res[0]) != OK:
			return
		var data: PackedByteArray = res[1] as PackedByteArray
		_tcp_rx.append_array(data)

	# Parse as many complete frames as possible.
	while _tcp_rx.size() >= 14:
		var magic := _read_le_u32(_tcp_rx, 0)
		if magic != NET_MAGIC:
			_tcp_rx = PackedByteArray()
			return
		var version := int(_tcp_rx[4])
		if version != NET_VERSION:
			_tcp_rx = PackedByteArray()
			return
		var msg_type := int(_tcp_rx[5])
		var seq := _read_le_u32(_tcp_rx, 6)
		var payload_len := _read_le_u32(_tcp_rx, 10)
		var frame_len := 14 + payload_len
		if _tcp_rx.size() < frame_len:
			break
		var payload := PackedByteArray()
		if payload_len > 0:
			payload = _tcp_rx.slice(14, frame_len)

		# Consume frame.
		_tcp_rx = _tcp_rx.slice(frame_len, _tcp_rx.size())

		if msg_type == int(MSG_CHUNK):
			# Keep receive cheap: mark received immediately, defer heavy decode.
			if payload.size() >= 12:
				var cx := _read_le_i32(payload, 0)
				var cz := _read_le_i32(payload, 4)
				var cs := payload.decode_float(8)
				var key := Vector2i(cx, cz)
				if cs > _mega_chunk_size * 1.5:
					_received_giga_chunks[key] = true
				elif cs > _chunk_size * 1.5:
					_received_mega_chunks[key] = true
				else:
					_received_chunks[key] = true
			_pending_chunk_packets.push_back(payload)
		elif msg_type == MSG_INFO:
			var spb := StreamPeerBuffer.new()
			spb.big_endian = false
			spb.data_array = payload
			spb.seek(0)
			if payload.size() >= 20:
				_tcp_batch_n = int(spb.get_u32())
				_chunk_size = float(spb.get_float())
				_chunk_resolution = int(spb.get_32())
				view_distance_chunks = int(spb.get_32())
				_chunk_height_amplitude = float(spb.get_float())
				_mega_chunk_size = _chunk_size * float(MEGA_CHUNK_SCALE)
				_giga_chunk_size = _chunk_size * float(GIGA_CHUNK_SCALE)
				_has_server = true
		elif msg_type == MSG_BATCH_END:
			_tcp_waiting_batch = maxi(0, _tcp_waiting_batch - 1)
			_packet_count += 1

func _apply_local_input(delta: float) -> void:
	var mf := _axis_from_keys(KEY_S, KEY_W)
	var mr := _axis_from_keys(KEY_D, KEY_A)
	var mu := _axis_from_keys(KEY_F, KEY_R)
	var is_moving_h := (mf != 0.0 or mr != 0.0)
	var is_moving_v := (mu != 0.0)
	var sprint_scale := 1.0
	if is_moving_h or is_moving_v:
		if Input.is_key_pressed(KEY_CTRL):
			sprint_scale = 100.0
		elif Input.is_key_pressed(KEY_SHIFT):
			sprint_scale = 3.0
	var look_yaw := _pending_mouse_yaw
	_pending_mouse_yaw = 0.0
	_facing_angle += look_yaw
	_player_node.rotation = Vector3(0.0, _facing_angle, 0.0)

	var spd := float(sprint_scale) * 8.0 * delta
	var sin_y := sin(_facing_angle)
	var cos_y := cos(_facing_angle)
	var dx := sin_y * mf + cos_y * mr
	var dz := cos_y * mf - sin_y * mr
	var mag := sqrt(dx * dx + dz * dz)
	if mag > 1.0:
		dx /= mag
		dz /= mag
	_player_node.position.x += dx * spd
	_player_node.position.z += dz * spd
	# Vertical direct control (R/F keys) — overrides gravity while active.
	if is_moving_v:
		_player_node.position.y += mu * spd
		_vertical_velocity = 0.0
		_is_grounded = false
	_update_human_pose(sprint_scale, is_moving_h, delta)
	_player_label.text = "Player (" + str(int(_player_node.position.x)) + ", " + str(int(_player_node.position.z)) + ")"

func _maybe_send_want_batch_tcp() -> void:
	if not _tcp_connected or not _has_server:
		return
	if _tcp_waiting_batch >= _tcp_max_batches_in_flight:
		return

	# Forward direction for FOV filtering (shared by both regular & mega).
	const FOV_BIAS_ANGLE := -0.12
	var biased_angle := _facing_angle + FOV_BIAS_ANGLE
	var fwd_x := sin(biased_angle)
	var fwd_z := cos(biased_angle)
	var target_n := mini(maxi(1, _tcp_batch_n), _max_mesh_builds_per_frame)

	var px := _player_node.position.x
	var pz := _player_node.position.z

	# ── Try regular (scale-1) chunks first ──────────────────────────────────
	var pcx := int(floor(px / _chunk_size))
	var pcz := int(floor(pz / _chunk_size))
	var send_list := _build_regular_want_list(pcx, pcz, fwd_x, fwd_z, target_n)
	_want_outstanding = send_list.size()

	if not send_list.is_empty():
		_send_want_packet(pcx, pcz, 1, send_list)
		return

	# ── Regular zone satisfied — fill mega-chunks (scale-8) ─────────────────
	var mpcx := int(floor(px / _mega_chunk_size))
	var mpcz := int(floor(pz / _mega_chunk_size))
	var mega_list := _build_mega_want_list(mpcx, mpcz, px, pz, fwd_x, fwd_z, target_n)
	_want_outstanding = mega_list.size()

	if not mega_list.is_empty():
		_send_want_packet(mpcx, mpcz, MEGA_CHUNK_SCALE, mega_list)
		return

	# ── Mega zone satisfied — fill giga-chunks (scale-64) ─────────────────
	var gpcx := int(floor(px / _giga_chunk_size))
	var gpcz := int(floor(pz / _giga_chunk_size))
	var giga_list := _build_giga_want_list(gpcx, gpcz, px, pz, fwd_x, fwd_z, target_n)
	_want_outstanding = giga_list.size()

	if not giga_list.is_empty():
		_send_want_packet(gpcx, gpcz, GIGA_CHUNK_SCALE, giga_list)

func _build_regular_want_list(pcx: int, pcz: int, fwd_x: float, fwd_z: float, target_n: int) -> PackedInt32Array:
	var send_list := PackedInt32Array()
	# Step 1: R≤2 patch around player (no FOV filter)
	for dz in range(-2, 3):
		for dx in range(-2, 3):
			if dx * dx + dz * dz > 4:
				continue
			if not _received_chunks.has(Vector2i(pcx + dx, pcz + dz)):
				send_list.append(((dx & 0xFFFF) << 16) | (dz & 0xFFFF))
				if send_list.size() >= target_n:
					return send_list
	# Step 2: FOV sweep outward
	if send_list.size() < target_n:
		_ensure_want_offsets()
		const FOV_COS2 := 0.25
		for packed32 in _want_offsets:
			var dx_u: int = (packed32 >> 16) & 0xFFFF
			var dz_u: int = packed32 & 0xFFFF
			var dx: int = dx_u - 0x10000 if dx_u >= 0x8000 else dx_u
			var dz: int = dz_u - 0x10000 if dz_u >= 0x8000 else dz_u
			var dist2 := dx * dx + dz * dz
			if dist2 <= 4:
				continue
			var dot := float(dx) * fwd_x + float(dz) * fwd_z
			if dot <= 0.0 or dot * dot < FOV_COS2 * float(dist2):
				continue
			if _received_chunks.has(Vector2i(pcx + dx, pcz + dz)):
				continue
			send_list.append(packed32)
			if send_list.size() >= target_n:
				break
	return send_list

func _build_mega_want_list(mpcx: int, mpcz: int, px: float, pz: float, fwd_x: float, fwd_z: float, target_n: int) -> PackedInt32Array:
	_ensure_mega_want_offsets()
	# Exclude mega-chunks whose nearest edge is well inside the regular chunk zone.
	# Shrink by one mega-chunk so boundary megas get requested (overlap with regulars).
	var regular_zone_ft := maxf(0.0, float(view_distance_chunks) * _chunk_size - _mega_chunk_size)
	var regular_zone_sq := regular_zone_ft * regular_zone_ft
	var send_list := PackedInt32Array()
	for packed32 in _mega_want_offsets:
		var dx_u: int = (packed32 >> 16) & 0xFFFF
		var dz_u: int = packed32 & 0xFFFF
		var dx: int = dx_u - 0x10000 if dx_u >= 0x8000 else dx_u
		var dz: int = dz_u - 0x10000 if dz_u >= 0x8000 else dz_u
		var cx := mpcx + dx
		var cz := mpcz + dz
		# World-space AABB nearest-edge distance — skip if inside regular zone.
		var aabb_min_x := float(cx) * _mega_chunk_size
		var aabb_max_x := float(cx + 1) * _mega_chunk_size
		var aabb_min_z := float(cz) * _mega_chunk_size
		var aabb_max_z := float(cz + 1) * _mega_chunk_size
		var ddx := maxf(0.0, maxf(aabb_min_x - px, px - aabb_max_x))
		var ddz := maxf(0.0, maxf(aabb_min_z - pz, pz - aabb_max_z))
		if ddx * ddx + ddz * ddz < regular_zone_sq:
			continue  # overlaps with regular zone
		if _received_mega_chunks.has(Vector2i(cx, cz)):
			continue
		send_list.append(packed32)
		if send_list.size() >= target_n:
			break
	return send_list

func _send_want_packet(pcx: int, pcz: int, scale: int, send_list: PackedInt32Array) -> void:
	_tcp_seq = (_tcp_seq + 1) & 0x7FFFFFFF
	var req_id := _tcp_seq
	var spb := StreamPeerBuffer.new()
	spb.big_endian = false
	spb.put_u32(req_id)
	spb.put_u8(0)          # part
	spb.put_u8(1)          # total_parts
	spb.put_u8(scale)      # chunk_size multiplier
	spb.put_32(pcx)
	spb.put_32(pcz)
	spb.put_u32(send_list.size())
	for packed32 in send_list:
		var dx_u: int = (packed32 >> 16) & 0xFFFF
		var dz_u: int = packed32 & 0xFFFF
		var dx: int = dx_u - 0x10000 if dx_u >= 0x8000 else dx_u
		var dz: int = dz_u - 0x10000 if dz_u >= 0x8000 else dz_u
		spb.put_16(dx)
		spb.put_16(dz)
	_tcp_waiting_batch += 1
	_tcp_send_packet(MSG_WANT, req_id, spb.data_array)

func _ensure_mega_want_offsets() -> void:
	var r := view_distance_mega_chunks
	if r == _mega_want_offsets_r and _mega_want_offsets.size() > 0:
		return
	_mega_want_offsets_r = r
	_mega_want_offsets = _build_sorted_offsets(r)

func _build_giga_want_list(gpcx: int, gpcz: int, px: float, pz: float, fwd_x: float, fwd_z: float, target_n: int) -> PackedInt32Array:
	_ensure_giga_want_offsets()
	# Exclude giga-chunks whose nearest edge is well inside the mega zone.
	# Shrink by one giga-chunk so boundary gigas get requested (overlap with megas).
	var mega_zone_ft := maxf(0.0, float(view_distance_mega_chunks) * _mega_chunk_size - _giga_chunk_size)
	var mega_zone_sq := mega_zone_ft * mega_zone_ft
	var send_list := PackedInt32Array()
	for packed32 in _giga_want_offsets:
		var dx_u: int = (packed32 >> 16) & 0xFFFF
		var dz_u: int = packed32 & 0xFFFF
		var dx: int = dx_u - 0x10000 if dx_u >= 0x8000 else dx_u
		var dz: int = dz_u - 0x10000 if dz_u >= 0x8000 else dz_u
		var cx := gpcx + dx
		var cz := gpcz + dz
		# World-space AABB nearest-edge distance — skip if inside mega zone.
		var aabb_min_x := float(cx) * _giga_chunk_size
		var aabb_max_x := float(cx + 1) * _giga_chunk_size
		var aabb_min_z := float(cz) * _giga_chunk_size
		var aabb_max_z := float(cz + 1) * _giga_chunk_size
		var ddx := maxf(0.0, maxf(aabb_min_x - px, px - aabb_max_x))
		var ddz := maxf(0.0, maxf(aabb_min_z - pz, pz - aabb_max_z))
		if ddx * ddx + ddz * ddz < mega_zone_sq:
			continue  # overlaps with mega zone
		if _received_giga_chunks.has(Vector2i(cx, cz)):
			continue
		send_list.append(packed32)
		if send_list.size() >= target_n:
			break
	return send_list

func _ensure_giga_want_offsets() -> void:
	var r := view_distance_giga_chunks
	if r == _giga_want_offsets_r and _giga_want_offsets.size() > 0:
		return
	_giga_want_offsets_r = r
	_giga_want_offsets = _build_sorted_offsets(r)

func _flush_all_tiles() -> void:
	for key in _chunks.keys():
		var chunk: MeshInstance3D = _chunks[key]
		chunk.queue_free()
	_chunks.clear()
	_received_chunks.clear()
	_pending_chunks.clear()
	_pending_chunk_packets.clear()
	_tcp_waiting_batch = 0
	_terrain_heights.clear()
	# Also flush mega-chunks.
	for key in _mega_chunks.keys():
		var chunk: MeshInstance3D = _mega_chunks[key]
		chunk.queue_free()
	_mega_chunks.clear()
	_received_mega_chunks.clear()
	_pending_mega_chunks.clear()
	_terrain_mega_heights.clear()
	# Also flush giga-chunks.
	for key in _giga_chunks.keys():
		var chunk: MeshInstance3D = _giga_chunks[key]
		chunk.queue_free()
	_giga_chunks.clear()
	_received_giga_chunks.clear()
	_pending_giga_chunks.clear()
	_terrain_giga_heights.clear()
	_mega_pending_removal.clear()
	_giga_pending_removal.clear()

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		_pending_mouse_yaw -= motion.relative.x * mouse_sensitivity
		_camera_pitch -= motion.relative.y * mouse_pitch_sensitivity
		_camera_pitch = clamp(_camera_pitch, min_camera_pitch, max_camera_pitch)
	elif event is InputEventMouseButton and event.pressed:
		# Auto-capture on left click for reliability when window focus changes.
		var mb := event as InputEventMouseButton
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED and mb.button_index == MOUSE_BUTTON_LEFT:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			_hud_label.text = ""
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		elif event.keycode == KEY_TAB:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		elif event.keycode == KEY_Q:
			if _world_env != null:
				_world_env.volumetric_fog_density = clampf(_world_env.volumetric_fog_density / 2.0, 0.0000001, 10.0)
				_update_hud()
		elif event.keycode == KEY_Z:
			if _world_env != null:
				_world_env.volumetric_fog_density = clampf(_world_env.volumetric_fog_density * 2.0, 0.0000001, 10.0)
				_update_hud()
		elif event.keycode == KEY_QUOTELEFT:
			_randomize_weather()
		elif event.keycode == KEY_BACKSPACE:
			_terrain_layer_mode = (_terrain_layer_mode + 1) % 5
			_flush_all_tiles()
			var lm_payload := PackedByteArray()
			lm_payload.resize(1)
			lm_payload[0] = _terrain_layer_mode
			_tcp_seq = (_tcp_seq + 1) & 0x7FFFFFFF
			_tcp_send_packet(MSG_SET_LAYER_MODE, _tcp_seq, lm_payload)

func _setup_scene() -> void:
	_player_node = Node3D.new()
	_player_node.scale = Vector3.ONE * player_scale
	add_child(_player_node)

	# Starting world position (feet): X/Z = (8433, -1775)
	_player_node.position = Vector3(8433.0, 0.0, -1775.0)

	_build_human_figure()

	_player_label = Label3D.new()
	_player_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_player_label.text = "Player"
	_player_label.position = Vector3(0, 7.5, 0)
	_player_node.add_child(_player_label)

	_hud_layer = CanvasLayer.new()
	add_child(_hud_layer)
	_hud_label = Label.new()
	_hud_label.text = "Pos: (0, 0, 0)"
	_hud_label.position = Vector2(12, 12)
	_hud_layer.add_child(_hud_label)

	_sun_light = DirectionalLight3D.new()
	_sun_light.rotation_degrees = Vector3(-50, 30, 0)
	_sun_light.light_energy = 1.2
	add_child(_sun_light)

	# ── Sky with ProceduralSkyMaterial for realistic atmospheric blending ──
	_world_env_node = WorldEnvironment.new()
	_world_env = Environment.new()
	var env := _world_env

	# Procedural sky: proper sun disk, horizon haze, ground reflection.
	_sky_material = ProceduralSkyMaterial.new()
	_sky_material.sky_top_color = Color(0.25, 0.46, 0.82)      # deep blue overhead
	_sky_material.sky_horizon_color = Color(0.55, 0.70, 0.88)   # hazy horizon
	_sky_material.sky_curve = 0.15                              # gradual transition
	_sky_material.ground_bottom_color = Color(0.17, 0.20, 0.25) # dark ground reflect
	_sky_material.ground_horizon_color = Color(0.55, 0.70, 0.88) # match sky horizon
	_sky_material.ground_curve = 0.02
	_sky_material.sun_angle_max = 30.0
	_sky_material.sun_curve = 0.15
	_sky = Sky.new()
	_sky.sky_material = _sky_material
	_sky.radiance_size = Sky.RADIANCE_SIZE_256
	env.sky = _sky
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.4
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	# Tone-mapping so bright sky doesn't blow out.
	# Avoid referencing Environment enum members (builds differ); use numeric fallback.
	# 0 is the "linear" tone mapper in Godot 4.x.
	if _object_has_property(env, "tonemap_mode"):
		env.set("tonemap_mode", 0)
	elif _object_has_property(env, "tone_mapper"):
		env.set("tone_mapper", 0)
	if _object_has_property(env, "tonemap_white"):
		env.set("tonemap_white", 6.0)

	# ── Volumetric fog: proper atmospheric scattering at flight-sim scale ──
	env.fog_enabled = false                   # disable old depth fog
	env.volumetric_fog_enabled = true
	# Density is per-unit; at our huge scale (feet) we need a tiny value.
	# Start with a reasonable default; Q/Z keys adjust at runtime.
	env.volumetric_fog_density = 0.00001
	env.volumetric_fog_albedo = Color(0.65, 0.75, 0.88)  # hazy blue-grey
	env.volumetric_fog_emission = Color(0.0, 0.0, 0.0)
	env.volumetric_fog_emission_energy = 0.0
	env.volumetric_fog_anisotropy = 0.3       # mild forward-scattering toward sun
	env.volumetric_fog_length = 50000.0       # fog volume extends to 50k ft
	env.volumetric_fog_detail_spread = 2.0
	env.volumetric_fog_gi_inject = 0.0
	env.volumetric_fog_sky_affect = 1.0       # fog blends toward the sky
	env.volumetric_fog_temporal_reprojection_enabled = true
	env.volumetric_fog_temporal_reprojection_amount = 0.9

	_world_env_node.environment = env
	add_child(_world_env_node)

	_camera = Camera3D.new()
	_camera.position = Vector3(0, camera_height, camera_distance)
	# Units are feet; set the far plane beyond the 40k-ft fog range.
	_camera.near = 1.0
	_camera.far = 60000.0
	add_child(_camera)
	_camera.look_at(Vector3.ZERO, Vector3.UP)

	_create_global_water()
	_update_underwater_lighting(false)

	# Load the terrain vertex-displacement shader (normals + colour computed on GPU).
	_terrain_shader = load("res://terrain_chunk.gdshader") as Shader


func _create_global_water() -> void:
	_water_plane = MeshInstance3D.new()
	_water_plane.name = "WaterPlane"
	var plane := PlaneMesh.new()
	# Big enough for early prototyping; adjust later if needed.
	plane.size = Vector2(200000.0, 200000.0)
	_water_plane.mesh = plane
	_water_plane.position = Vector3(0.0, 0.0, 0.0)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.28, 0.6, 0.55)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Ensure the water participates in fog (transparent objects can otherwise
	# skip depth-based fog depending on render path/settings).
	for prop in mat.get_property_list():
		var pname: String = String(prop.get("name", ""))
		if pname == "disable_fog" or pname == "fog_disabled":
			mat.set(pname, false)
		elif pname == "depth_draw_mode":
			mat.set(pname, BaseMaterial3D.DEPTH_DRAW_ALWAYS)
	# Transparent water should not be backface culled.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_water_plane.material_override = mat
	add_child(_water_plane)


func _object_has_property(obj: Object, prop_name: String) -> bool:
	for prop in obj.get_property_list():
		var pname: String = String(prop.get("name", ""))
		if pname == prop_name:
			return true
	return false


func _update_water_level(delta: float) -> void:
	_game_time += delta
	# Tide: 5 ft total range (±2.5 ft) with ~2-hour period (7200 s).
	var tide := 2.5 * sin(_game_time * TAU / 7200.0)
	# Lapping / shore waves: 1 ft total range (±0.5 ft) with ~30 s period.
	var lapping := 0.5 * sin(_game_time * TAU / 30.0)
	_water_plane.position.y = tide + lapping

func _update_underwater_lighting(force: bool = false) -> void:
	var underwater_now := _camera != null and _camera.global_position.y < 0.0
	if not force and underwater_now == _is_underwater:
		return
	_is_underwater = underwater_now
	if _is_underwater:
		_sun_light.light_energy = 0.35
		_sun_light.light_color = Color(0.55, 0.75, 1.0)
	else:
		_sun_light.light_energy = 1.0
		_sun_light.light_color = Color(1.0, 1.0, 1.0)

# ── Weather randomizer (backtick key) ─────────────────────────────────────
# Presets cover clear, overcast, hazy, stormy, golden-hour, and foggy conditions.
# Each preset adjusts sky colors, fog density, sun energy, and fog anisotropy.
const WEATHER_PRESETS: Array[Dictionary] = [
	{ "name": "Clear",       "sky_top": Color(0.25, 0.46, 0.82), "sky_horiz": Color(0.55, 0.70, 0.88), "ground_horiz": Color(0.55, 0.70, 0.88), "fog_density": 0.000005, "fog_albedo": Color(0.65, 0.78, 0.90), "sun_energy": 1.2, "aniso": 0.3 },
	{ "name": "Overcast",    "sky_top": Color(0.45, 0.48, 0.52), "sky_horiz": Color(0.55, 0.56, 0.58), "ground_horiz": Color(0.50, 0.52, 0.55), "fog_density": 0.00004, "fog_albedo": Color(0.58, 0.60, 0.62), "sun_energy": 0.5, "aniso": 0.05 },
	{ "name": "Hazy",        "sky_top": Color(0.35, 0.52, 0.75), "sky_horiz": Color(0.65, 0.72, 0.80), "ground_horiz": Color(0.62, 0.68, 0.76), "fog_density": 0.00003, "fog_albedo": Color(0.70, 0.75, 0.82), "sun_energy": 0.9, "aniso": 0.15 },
	{ "name": "Stormy",      "sky_top": Color(0.18, 0.20, 0.26), "sky_horiz": Color(0.30, 0.32, 0.38), "ground_horiz": Color(0.28, 0.30, 0.34), "fog_density": 0.00006, "fog_albedo": Color(0.35, 0.38, 0.42), "sun_energy": 0.3, "aniso": 0.0 },
	{ "name": "Golden Hour", "sky_top": Color(0.30, 0.38, 0.65), "sky_horiz": Color(0.85, 0.60, 0.35), "ground_horiz": Color(0.80, 0.55, 0.30), "fog_density": 0.00002, "fog_albedo": Color(0.85, 0.68, 0.45), "sun_energy": 0.8, "aniso": 0.6 },
	{ "name": "Dense Fog",   "sky_top": Color(0.60, 0.62, 0.64), "sky_horiz": Color(0.68, 0.70, 0.72), "ground_horiz": Color(0.66, 0.68, 0.70), "fog_density": 0.0001, "fog_albedo": Color(0.70, 0.72, 0.74), "sun_energy": 0.4, "aniso": 0.0 },
]

func _randomize_weather() -> void:
	if _world_env == null or _sky_material == null:
		return
	var preset: Dictionary = WEATHER_PRESETS[randi() % WEATHER_PRESETS.size()]
	# Sky
	_sky_material.sky_top_color = preset["sky_top"] as Color
	_sky_material.sky_horizon_color = preset["sky_horiz"] as Color
	_sky_material.ground_horizon_color = preset["ground_horiz"] as Color
	# Volumetric fog
	_world_env.volumetric_fog_density = preset["fog_density"] as float
	_world_env.volumetric_fog_albedo = preset["fog_albedo"] as Color
	_world_env.volumetric_fog_anisotropy = preset["aniso"] as float
	# Sun
	_sun_light.light_energy = preset["sun_energy"] as float
	print("Weather → ", preset["name"])
	_update_hud()

func _axis_from_keys(negative_key: Key, positive_key: Key) -> float:
	var value := 0.0
	if Input.is_key_pressed(positive_key):
		value += 1.0
	if Input.is_key_pressed(negative_key):
		value -= 1.0
	return clamp(value, -1.0, 1.0)

func _angle_diff(a: float, b: float) -> float:
	var TAU: float = PI * 2.0
	var d: float = a - b
	while d > PI:
		d -= TAU
	while d < -PI:
		d += TAU
	return d

func _drain_chunk_packets() -> void:
	var decoded := 0
	while not _pending_chunk_packets.is_empty() and decoded < _max_chunk_decodes_per_frame:
		var payload_bytes: PackedByteArray = _pending_chunk_packets.pop_front() as PackedByteArray
		var payload := _decode_chunk_payload(payload_bytes)
		if payload.is_empty():
			continue
		_apply_chunk_message(payload)
		decoded += 1

func _decode_chunk_payload(payload: PackedByteArray) -> Dictionary:
	if payload.size() < 44:
		return {}

	var cx := payload.decode_s32(0)
	var cz := payload.decode_s32(4)
	var chunk_size := payload.decode_float(8)
	var chunk_resolution := payload.decode_s32(12)
	var height_amplitude := payload.decode_float(16)
	# height_scale at offset 20 — now always 1.0 (heights are raw float32)
	var height_count := int(payload.decode_u32(40))
	# Server sends heights then biomes (each n*n float32s), so total count = 2*n*n.
	var vertex_count := height_count / 2
	if payload.size() < 44 + height_count * 4:
		return {}

	# Slice the raw float32 bytes — zero GDScript iteration.
	var height_bytes := payload.slice(44, 44 + vertex_count * 4)
	var biome_bytes := payload.slice(44 + vertex_count * 4, 44 + height_count * 4)

	return {
		"cx": cx,
		"cz": cz,
		"chunk_size": chunk_size,
		"chunk_resolution": chunk_resolution,
		"height_amplitude": height_amplitude,
		"height_bytes": height_bytes,
		"biome_bytes": biome_bytes,
	}

func _update_camera() -> void:
	var player_pos: Vector3 = _player_node.position
	var moved := (player_pos - _prev_player_pos).length_squared() > _camera_move_epsilon * _camera_move_epsilon
	var turned := (_prev_facing_angle != INF) and absf(_angle_diff(_facing_angle, _prev_facing_angle)) > 0.0001
	var pitch_changed := (_prev_camera_pitch != INF) and absf(_camera_pitch - _prev_camera_pitch) > 0.0001
	if not moved and not turned and not pitch_changed:
		return
	var forward := Vector3(sin(_facing_angle), 0.0, cos(_facing_angle)).normalized()
	var right := Vector3(forward.z, 0.0, -forward.x).normalized()
	var forward_pitched := (forward * cos(_camera_pitch) + Vector3.UP * sin(_camera_pitch)).normalized()

	var camera_target := player_pos + Vector3(0.0, camera_height * 0.5, 0.0) + (forward_pitched * camera_look_ahead)
	var camera_pos := player_pos - (forward * camera_distance) + (right * camera_shoulder_offset)
	camera_pos.y = player_pos.y + camera_height

	_camera.global_transform = Transform3D(_camera.global_transform.basis, camera_pos)
	_camera.look_at(camera_target, Vector3.UP)

	_prev_player_pos = player_pos
	_prev_facing_angle = _facing_angle
	_prev_camera_pitch = _camera_pitch
func _update_hud() -> void:
	var pos_text := "Pos: (" + str(int(_player_node.position.x)) + ", " + str(int(_player_node.position.y)) + ", " + str(int(_player_node.position.z)) + ")"
	var status := "NET: TCP"
	status += "  Connected:" + ("1" if _tcp_connected else "0")
	status += "  Hello:" + ("1" if _tcp_hello_sent else "0")
	status += "  BatchN:" + str(_tcp_batch_n)
	status += "  Waiting:" + str(_tcp_waiting_batch)
	status += "  Batches:" + str(_packet_count)
	status += "  Sent: " + str(_send_count) + "  LastSend(ms): " + str(_last_send_time_ms)
	status += "  Target: " + server_host + ":" + str(server_tcp_port)
	if not _has_server:
		status += "  [NO SERVER]"
	status += "  Built:" + str(_chunks.size()) + "+" + str(_mega_chunks.size()) + "m+" + str(_giga_chunks.size()) + "g  Queue:" + str(_pending_chunks.size()) + "  Want:" + str(_want_outstanding)
	status += "  RxQ:" + str(_pending_chunk_packets.size())
	if _world_env != null:
		var fd: float = _world_env.volumetric_fog_density
		status += "  FogD:" + str(snappedf(fd, 0.0000001))
	_hud_label.text = pos_text + "  Facing: " + str(snapped(_facing_angle, 0.01)) + "  " + status + "  Layer: " + LAYER_MODE_NAMES[_terrain_layer_mode]

func _apply_chunk_message(payload: Dictionary) -> void:
	if payload.is_empty():
		return
	var cx := int(payload.get("cx", 0))
	var cz := int(payload.get("cz", 0))
	var pkt_chunk_size := float(payload.get("chunk_size", _chunk_size))
	var key := Vector2i(cx, cz)

	# Route giga/mega/regular based on chunk_size in the response.
	var is_giga := pkt_chunk_size > _mega_chunk_size * 1.5
	var is_mega := not is_giga and pkt_chunk_size > _chunk_size * 1.5
	if is_giga:
		_received_giga_chunks[key] = true
		if _giga_chunks.has(key):
			return
		_pending_giga_chunks.push_back(payload.duplicate())
	elif is_mega:
		_received_mega_chunks[key] = true
		if _mega_chunks.has(key):
			return
		_pending_mega_chunks.push_back(payload.duplicate())
	else:
		# Regular: update globals from payload (as before).
		_chunk_size = pkt_chunk_size
		_chunk_resolution = int(payload.get("chunk_resolution", _chunk_resolution))
		_chunk_height_amplitude = float(payload.get("height_amplitude", _chunk_height_amplitude))
		_received_chunks[key] = true
		if _chunks.has(key):
			return
		_pending_chunks.push_back(payload.duplicate())

func _drain_chunk_queue() -> void:
	# ── Regular chunks ──
	if not _pending_chunks.is_empty():
		var pcx := int(floor(_player_node.position.x / _chunk_size))
		var pcz := int(floor(_player_node.position.z / _chunk_size))
		var r2 := view_distance_chunks * view_distance_chunks
		for i in range(_pending_chunks.size()):
			var p: Dictionary = _pending_chunks[i]
			var cx := int(p["cx"])
			var cz := int(p["cz"])
			var dx := cx - pcx
			var dz := cz - pcz
			if dx * dx + dz * dz > r2:
				# Too far now — clear received so it can be re-requested later.
				_received_chunks.erase(Vector2i(cx, cz))
				continue
			var key := Vector2i(cx, cz)
			if _chunks.has(key):
				continue
			var height_bytes: PackedByteArray = p.get("height_bytes", PackedByteArray())
			var biome_bytes: PackedByteArray = p.get("biome_bytes", PackedByteArray())
			_create_chunk(cx, cz, height_bytes, biome_bytes)
		_pending_chunks.clear()
	# ── Mega chunks ──
	if not _pending_mega_chunks.is_empty():
		var mpcx := int(floor(_player_node.position.x / _mega_chunk_size))
		var mpcz := int(floor(_player_node.position.z / _mega_chunk_size))
		var mr2 := view_distance_mega_chunks * view_distance_mega_chunks
		for i in range(_pending_mega_chunks.size()):
			var p: Dictionary = _pending_mega_chunks[i]
			var cx := int(p["cx"])
			var cz := int(p["cz"])
			var dx := cx - mpcx
			var dz := cz - mpcz
			if dx * dx + dz * dz > mr2:
				_received_mega_chunks.erase(Vector2i(cx, cz))
				continue
			var key := Vector2i(cx, cz)
			if _mega_chunks.has(key):
				continue
			var height_bytes: PackedByteArray = p.get("height_bytes", PackedByteArray())
			var biome_bytes: PackedByteArray = p.get("biome_bytes", PackedByteArray())
			_create_mega_chunk(cx, cz, height_bytes, biome_bytes)
		_pending_mega_chunks.clear()
	# ── Giga chunks ──
	if not _pending_giga_chunks.is_empty():
		var gpcx := int(floor(_player_node.position.x / _giga_chunk_size))
		var gpcz := int(floor(_player_node.position.z / _giga_chunk_size))
		var gr2 := view_distance_giga_chunks * view_distance_giga_chunks
		for i in range(_pending_giga_chunks.size()):
			var p: Dictionary = _pending_giga_chunks[i]
			var cx := int(p["cx"])
			var cz := int(p["cz"])
			var dx := cx - gpcx
			var dz := cz - gpcz
			if dx * dx + dz * dz > gr2:
				_received_giga_chunks.erase(Vector2i(cx, cz))
				continue
			var key := Vector2i(cx, cz)
			if _giga_chunks.has(key):
				continue
			var height_bytes: PackedByteArray = p.get("height_bytes", PackedByteArray())
			var biome_bytes: PackedByteArray = p.get("biome_bytes", PackedByteArray())
			_create_giga_chunk(cx, cz, height_bytes, biome_bytes)
		_pending_giga_chunks.clear()

func _prune_chunks() -> void:
	var px := _player_node.position.x
	var pz := _player_node.position.z
	# ── Regular chunks ──
	var center_x := int(floor(px / _chunk_size))
	var center_z := int(floor(pz / _chunk_size))
	for key in _chunks.keys():
		var k: Vector2i = key
		if abs(k.x - center_x) > view_distance_chunks or abs(k.y - center_z) > view_distance_chunks:
			var chunk: MeshInstance3D = _chunks[k]
			chunk.queue_free()
			_chunks.erase(k)
			_received_chunks.erase(k)
			_terrain_heights.erase(k)
	# ── Mega chunks: distance prune + deferred removal when covered by regulars ──
	if _mega_chunk_size > 0.0:
		var mcx := int(floor(px / _mega_chunk_size))
		var mcz := int(floor(pz / _mega_chunk_size))
		var regular_zone_ft := float(view_distance_chunks) * _chunk_size
		var regular_zone_sq := regular_zone_ft * regular_zone_ft
		for key in _mega_chunks.keys():
			var k: Vector2i = key
			if abs(k.x - mcx) > view_distance_mega_chunks or abs(k.y - mcz) > view_distance_mega_chunks:
				var chunk: MeshInstance3D = _mega_chunks[k]
				chunk.queue_free()
				_mega_chunks.erase(k)
				_received_mega_chunks.erase(k)
				_terrain_mega_heights.erase(k)
				_mega_pending_removal.erase(k)
				continue
			# Mark for removal once furthest edge enters regular zone.
			var aabb_min_x := float(k.x) * _mega_chunk_size
			var aabb_max_x := float(k.x + 1) * _mega_chunk_size
			var aabb_min_z := float(k.y) * _mega_chunk_size
			var aabb_max_z := float(k.y + 1) * _mega_chunk_size
			var ddx := maxf(absf(aabb_min_x - px), absf(aabb_max_x - px))
			var ddz := maxf(absf(aabb_min_z - pz), absf(aabb_max_z - pz))
			if ddx * ddx + ddz * ddz < regular_zone_sq:
				_mega_pending_removal[k] = true
			else:
				_mega_pending_removal.erase(k)
			# Actually remove only when all constituent regular chunks are built.
			if _mega_pending_removal.has(k):
				var base_cx := k.x * MEGA_CHUNK_SCALE
				var base_cz := k.y * MEGA_CHUNK_SCALE
				var all_present := true
				for dz in range(MEGA_CHUNK_SCALE):
					for dx in range(MEGA_CHUNK_SCALE):
						if not _chunks.has(Vector2i(base_cx + dx, base_cz + dz)):
							all_present = false
							break
					if not all_present:
						break
				if all_present:
					var chunk: MeshInstance3D = _mega_chunks[k]
					chunk.queue_free()
					_mega_chunks.erase(k)
					_mega_pending_removal.erase(k)
					# Keep _received_mega_chunks entry so it won't be re-requested.
					_terrain_mega_heights.erase(k)
	# ── Giga chunks: distance prune + deferred removal when covered by megas ──
	if _giga_chunk_size > 0.0:
		var gcx := int(floor(px / _giga_chunk_size))
		var gcz := int(floor(pz / _giga_chunk_size))
		var mega_zone_ft := float(view_distance_mega_chunks) * _mega_chunk_size
		var mega_zone_sq := mega_zone_ft * mega_zone_ft
		var giga_mega_ratio := GIGA_CHUNK_SCALE / MEGA_CHUNK_SCALE  # 8
		for key in _giga_chunks.keys():
			var k: Vector2i = key
			if abs(k.x - gcx) > view_distance_giga_chunks or abs(k.y - gcz) > view_distance_giga_chunks:
				var chunk: MeshInstance3D = _giga_chunks[k]
				chunk.queue_free()
				_giga_chunks.erase(k)
				_received_giga_chunks.erase(k)
				_terrain_giga_heights.erase(k)
				_giga_pending_removal.erase(k)
				continue
			# Mark for removal once furthest edge enters mega zone.
			var aabb_min_x := float(k.x) * _giga_chunk_size
			var aabb_max_x := float(k.x + 1) * _giga_chunk_size
			var aabb_min_z := float(k.y) * _giga_chunk_size
			var aabb_max_z := float(k.y + 1) * _giga_chunk_size
			var ddx := maxf(absf(aabb_min_x - px), absf(aabb_max_x - px))
			var ddz := maxf(absf(aabb_min_z - pz), absf(aabb_max_z - pz))
			if ddx * ddx + ddz * ddz < mega_zone_sq:
				_giga_pending_removal[k] = true
			else:
				_giga_pending_removal.erase(k)
			# Actually remove only when all constituent mega chunks are built.
			if _giga_pending_removal.has(k):
				var base_mcx := k.x * giga_mega_ratio
				var base_mcz := k.y * giga_mega_ratio
				var all_present := true
				for dz in range(giga_mega_ratio):
					for dx in range(giga_mega_ratio):
						if not _mega_chunks.has(Vector2i(base_mcx + dx, base_mcz + dz)):
							all_present = false
							break
					if not all_present:
						break
				if all_present:
					var chunk: MeshInstance3D = _giga_chunks[k]
					chunk.queue_free()
					_giga_chunks.erase(k)
					_giga_pending_removal.erase(k)
					# Keep _received_giga_chunks entry so it won't be re-requested.
					_terrain_giga_heights.erase(k)

func _ensure_want_offsets() -> void:
	var r := view_distance_chunks
	if r == _want_offsets_r and _want_offsets.size() > 0:
		return
	_want_offsets_r = r
	_want_cursor = 0
	_want_offsets = _build_sorted_offsets(r)

func _build_sorted_offsets(r: int) -> PackedInt32Array:
	var r2 := r * r
	var packed64: Array[int] = []
	for dx in range(-r, r + 1):
		var dx2 := dx * dx
		for dz in range(-r, r + 1):
			var dist2 := dx2 + dz * dz
			if dist2 > r2:
				continue
			var dx_u := dx & 0xFFFF
			var dz_u := dz & 0xFFFF
			# [dist2:32][dx_u16:16][dz_u16:16]
			packed64.push_back((int(dist2) << 32) | (dx_u << 16) | dz_u)
	packed64.sort()
	var out := PackedInt32Array()
	out.resize(packed64.size())
	for i in range(packed64.size()):
		out[i] = int(packed64[i] & 0xFFFFFFFF)
	return out

func _make_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	return mat

func _build_human_figure() -> void:
	# All dimensions in feet. _player_node.position = feet (y=0).
	# _figure_root: body-lean pivot at y=3.0 (center of mass).
	# In figure_root space y=0 → world y=3.0; positive y is up.
	_figure_root = Node3D.new()
	_figure_root.position = Vector3(0.0, 3.0, 0.0)
	_figure_root.rotation.y = PI  # face forward (away from camera)
	_player_node.add_child(_figure_root)

	var skin  := _make_material(Color(0.95, 0.78, 0.62))
	var shirt := _make_material(Color(0.22, 0.40, 0.65))
	var pants := _make_material(Color(0.18, 0.18, 0.40))
	var shoes := _make_material(Color(0.10, 0.08, 0.06))
	var hair  := _make_material(Color(0.32, 0.20, 0.10))

	# HEAD — center at fig y=+2.65 (world 5.65); top at world 6.0
	var head_mesh := SphereMesh.new(); head_mesh.radius = 0.35; head_mesh.height = 0.70
	var head := MeshInstance3D.new(); head.mesh = head_mesh; head.material_override = skin
	head.position = Vector3(0.0, 2.65, 0.0); _figure_root.add_child(head)

	var hair_mesh := SphereMesh.new(); hair_mesh.radius = 0.36; hair_mesh.height = 0.36
	var hair_node := MeshInstance3D.new(); hair_node.mesh = hair_mesh; hair_node.material_override = hair
	hair_node.position = Vector3(0.0, 2.85, 0.0); _figure_root.add_child(hair_node)

	# NECK — fig y≈2.175, between shoulder (2.0) and head base (2.33)
	var neck_mesh := CapsuleMesh.new(); neck_mesh.radius = 0.12; neck_mesh.height = 0.35
	var neck := MeshInstance3D.new(); neck.mesh = neck_mesh; neck.material_override = skin
	neck.position = Vector3(0.0, 2.175, 0.0); _figure_root.add_child(neck)

	# TORSO — from fig y=0.25 (hips, world 3.25) to fig y=2.0 (shoulder, world 5.0)
	var torso_mesh := BoxMesh.new(); torso_mesh.size = Vector3(0.80, 1.75, 0.42)
	var torso := MeshInstance3D.new(); torso.mesh = torso_mesh; torso.material_override = shirt
	torso.position = Vector3(0.0, 1.125, 0.0); _figure_root.add_child(torso)

	# LEFT ARM — shoulder pivot at fig (−0.68, 2.0, 0) = world (−0.68, 5.0, 0)
	_l_shoulder_pivot = Node3D.new()
	_l_shoulder_pivot.position = Vector3(-0.68, 2.0, 0.0); _figure_root.add_child(_l_shoulder_pivot)
	var lua := CapsuleMesh.new(); lua.radius = 0.13; lua.height = 1.05
	var l_upper_arm := MeshInstance3D.new(); l_upper_arm.mesh = lua; l_upper_arm.material_override = shirt
	l_upper_arm.position = Vector3(0.0, -0.525, 0.0); _l_shoulder_pivot.add_child(l_upper_arm)
	_l_elbow_pivot = Node3D.new()
	_l_elbow_pivot.position = Vector3(0.0, -1.05, 0.0); _l_shoulder_pivot.add_child(_l_elbow_pivot)
	var lfa := CapsuleMesh.new(); lfa.radius = 0.11; lfa.height = 0.95
	var l_forearm := MeshInstance3D.new(); l_forearm.mesh = lfa; l_forearm.material_override = skin
	l_forearm.position = Vector3(0.0, -0.475, 0.0); _l_elbow_pivot.add_child(l_forearm)

	# RIGHT ARM
	_r_shoulder_pivot = Node3D.new()
	_r_shoulder_pivot.position = Vector3(0.68, 2.0, 0.0); _figure_root.add_child(_r_shoulder_pivot)
	var rua := CapsuleMesh.new(); rua.radius = 0.13; rua.height = 1.05
	var r_upper_arm := MeshInstance3D.new(); r_upper_arm.mesh = rua; r_upper_arm.material_override = shirt
	r_upper_arm.position = Vector3(0.0, -0.525, 0.0); _r_shoulder_pivot.add_child(r_upper_arm)
	_r_elbow_pivot = Node3D.new()
	_r_elbow_pivot.position = Vector3(0.0, -1.05, 0.0); _r_shoulder_pivot.add_child(_r_elbow_pivot)
	var rfa := CapsuleMesh.new(); rfa.radius = 0.11; rfa.height = 0.95
	var r_forearm := MeshInstance3D.new(); r_forearm.mesh = rfa; r_forearm.material_override = skin
	r_forearm.position = Vector3(0.0, -0.475, 0.0); _r_elbow_pivot.add_child(r_forearm)

	# LEFT LEG — hip pivot fig (−0.28, 0.25, 0) → world (−0.28, 3.25, 0)
	# Geometry: thigh 1.6ft, shin 1.55ft, shoe 0.20ft → foot bottom at world 0.0
	_l_hip_pivot = Node3D.new()
	_l_hip_pivot.position = Vector3(-0.28, 0.25, 0.0); _figure_root.add_child(_l_hip_pivot)
	var lth := CapsuleMesh.new(); lth.radius = 0.20; lth.height = 1.60
	var l_thigh := MeshInstance3D.new(); l_thigh.mesh = lth; l_thigh.material_override = pants
	l_thigh.position = Vector3(0.0, -0.80, 0.0); _l_hip_pivot.add_child(l_thigh)
	_l_knee_pivot = Node3D.new()
	_l_knee_pivot.position = Vector3(0.0, -1.60, 0.0); _l_hip_pivot.add_child(_l_knee_pivot)
	var lsh := CapsuleMesh.new(); lsh.radius = 0.15; lsh.height = 1.55
	var l_shin := MeshInstance3D.new(); l_shin.mesh = lsh; l_shin.material_override = pants
	l_shin.position = Vector3(0.0, -0.775, 0.0); _l_knee_pivot.add_child(l_shin)
	var lsm := BoxMesh.new(); lsm.size = Vector3(0.22, 0.20, 0.50)
	var l_shoe := MeshInstance3D.new(); l_shoe.mesh = lsm; l_shoe.material_override = shoes
	l_shoe.position = Vector3(0.0, -1.55, 0.12); _l_knee_pivot.add_child(l_shoe)

	# RIGHT LEG
	_r_hip_pivot = Node3D.new()
	_r_hip_pivot.position = Vector3(0.28, 0.25, 0.0); _figure_root.add_child(_r_hip_pivot)
	var rth := CapsuleMesh.new(); rth.radius = 0.20; rth.height = 1.60
	var r_thigh := MeshInstance3D.new(); r_thigh.mesh = rth; r_thigh.material_override = pants
	r_thigh.position = Vector3(0.0, -0.80, 0.0); _r_hip_pivot.add_child(r_thigh)
	_r_knee_pivot = Node3D.new()
	_r_knee_pivot.position = Vector3(0.0, -1.60, 0.0); _r_hip_pivot.add_child(_r_knee_pivot)
	var rsh := CapsuleMesh.new(); rsh.radius = 0.15; rsh.height = 1.55
	var r_shin := MeshInstance3D.new(); r_shin.mesh = rsh; r_shin.material_override = pants
	r_shin.position = Vector3(0.0, -0.775, 0.0); _r_knee_pivot.add_child(r_shin)
	var rsm := BoxMesh.new(); rsm.size = Vector3(0.22, 0.20, 0.50)
	var r_shoe := MeshInstance3D.new(); r_shoe.mesh = rsm; r_shoe.material_override = shoes
	r_shoe.position = Vector3(0.0, -1.55, 0.12); _r_knee_pivot.add_child(r_shoe)

# Bilinear sample of terrain height (feet) at arbitrary world (wx, wz).
func _sample_terrain_height(wx: float, wz: float) -> float:
	if _chunk_size <= 0.0 or _chunk_resolution <= 0:
		return 0.0
	var cx := int(floor(wx / _chunk_size))
	var cz := int(floor(wz / _chunk_size))
	var key := Vector2i(cx, cz)
	if not _terrain_heights.has(key):
		return 0.0
	var heights: PackedFloat32Array = _terrain_heights[key]
	var n := _chunk_resolution + 1
	if heights.size() < n * n:
		return 0.0
	var lx := wx - float(cx) * _chunk_size
	var lz := wz - float(cz) * _chunk_size
	var inv_step := float(_chunk_resolution) / _chunk_size
	var gx := clampi(int(lx * inv_step), 0, _chunk_resolution - 1)
	var gz := clampi(int(lz * inv_step), 0, _chunk_resolution - 1)
	var fx := clampf(lx * inv_step - float(gx), 0.0, 1.0)
	var fz := clampf(lz * inv_step - float(gz), 0.0, 1.0)
	var h00 := heights[gz       * n + gx    ]
	var h10 := heights[gz       * n + gx + 1]
	var h01 := heights[(gz + 1) * n + gx    ]
	var h11 := heights[(gz + 1) * n + gx + 1]
	return lerp(lerp(h00, h10, fx), lerp(h01, h11, fx), fz)

# Gravity + terrain following.  Called each frame after horizontal movement.
func _apply_terrain_physics(delta: float) -> void:
	# Stupidly-simple feet-vs-ground physics:
	# - If feet are below ground at (x,z): clamp to ground.
	# - Otherwise: integrate vertical velocity with gravity.
	var pos := _player_node.position
	var ground := _sample_terrain_height(pos.x, pos.z)
	if pos.y <= ground:
		_player_node.position.y = ground
		_vertical_velocity = 0.0
		_is_grounded = true
		return

	# Airborne: accelerate downward.
	_is_grounded = false
	_vertical_velocity -= GRAVITY_ACCEL * delta
	_player_node.position.y += _vertical_velocity * delta
	# Land if we crossed the ground this frame.
	pos = _player_node.position
	ground = _sample_terrain_height(pos.x, pos.z)
	if pos.y <= ground:
		_player_node.position.y = ground
		_vertical_velocity = 0.0
		_is_grounded = true

# Pose-animation driver.  sprint_scale: 1=walk  3=run  100=hyper-sprint.
func _update_human_pose(sprint_scale: float, is_moving: bool, delta: float) -> void:
	if _figure_root == null:
		return
	# Gait parameters by speed tier.
	var hip_amp: float; var knee_amp: float; var shoulder_amp: float
	var elbow_bend: float; var lean_ang: float
	if not is_moving:
		hip_amp = 0.0; knee_amp = 0.0; shoulder_amp = 0.0
		elbow_bend = deg_to_rad(5.0); lean_ang = 0.0
	elif sprint_scale <= 1.1:           # walking
		hip_amp = deg_to_rad(22.0); knee_amp = deg_to_rad(28.0)
		shoulder_amp = deg_to_rad(18.0); elbow_bend = deg_to_rad(15.0); lean_ang = deg_to_rad(2.0)
	elif sprint_scale <= 3.5:           # running
		hip_amp = deg_to_rad(38.0); knee_amp = deg_to_rad(50.0)
		shoulder_amp = deg_to_rad(38.0); elbow_bend = deg_to_rad(60.0); lean_ang = deg_to_rad(8.0)
	else:                               # sprinting / hyper
		hip_amp = deg_to_rad(55.0); knee_amp = deg_to_rad(70.0)
		shoulder_amp = deg_to_rad(55.0); elbow_bend = deg_to_rad(85.0); lean_ang = deg_to_rad(22.0)
	# Advance gait cycle phase.
	if is_moving:
		_anim_phase += clamp(sprint_scale * 0.5, 0.5, 5.0) * 2.0 * PI * delta
		if _anim_phase > 2.0 * PI:
			_anim_phase -= 2.0 * PI
	else:
		_anim_phase = move_toward(_anim_phase, 0.0, delta * 6.0)
	var s := sin(_anim_phase)
	var t := clampf(delta * 12.0, 0.0, 1.0)   # settle speed
	# Body lean (forward tilt around center of mass).
	_figure_root.rotation.x = lerp(_figure_root.rotation.x, lean_ang, t)
	# Hips: opposite phase each side.
	_l_hip_pivot.rotation.x = lerp(_l_hip_pivot.rotation.x,  s * hip_amp, t)
	_r_hip_pivot.rotation.x = lerp(_r_hip_pivot.rotation.x, -s * hip_amp, t)
	# Knees: bend backward at the rear of each swing (anatomical curl).
	_l_knee_pivot.rotation.x = lerp(_l_knee_pivot.rotation.x, -maxf(0.0, -s) * knee_amp, t)
	_r_knee_pivot.rotation.x = lerp(_r_knee_pivot.rotation.x, -maxf(0.0,  s) * knee_amp, t)
	# Shoulders: contralateral swing (left arm with right leg, and vice versa).
	_l_shoulder_pivot.rotation.x = lerp(_l_shoulder_pivot.rotation.x, -s * shoulder_amp, t)
	_r_shoulder_pivot.rotation.x = lerp(_r_shoulder_pivot.rotation.x,  s * shoulder_amp, t)
	# Elbows: constant forward curl that deepens with speed.
	_l_elbow_pivot.rotation.x = lerp(_l_elbow_pivot.rotation.x, elbow_bend, t)
	_r_elbow_pivot.rotation.x = lerp(_r_elbow_pivot.rotation.x, elbow_bend, t)

func _create_chunk(cx: int, cz: int, height_bytes: PackedByteArray, biome_bytes: PackedByteArray) -> void:
	# Store CPU-side height floats for terrain physics sampling.
	var heights_f32 := height_bytes.to_float32_array()
	_terrain_heights[Vector2i(cx, cz)] = heights_f32
	_ensure_lod_meshes()
	var n := _chunk_resolution + 1

	# Build padded heightmap texture for seam-free normals.
	var h_tex := _build_padded_height_texture(cx, cz, heights_f32)
	var b_img := Image.create_from_data(n, n, false, Image.FORMAT_RF, biome_bytes)
	var b_tex := ImageTexture.create_from_image(b_img)

	var mat := ShaderMaterial.new()
	mat.shader = _terrain_shader
	mat.set_shader_parameter("heightmap", h_tex)
	mat.set_shader_parameter("biomemap", b_tex)
	mat.set_shader_parameter("height_amplitude", _chunk_height_amplitude)
	mat.set_shader_parameter("chunk_size", _chunk_size)
	mat.set_shader_parameter("chunk_resolution", float(_chunk_resolution))
	mat.set_shader_parameter("heightmap_padded", 1.0)

	# Pick LOD mesh based on distance from player to chunk center.
	var cx_world := (float(cx) + 0.5) * _chunk_size
	var cz_world := (float(cz) + 0.5) * _chunk_size
	var dx := _player_node.position.x - cx_world
	var dz := _player_node.position.z - cz_world
	var lod := _get_lod_for_dist_sq(dx * dx + dz * dz)

	var chunk := MeshInstance3D.new()
	chunk.mesh = _lod_meshes[lod]
	chunk.material_override = mat
	chunk.position = Vector3(cx * _chunk_size, 0.0, cz * _chunk_size)

	# Tight per-chunk AABB from actual min/max heights — enables real frustum
	# culling.  The old code used ±height_amplitude (~20,000 ft) which made
	# every chunk appear always-visible to the frustum test.
	var h_min: float = INF
	var h_max: float = -INF
	for i in range(heights_f32.size()):
		var h := heights_f32[i]
		if h < h_min: h_min = h
		if h > h_max: h_max = h
	if h_min == INF:
		h_min = -_chunk_height_amplitude
		h_max = _chunk_height_amplitude
	var margin := 10.0
	chunk.custom_aabb = AABB(
		Vector3(0.0, h_min - margin, 0.0),
		Vector3(_chunk_size, (h_max - h_min) + 2.0 * margin, _chunk_size)
	)
	add_child(chunk)
	_chunks[Vector2i(cx, cz)] = chunk

	# When a chunk arrives, refresh its height borders and its neighbors' borders
	# (if present) to eliminate seams as data streams in.
	_refresh_heightmap_borders(cx, cz)


func _update_chunk(key: Vector2i, height_bytes: PackedByteArray, biome_bytes: PackedByteArray) -> void:
	var chunk: MeshInstance3D = _chunks[key]
	var n := _chunk_resolution + 1
	var heights_f32 := height_bytes.to_float32_array()
	_terrain_heights[key] = heights_f32
	var h_tex := _build_padded_height_texture(key.x, key.y, heights_f32)
	var b_img := Image.create_from_data(n, n, false, Image.FORMAT_RF, biome_bytes)
	var b_tex := ImageTexture.create_from_image(b_img)
	var mat := chunk.material_override as ShaderMaterial
	if mat:
		mat.set_shader_parameter("heightmap", h_tex)
		mat.set_shader_parameter("biomemap", b_tex)
	_refresh_heightmap_borders(key.x, key.y)


# ── Heightmap padding for seam-free normals ───────────────────────────────
func _build_padded_height_texture(cx: int, cz: int, heights_f32: PackedFloat32Array) -> Texture2D:
	var n := _chunk_resolution + 1
	var pn := n + 2
	var padded := PackedFloat32Array()
	padded.resize(pn * pn)

	# Neighbor arrays (optional)
	var left: PackedFloat32Array = _terrain_heights.get(Vector2i(cx - 1, cz), PackedFloat32Array())
	var right: PackedFloat32Array = _terrain_heights.get(Vector2i(cx + 1, cz), PackedFloat32Array())
	var down: PackedFloat32Array = _terrain_heights.get(Vector2i(cx, cz - 1), PackedFloat32Array())
	var up: PackedFloat32Array = _terrain_heights.get(Vector2i(cx, cz + 1), PackedFloat32Array())
	var has_left := left.size() == n * n
	var has_right := right.size() == n * n
	var has_down := down.size() == n * n
	var has_up := up.size() == n * n

	# Interior
	for z in range(n):
		var src_row := z * n
		var dst_row := (z + 1) * pn
		for x in range(n):
			padded[dst_row + (x + 1)] = heights_f32[src_row + x]

	# Left/right borders
	for z in range(n):
		var src_row := z * n
		var dst_row := (z + 1) * pn
		# Important: these border texels represent the height one grid step OUTSIDE
		# this chunk, not the shared edge height itself.
		# Example: for the x=0 edge vertex, central-difference needs x=-1, which is
		# neighbor-left's (n-2) column (one step inside that neighbor), not (n-1).
		padded[dst_row + 0] = left[src_row + (n - 2)] if has_left else heights_f32[src_row + 0]
		padded[dst_row + (pn - 1)] = right[src_row + 1] if has_right else heights_f32[src_row + (n - 1)]
	# Down/up borders
	for x in range(n):
		# Same off-by-one applies in Z: z=-1 comes from neighbor-down's (n-2) row,
		# and z=+1 beyond the top edge comes from neighbor-up's row 1.
		padded[0 * pn + (x + 1)] = down[(n - 2) * n + x] if has_down else heights_f32[0 * n + x]
		padded[(pn - 1) * pn + (x + 1)] = up[1 * n + x] if has_up else heights_f32[(n - 1) * n + x]

	# Corners: average adjacent borders (good enough for normals)
	padded[0 * pn + 0] = 0.5 * (padded[0 * pn + 1] + padded[1 * pn + 0])
	padded[0 * pn + (pn - 1)] = 0.5 * (padded[0 * pn + (pn - 2)] + padded[1 * pn + (pn - 1)])
	padded[(pn - 1) * pn + 0] = 0.5 * (padded[(pn - 1) * pn + 1] + padded[(pn - 2) * pn + 0])
	padded[(pn - 1) * pn + (pn - 1)] = 0.5 * (padded[(pn - 1) * pn + (pn - 2)] + padded[(pn - 2) * pn + (pn - 1)])

	var h_img := Image.create_from_data(pn, pn, false, Image.FORMAT_RF, padded.to_byte_array())
	return ImageTexture.create_from_image(h_img)


func _refresh_heightmap_borders(cx: int, cz: int) -> void:
	# Rebuild padded heightmaps for this chunk and its 4-neighbors if they exist.
	var keys := [
		Vector2i(cx, cz),
		Vector2i(cx - 1, cz),
		Vector2i(cx + 1, cz),
		Vector2i(cx, cz - 1),
		Vector2i(cx, cz + 1),
	]
	for k in keys:
		if not _chunks.has(k):
			continue
		var heights_f32: PackedFloat32Array = _terrain_heights.get(k, PackedFloat32Array())
		if heights_f32.size() != (_chunk_resolution + 1) * (_chunk_resolution + 1):
			continue
		var chunk: MeshInstance3D = _chunks[k]
		var mat := chunk.material_override as ShaderMaterial
		if mat:
			mat.set_shader_parameter("heightmap", _build_padded_height_texture(k.x, k.y, heights_f32))


# ── LOD mesh pools (built once per chunk_size, reused by every chunk) ────────
# Five resolution tiers: full, ½, ¼, ⅛, 1/16 of chunk_resolution.
# The vertex shader uses UV × chunk_resolution → texelFetch, so all tiers
# produce correct heights from the same heightmap texture.

func _get_lod_for_dist_sq(dist_sq: float) -> int:
	for i in range(LOD_DIST_MULTS.size()):
		var d := LOD_DIST_MULTS[i] * _chunk_size
		if dist_sq < d * d:
			return i
	return _lod_meshes.size() - 1

func _get_mega_lod_for_dist_sq(dist_sq: float) -> int:
	# Mega-chunks are always far away; use 3 tiers: 32, 16, 8 resolution.
	if _mega_lod_meshes.is_empty():
		return 0
	var thresholds : Array[float] = [40.0, 100.0]  # multiples of _mega_chunk_size
	for i in range(thresholds.size()):
		var d : float = thresholds[i] * _mega_chunk_size
		if dist_sq < d * d:
			return i
	return _mega_lod_meshes.size() - 1

func _update_chunk_lods() -> void:
	if _lod_meshes.is_empty():
		return
	var pos := _player_node.position
	var delta := pos - _lod_last_update_pos
	# Only re-evaluate when player has moved at least half a chunk.
	if delta.x * delta.x + delta.z * delta.z < _chunk_size * _chunk_size * 0.25:
		return
	_lod_last_update_pos = pos
	# Regular chunks
	for key in _chunks:
		var k: Vector2i = key
		var cx_world := (float(k.x) + 0.5) * _chunk_size
		var cz_world := (float(k.y) + 0.5) * _chunk_size
		var dx := pos.x - cx_world
		var dz := pos.z - cz_world
		var lod := _get_lod_for_dist_sq(dx * dx + dz * dz)
		var chunk: MeshInstance3D = _chunks[k]
		var target_mesh: ArrayMesh = _lod_meshes[lod]
		if chunk.mesh != target_mesh:
			chunk.mesh = target_mesh
	# Mega chunks
	if not _mega_lod_meshes.is_empty():
		for key in _mega_chunks:
			var k: Vector2i = key
			var cx_world := (float(k.x) + 0.5) * _mega_chunk_size
			var cz_world := (float(k.y) + 0.5) * _mega_chunk_size
			var dx := pos.x - cx_world
			var dz := pos.z - cz_world
			var lod := _get_mega_lod_for_dist_sq(dx * dx + dz * dz)
			var chunk: MeshInstance3D = _mega_chunks[k]
			var target_mesh: ArrayMesh = _mega_lod_meshes[lod]
			if chunk.mesh != target_mesh:
				chunk.mesh = target_mesh
	# Giga chunks
	if not _giga_lod_meshes.is_empty():
		for key in _giga_chunks:
			var k: Vector2i = key
			var cx_world := (float(k.x) + 0.5) * _giga_chunk_size
			var cz_world := (float(k.y) + 0.5) * _giga_chunk_size
			var dx := pos.x - cx_world
			var dz := pos.z - cz_world
			var lod := _get_giga_lod_for_dist_sq(dx * dx + dz * dz)
			var chunk: MeshInstance3D = _giga_chunks[k]
			var target_mesh: ArrayMesh = _giga_lod_meshes[lod]
			if chunk.mesh != target_mesh:
				chunk.mesh = target_mesh

func _ensure_lod_meshes() -> void:
	if _lod_meshes_chunk_size == _chunk_size and _lod_meshes.size() == 5:
		return
	_lod_meshes_chunk_size = _chunk_size
	_lod_meshes.clear()
	var base := _chunk_resolution
	var resolutions := [base, maxi(base / 2, 2), maxi(base / 4, 2), maxi(base / 8, 2), maxi(base / 16, 2)]
	for r in resolutions:
		_lod_meshes.append(_build_flat_mesh(r, _chunk_size))

func _ensure_mega_lod_meshes() -> void:
	if _mega_lod_meshes_size == _mega_chunk_size and _mega_lod_meshes.size() == 3:
		return
	_mega_lod_meshes_size = _mega_chunk_size
	_mega_lod_meshes.clear()
	var base := _chunk_resolution
	# 3 tiers for mega-chunks: 32, 16, 8 — they're always far away.
	var resolutions := [maxi(base / 4, 2), maxi(base / 8, 2), maxi(base / 16, 2)]
	for r in resolutions:
		_mega_lod_meshes.append(_build_flat_mesh(r, _mega_chunk_size))

func _get_giga_lod_for_dist_sq(dist_sq: float) -> int:
	if _giga_lod_meshes.is_empty():
		return 0
	var d : float = 2.5 * _giga_chunk_size
	if dist_sq < d * d:
		return 0
	return _giga_lod_meshes.size() - 1

func _ensure_giga_lod_meshes() -> void:
	if _giga_lod_meshes_size == _giga_chunk_size and _giga_lod_meshes.size() == 2:
		return
	_giga_lod_meshes_size = _giga_chunk_size
	_giga_lod_meshes.clear()
	var base := _chunk_resolution
	# 2 tiers for giga-chunks: 16, 8 — always very far away.
	var resolutions := [maxi(base / 8, 2), maxi(base / 16, 2)]
	for r in resolutions:
		_giga_lod_meshes.append(_build_flat_mesh(r, _giga_chunk_size))

func _build_flat_mesh(res: int, chunk_sz: float) -> ArrayMesh:
	var n := res + 1
	var step := chunk_sz / float(res)
	var vert_count := n * n
	var inv_res := 1.0 / float(res)

	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	vertices.resize(vert_count)
	uvs.resize(vert_count)
	normals.resize(vert_count)

	for z in range(n):
		var v := float(z) * inv_res
		var zs := float(z) * step
		for x in range(n):
			var idx := z * n + x
			vertices[idx] = Vector3(float(x) * step, 0.0, zs)
			uvs[idx] = Vector2(float(x) * inv_res, v)
			normals[idx] = Vector3(0.0, 1.0, 0.0)

	var indices := PackedInt32Array()
	indices.resize(res * res * 6)
	var ii := 0
	for z in range(res):
		for x in range(res):
			var i0 := z * n + x
			indices[ii] = i0;           ii += 1
			indices[ii] = i0 + 1;       ii += 1
			indices[ii] = i0 + n;       ii += 1
			indices[ii] = i0 + 1;       ii += 1
			indices[ii] = i0 + n + 1;   ii += 1
			indices[ii] = i0 + n;       ii += 1

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# ── Mega-chunk creation ──────────────────────────────────────────────────────
func _create_mega_chunk(cx: int, cz: int, height_bytes: PackedByteArray, biome_bytes: PackedByteArray) -> void:
	var heights_f32 := height_bytes.to_float32_array()
	_terrain_mega_heights[Vector2i(cx, cz)] = heights_f32
	_ensure_mega_lod_meshes()
	var n := _chunk_resolution + 1

	# Simple unpadded heightmap — mega-chunks are far away, seams invisible.
	var h_img := Image.create_from_data(n, n, false, Image.FORMAT_RF, height_bytes)
	var h_tex := ImageTexture.create_from_image(h_img)
	var b_img := Image.create_from_data(n, n, false, Image.FORMAT_RF, biome_bytes)
	var b_tex := ImageTexture.create_from_image(b_img)

	var mat := ShaderMaterial.new()
	mat.shader = _terrain_shader
	mat.set_shader_parameter("heightmap", h_tex)
	mat.set_shader_parameter("biomemap", b_tex)
	mat.set_shader_parameter("height_amplitude", _chunk_height_amplitude)
	mat.set_shader_parameter("chunk_size", _mega_chunk_size)
	mat.set_shader_parameter("chunk_resolution", float(_chunk_resolution))
	mat.set_shader_parameter("heightmap_padded", 0.0)

	# Pick LOD based on distance.
	var cx_world := (float(cx) + 0.5) * _mega_chunk_size
	var cz_world := (float(cz) + 0.5) * _mega_chunk_size
	var dx := _player_node.position.x - cx_world
	var dz := _player_node.position.z - cz_world
	var lod := _get_mega_lod_for_dist_sq(dx * dx + dz * dz)

	var chunk := MeshInstance3D.new()
	chunk.mesh = _mega_lod_meshes[lod]
	chunk.material_override = mat
	chunk.position = Vector3(cx * _mega_chunk_size, 0.0, cz * _mega_chunk_size)

	# Tight AABB from actual heights.
	var h_min: float = INF
	var h_max: float = -INF
	for i in range(heights_f32.size()):
		var h := heights_f32[i]
		if h < h_min: h_min = h
		if h > h_max: h_max = h
	if h_min == INF:
		h_min = -_chunk_height_amplitude
		h_max = _chunk_height_amplitude
	var margin := 50.0
	chunk.custom_aabb = AABB(
		Vector3(0.0, h_min - margin, 0.0),
		Vector3(_mega_chunk_size, (h_max - h_min) + 2.0 * margin, _mega_chunk_size)
	)
	add_child(chunk)
	_mega_chunks[Vector2i(cx, cz)] = chunk


# ── Giga-chunk creation ──────────────────────────────────────────────────────────────
func _create_giga_chunk(cx: int, cz: int, height_bytes: PackedByteArray, biome_bytes: PackedByteArray) -> void:
	var heights_f32 := height_bytes.to_float32_array()
	_terrain_giga_heights[Vector2i(cx, cz)] = heights_f32
	_ensure_giga_lod_meshes()
	var n := _chunk_resolution + 1

	var h_img := Image.create_from_data(n, n, false, Image.FORMAT_RF, height_bytes)
	var h_tex := ImageTexture.create_from_image(h_img)
	var b_img := Image.create_from_data(n, n, false, Image.FORMAT_RF, biome_bytes)
	var b_tex := ImageTexture.create_from_image(b_img)

	var mat := ShaderMaterial.new()
	mat.shader = _terrain_shader
	mat.set_shader_parameter("heightmap", h_tex)
	mat.set_shader_parameter("biomemap", b_tex)
	mat.set_shader_parameter("height_amplitude", _chunk_height_amplitude)
	mat.set_shader_parameter("chunk_size", _giga_chunk_size)
	mat.set_shader_parameter("chunk_resolution", float(_chunk_resolution))
	mat.set_shader_parameter("heightmap_padded", 0.0)

	var cx_world := (float(cx) + 0.5) * _giga_chunk_size
	var cz_world := (float(cz) + 0.5) * _giga_chunk_size
	var dx := _player_node.position.x - cx_world
	var dz := _player_node.position.z - cz_world
	var lod := _get_giga_lod_for_dist_sq(dx * dx + dz * dz)

	var chunk := MeshInstance3D.new()
	chunk.mesh = _giga_lod_meshes[lod]
	chunk.material_override = mat
	chunk.position = Vector3(cx * _giga_chunk_size, 0.0, cz * _giga_chunk_size)

	var h_min: float = INF
	var h_max: float = -INF
	for i in range(heights_f32.size()):
		var h := heights_f32[i]
		if h < h_min: h_min = h
		if h > h_max: h_max = h
	if h_min == INF:
		h_min = -_chunk_height_amplitude
		h_max = _chunk_height_amplitude
	var margin := 100.0
	chunk.custom_aabb = AABB(
		Vector3(0.0, h_min - margin, 0.0),
		Vector3(_giga_chunk_size, (h_max - h_min) + 2.0 * margin, _giga_chunk_size)
	)
	add_child(chunk)
	_giga_chunks[Vector2i(cx, cz)] = chunk
