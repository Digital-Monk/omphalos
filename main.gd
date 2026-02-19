extends Node3D

const NET_MAGIC: int = 0x4F4D5048 # 'OMPH'
const NET_VERSION: int = 1
const MSG_HELLO: int = 1
const MSG_CHUNK: int = 5
const MSG_WANT: int = 6   # client → server: demand list
const MSG_INFO: int = 7   # server → client: batch/terrain config
const MSG_BATCH_END: int = 8

@export var server_host: String = "127.0.0.1"
@export var server_tcp_port: int = 7778

@export var player_scale: float = 1.5
@export var turn_speed: float = 2.5

@export var camera_distance: float = 8.0
@export var camera_height: float = 4.0
@export var camera_look_ahead: float = 2.0
@export var camera_shoulder_offset: float = 1.2
@export var view_distance_chunks: int = 150
@export var camera_yaw_speed: float = 6.0
@export var mouse_sensitivity: float = 0.0035
@export var mouse_pitch_sensitivity: float = 0.0035
@export var min_camera_pitch: float = -PI * 0.5 + 0.01
@export var max_camera_pitch: float = PI * 0.5 - 0.01

var _tcp := StreamPeerTCP.new()
var _tcp_rx: PackedByteArray = PackedByteArray()
var _tcp_seq: int = 0
var _tcp_batch_n: int = 0
var _tcp_waiting_batch: bool = false
var _tcp_connected: bool = false
var _tcp_hello_sent: bool = false
var _tcp_reconnect_timer: float = 0.0
var _tcp_reconnect_interval: float = 1.0

var _player_node: Node3D
var _player_mesh: MeshInstance3D
var _camera: Camera3D
var _player_label: Label3D
var _facing_angle := 0.0
var _chunks: Dictionary = {}
# Chunks whose height data has arrived but whose mesh hasn't been built yet.
# We drain at most _max_mesh_builds_per_frame per _process() to avoid
# holding the main thread for a spike when dozens of packets arrive at once.
var _pending_chunks: Array = []
# Raw chunk payloads received from TCP. We decode a limited number per frame
# to avoid spikes when a batch arrives.
var _pending_chunk_packets: Array = []
var _max_chunk_decodes_per_frame: int = 256
var _max_mesh_builds_per_frame: int = 64
# All chunks whose data has arrived from the server (superset of _chunks).
# Used by the want list so we never re-request data we already have.
var _received_chunks: Dictionary = {}
# GPU-side terrain: one shared flat grid mesh + per-chunk heightmap texture + shader.
var _terrain_shader: Shader
var _shared_flat_mesh: ArrayMesh = null
var _shared_flat_mesh_res: int = -1
var _shared_flat_mesh_size: float = -1.0
var _want_outstanding: int = 0   # cached count of unreceived visible chunks
var _want_cursor: int = 0
var _want_offsets_r: int = -1
var _want_offsets: PackedInt32Array = PackedInt32Array() # packed (dx_u16<<16 | dz_u16), sorted by dist asc
var _water_plane: MeshInstance3D
var _sun_light: DirectionalLight3D
var _is_underwater: bool = false
var _chunk_size := 32.0
var _chunk_resolution := 32
var _chunk_height_amplitude := 8.0
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
	_tcp_waiting_batch = false
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
		_tcp_waiting_batch = false
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
			if payload.size() >= 8:
				var cx := _read_le_i32(payload, 0)
				var cz := _read_le_i32(payload, 4)
				_received_chunks[Vector2i(cx, cz)] = true
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
				_has_server = true
		elif msg_type == MSG_BATCH_END:
			_tcp_waiting_batch = false
			_packet_count += 1

func _apply_local_input(delta: float) -> void:
	var mf := _axis_from_keys(KEY_S, KEY_W)
	var mr := _axis_from_keys(KEY_D, KEY_A)
	var mu := _axis_from_keys(KEY_F, KEY_R)
	var sprint_scale := 1.0
	if (mf != 0.0 or mr != 0.0):
		if Input.is_key_pressed(KEY_CTRL):
			sprint_scale = 100.0
		elif Input.is_key_pressed(KEY_SHIFT):
			sprint_scale = 3.0
	var jump_pressed := Input.is_key_pressed(KEY_E)
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
	var dy := (mu + (1.0 if jump_pressed else 0.0))
	_player_node.position += Vector3(dx * spd, dy * spd, dz * spd)
	_player_label.text = "Player (" + str(int(_player_node.position.x)) + ", " + str(int(_player_node.position.z)) + ")"

func _maybe_send_want_batch_tcp() -> void:
	if not _tcp_connected or not _has_server:
		return
	if _tcp_waiting_batch:
		return
	_ensure_want_offsets()
	var pcx := int(floor(_player_node.position.x / _chunk_size))
	var pcz := int(floor(_player_node.position.z / _chunk_size))
	_want_outstanding = _count_missing_visible(pcx, pcz)
	if _want_outstanding <= 0:
		return

	var target_n := maxi(1, _tcp_batch_n)
	var send_list := PackedInt32Array()
	for packed32 in _want_offsets:
		if send_list.size() >= target_n:
			break
		var dx_u: int = (packed32 >> 16) & 0xFFFF
		var dz_u: int = packed32 & 0xFFFF
		var dx: int = dx_u - 0x10000 if dx_u >= 0x8000 else dx_u
		var dz: int = dz_u - 0x10000 if dz_u >= 0x8000 else dz_u
		if _received_chunks.has(Vector2i(pcx + dx, pcz + dz)):
			continue
		send_list.append(packed32)

	_tcp_seq = (_tcp_seq + 1) & 0x7FFFFFFF
	var req_id := _tcp_seq

	var spb := StreamPeerBuffer.new()
	spb.big_endian = false
	spb.put_u32(req_id)  # gen (mirrors existing WANT layout; not used by TCP server)
	spb.put_u8(0)        # part
	spb.put_u8(1)        # total parts
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
	_tcp_waiting_batch = true
	_tcp_send_packet(MSG_WANT, req_id, spb.data_array)

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

func _setup_scene() -> void:
	_player_node = Node3D.new()
	_player_node.scale = Vector3.ONE * player_scale
	add_child(_player_node)

	_player_mesh = MeshInstance3D.new()
	var body_mesh := CylinderMesh.new()
	body_mesh.top_radius = 0.0
	body_mesh.bottom_radius = 0.6
	body_mesh.height = 2.0
	_player_mesh.mesh = body_mesh
	_player_mesh.rotation = Vector3(PI / 2.0, 0.0, 0.0)
	_player_node.add_child(_player_mesh)

	var tip := MeshInstance3D.new()
	var tip_mesh := SphereMesh.new()
	tip_mesh.radius = 0.2
	tip_mesh.height = 0.4
	tip.mesh = tip_mesh
	var tip_material := StandardMaterial3D.new()
	tip_material.albedo_color = Color(1.0, 0.3, 0.2)
	tip.material_override = tip_material
	tip.position = Vector3(0, 0.0, -1.1)
	_player_mesh.add_child(tip)

	_player_label = Label3D.new()
	_player_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_player_label.text = "Player"
	_player_label.position = Vector3(0, 2.5, 0)
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

	# Sky background so the world isn't flat gray.
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.5, 0.7, 0.9)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.8, 1.0)
	env.ambient_light_energy = 0.5
	env_node.environment = env
	add_child(env_node)

	_camera = Camera3D.new()
	_camera.position = Vector3(0, camera_height, camera_distance)
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
	# Transparent water should not be backface culled.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_water_plane.material_override = mat
	add_child(_water_plane)


func _update_underwater_lighting(force: bool = false) -> void:
	var underwater_now := _player_node != null and _player_node.position.y < 0.0
	if not force and underwater_now == _is_underwater:
		return
	_is_underwater = underwater_now
	if _is_underwater:
		_sun_light.light_energy = 0.35
		_sun_light.light_color = Color(0.55, 0.75, 1.0)
	else:
		_sun_light.light_energy = 1.0
		_sun_light.light_color = Color(1.0, 1.0, 1.0)

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
	if payload.size() < 44 + height_count * 4:
		return {}

	# Slice the raw float32 height bytes — zero GDScript iteration.
	var height_bytes := payload.slice(44, 44 + height_count * 4)

	return {
		"cx": cx,
		"cz": cz,
		"chunk_size": chunk_size,
		"chunk_resolution": chunk_resolution,
		"height_amplitude": height_amplitude,
		"height_bytes": height_bytes,
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
	status += "  Waiting:" + ("1" if _tcp_waiting_batch else "0")
	status += "  Batches:" + str(_packet_count)
	status += "  Sent: " + str(_send_count) + "  LastSend(ms): " + str(_last_send_time_ms)
	status += "  Target: " + server_host + ":" + str(server_tcp_port)
	if not _has_server:
		status += "  [NO SERVER]"
	status += "  Built:" + str(_chunks.size()) + "  Queue:" + str(_pending_chunks.size()) + "  Want:" + str(_want_outstanding)
	status += "  RxQ:" + str(_pending_chunk_packets.size())
	_hud_label.text = pos_text + "  Facing: " + str(snapped(_facing_angle, 0.01)) + "  " + status

func _apply_chunk_message(payload: Dictionary) -> void:
	if payload.is_empty():
		return
	var cx := int(payload.get("cx", 0))
	var cz := int(payload.get("cz", 0))
	_chunk_size = float(payload.get("chunk_size", _chunk_size))
	_chunk_resolution = int(payload.get("chunk_resolution", _chunk_resolution))
	_chunk_height_amplitude = float(payload.get("height_amplitude", _chunk_height_amplitude))
	var key := Vector2i(cx, cz)
	# Mark received immediately so the want list stops requesting this chunk
	# even before the mesh is built from the pending queue.
	_received_chunks[key] = true
	# Skip if already built; don't rebuild static terrain.
	if _chunks.has(key):
		return
	# Queue for deferred mesh build — never build directly in the receive loop.
	_pending_chunks.push_back(payload.duplicate())

func _drain_chunk_queue() -> void:
	if _pending_chunks.is_empty():
		return

	# ── Priority sort: build nearest chunks first, drop out-of-range ones ──
	var pcx := int(floor(_player_node.position.x / _chunk_size))
	var pcz := int(floor(_player_node.position.z / _chunk_size))
	var r2 := view_distance_chunks * view_distance_chunks

	# Drop chunks that have moved outside the view distance.
	var kept: Array = []
	for p in _pending_chunks:
		var dx := int(p["cx"]) - pcx
		var dz := int(p["cz"]) - pcz
		if dx * dx + dz * dz <= r2:
			kept.push_back(p)
	_pending_chunks = kept

	# Sort remaining by distance ascending (nearest first).
	_pending_chunks.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var adx := int(a["cx"]) - pcx
		var adz := int(a["cz"]) - pcz
		var bdx := int(b["cx"]) - pcx
		var bdz := int(b["cz"]) - pcz
		return (adx * adx + adz * adz) < (bdx * bdx + bdz * bdz)
	)

	var budget_usec := 8000  # 8 ms — mesh build is now GPU-upload only
	var start := Time.get_ticks_usec()
	var built := 0
	while not _pending_chunks.is_empty() and built < _max_mesh_builds_per_frame:
		if built > 0 and (Time.get_ticks_usec() - start) >= budget_usec:
			break
		var payload: Dictionary = _pending_chunks.pop_front() as Dictionary
		var cx := int(payload.get("cx", 0))
		var cz := int(payload.get("cz", 0))
		var key := Vector2i(cx, cz)
		if _chunks.has(key):
			continue
		var height_bytes: PackedByteArray = payload.get("height_bytes", PackedByteArray())
		_create_chunk(cx, cz, height_bytes)
		built += 1

func _prune_chunks() -> void:
	var px := _player_node.position.x
	var pz := _player_node.position.z
	var center_x := int(floor(px / _chunk_size))
	var center_z := int(floor(pz / _chunk_size))
	for key in _chunks.keys():
		var k: Vector2i = key
		if abs(k.x - center_x) > view_distance_chunks or abs(k.y - center_z) > view_distance_chunks:
			var chunk: MeshInstance3D = _chunks[k]
			chunk.queue_free()
			_chunks.erase(k)
			# Also clear received flag so this chunk re-enters the want list
			# the next time it comes into view.
			_received_chunks.erase(k)

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

func _count_missing_visible(pcx: int, pcz: int) -> int:
	var missing := 0
	for packed32 in _want_offsets:
		var dx_u: int = (packed32 >> 16) & 0xFFFF
		var dz_u: int = packed32 & 0xFFFF
		var dx: int = dx_u - 0x10000 if dx_u >= 0x8000 else dx_u
		var dz: int = dz_u - 0x10000 if dz_u >= 0x8000 else dz_u
		if not _received_chunks.has(Vector2i(pcx + dx, pcz + dz)):
			missing += 1
	return missing

func _create_chunk(cx: int, cz: int, height_bytes: PackedByteArray) -> void:
	_ensure_shared_flat_mesh()
	var n := _chunk_resolution + 1

	# Build a single-channel float32 heightmap texture — no GDScript loops.
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RF, height_bytes)
	var tex := ImageTexture.create_from_image(img)

	var mat := ShaderMaterial.new()
	mat.shader = _terrain_shader
	mat.set_shader_parameter("heightmap", tex)
	mat.set_shader_parameter("height_amplitude", _chunk_height_amplitude)
	mat.set_shader_parameter("chunk_size", _chunk_size)
	mat.set_shader_parameter("chunk_resolution", float(_chunk_resolution))

	var chunk := MeshInstance3D.new()
	chunk.mesh = _shared_flat_mesh
	chunk.material_override = mat
	chunk.position = Vector3(cx * _chunk_size, 0.0, cz * _chunk_size)
	add_child(chunk)
	_chunks[Vector2i(cx, cz)] = chunk


func _update_chunk(key: Vector2i, height_bytes: PackedByteArray) -> void:
	var chunk: MeshInstance3D = _chunks[key]
	var n := _chunk_resolution + 1
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RF, height_bytes)
	var tex := ImageTexture.create_from_image(img)
	var mat := chunk.material_override as ShaderMaterial
	if mat:
		mat.set_shader_parameter("heightmap", tex)


# ── Shared flat grid (built once per resolution, reused by every chunk) ──────
func _ensure_shared_flat_mesh() -> void:
	if _shared_flat_mesh_res == _chunk_resolution and _shared_flat_mesh_size == _chunk_size:
		return
	_shared_flat_mesh_res = _chunk_resolution
	_shared_flat_mesh_size = _chunk_size

	var n := _chunk_resolution + 1
	var step := _chunk_size / float(_chunk_resolution)
	var vert_count := n * n
	var inv_res := 1.0 / float(_chunk_resolution)

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
	indices.resize(_chunk_resolution * _chunk_resolution * 6)
	var ii := 0
	for z in range(_chunk_resolution):
		for x in range(_chunk_resolution):
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

	_shared_flat_mesh = ArrayMesh.new()
	_shared_flat_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
