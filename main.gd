extends Node3D

@export var server_host: String = "127.0.0.1"
@export var server_port: int = 7777
@export var send_hz: int = 20

@export var player_scale: float = 1.5
@export var turn_speed: float = 2.5

@export var camera_distance: float = 8.0
@export var camera_height: float = 4.0
@export var camera_look_ahead: float = 2.0
@export var camera_shoulder_offset: float = 1.2
@export var view_distance_chunks: int = 3
@export var camera_yaw_speed: float = 6.0

var _udp := PacketPeerUDP.new()
var _seq := 0
var _send_accumulator := 0.0
var _last_state: Dictionary = {}

var _player_node: Node3D
var _player_mesh: MeshInstance3D
var _camera: Camera3D
var _player_label: Label3D
var _facing_angle := 0.0
var _chunks: Dictionary = {}
var _chunk_size := 32.0
var _chunk_resolution := 32
var _hud_layer: CanvasLayer
var _hud_label: Label
var _packet_count := 0
var _last_server_time_ms := 0
var _send_count := 0
var _last_send_time_ms := 0
var _local_port := 0
var _has_server := false

func _ready() -> void:
	_setup_scene()
	_connect_udp()
	_send_message("hello", {})

func _process(delta: float) -> void:
	_update_facing(delta)
	_send_accumulator += delta
	var send_interval: float = 1.0 / float(max(1, send_hz))
	if _send_accumulator >= send_interval:
		_send_accumulator = 0.0
		_send_input()
		_send_message("ping", {})
		if not _has_server:
			_send_message("hello", {})

	_poll_udp()
	_apply_state()
	_update_hud()

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

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, 30, 0)
	add_child(light)

	_camera = Camera3D.new()
	_camera.position = Vector3(0, camera_height, camera_distance)
	_camera.look_at(Vector3.ZERO, Vector3.UP)
	add_child(_camera)

func _update_facing(delta: float) -> void:
	var turn_input := Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left")
	if turn_input != 0.0:
		_facing_angle -= turn_input * turn_speed * delta

func _connect_udp() -> void:
	_udp.bind(0)
	_udp.connect_to_host(server_host, server_port)
	_local_port = _udp.get_local_port()


func _angle_diff(a: float, b: float) -> float:
	var TAU: float = PI * 2.0
	var d: float = a - b
	while d > PI:
		d -= TAU
	while d < -PI:
		d += TAU
	return d

func _send_message(msg_type: String, payload: Dictionary) -> void:
	_seq += 1
	var message := {
		"type": msg_type,
		"seq": _seq,
		"payload": payload,
	}
	var json_text := JSON.stringify(message)
	_udp.put_packet(json_text.to_utf8_buffer())
	_send_count += 1
	_last_send_time_ms = Time.get_ticks_msec()

func _send_input() -> void:
	var move_input := Input.get_action_strength("ui_up") - Input.get_action_strength("ui_down")
	var turn_input := Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left")
	var payload := {
		"move": move_input,
		"turn": turn_input,
	}
	_send_message("input", payload)

func _poll_udp() -> void:
	# UDP concerns: packets can be lost/duplicated/out-of-order. We process
	# the latest valid state and ignore missing frames gracefully.
	while _udp.get_available_packet_count() > 0:
		var packet := _udp.get_packet()
		var text := packet.get_string_from_utf8()
		var parsed: Variant = JSON.parse_string(text)
		if typeof(parsed) != TYPE_DICTIONARY:
			continue
		var msg: Dictionary = parsed as Dictionary
		var msg_type: String = str(msg.get("type", ""))
		if msg_type == "state":
			var payload: Dictionary = msg.get("payload", {}) as Dictionary
			_last_state = payload
			_packet_count += 1
			_last_server_time_ms = int(payload.get("server_time_ms", 0))
			_has_server = true
			var terrain: Dictionary = payload.get("terrain", {}) as Dictionary
			if not terrain.is_empty():
				_chunk_size = float(terrain.get("chunk_size", _chunk_size))
				_chunk_resolution = int(terrain.get("chunk_resolution", _chunk_resolution))
				view_distance_chunks = int(terrain.get("view_distance_chunks", view_distance_chunks))
		elif msg_type == "chunk":
			var payload: Dictionary = msg.get("payload", {}) as Dictionary
			_apply_chunk_message(payload)

func _apply_state() -> void:
	if _last_state.is_empty():
		return
	var player: Dictionary = _last_state.get("player", {}) as Dictionary
	var px := float(player.get("x", 0))
	var py := float(player.get("y", 0))
	var pz := float(player.get("z", 0))
	_facing_angle = float(player.get("facing", _facing_angle))
	_player_node.position = Vector3(px, py, pz)
	_player_node.rotation = Vector3(0.0, _facing_angle, 0.0)
	_player_label.text = "Player (" + str(int(px)) + ", " + str(int(pz)) + ")"

	_update_chunks_from_state()
	_update_camera()

func _update_camera() -> void:
	var player_pos: Vector3 = _player_node.position

	# Compute flat vector from camera to player and desired yaw
	var cam_pos: Vector3 = _camera.global_transform.origin
	var to_player: Vector3 = player_pos - cam_pos
	var to_player_flat: Vector3 = Vector3(to_player.x, 0.0, to_player.z)
	if to_player_flat.length() > 0.0001:
		var desired_yaw: float = atan2(to_player_flat.x, to_player_flat.z)

		var current_yaw: float = _camera.rotation.y
		var diff: float = _angle_diff(desired_yaw, current_yaw)

		# Rotate only up to camera_yaw_speed * frame_delta to avoid instant flips
		var max_step: float = camera_yaw_speed * get_process_delta_time()
		var step: float = diff
		if abs(diff) > max_step:
			step = sign(diff) * max_step
		_camera.rotate_y(step)

	# After yawing, compute forward and place camera at desired distance
	var cam_forward: Vector3 = -_camera.global_transform.basis.z.normalized()
	var desired_pos: Vector3 = player_pos - cam_forward * camera_distance
	desired_pos.y = player_pos.y + camera_height

	# Apply shoulder offset relative to current camera right vector
	var cam_right: Vector3 = _camera.global_transform.basis.x.normalized()
	desired_pos += cam_right * camera_shoulder_offset

	# Place camera instantly at desired position and look at player
	_camera.global_transform = Transform3D(_camera.global_transform.basis, desired_pos)
	_camera.look_at(player_pos, Vector3.UP)

func _update_hud() -> void:
	var pos_text := "Pos: (0, 0, 0)"
	if not _last_state.is_empty():
		var player: Dictionary = _last_state.get("player", {}) as Dictionary
		var px := int(float(player.get("x", 0)))
		var py := int(float(player.get("y", 0)))
		var pz := int(float(player.get("z", 0)))
		pos_text = "Pos: (" + str(px) + ", " + str(py) + ", " + str(pz) + ")"
	var status := "Packets: " + str(_packet_count) + "  Server: " + str(_last_server_time_ms)
	status += "  Sent: " + str(_send_count) + "  LastSend(ms): " + str(_last_send_time_ms)
	status += "  LocalPort: " + str(_local_port) + "  Target: " + server_host + ":" + str(server_port)
	if not _has_server:
		status += "  [NO SERVER]"
	_hud_label.text = pos_text + "  Facing: " + str(snapped(_facing_angle, 0.01)) + "  " + status

func _update_chunks_from_state() -> void:
	_prune_chunks()

func _apply_chunk_message(payload: Dictionary) -> void:
	if payload.is_empty():
		return
	var cx := int(payload.get("cx", 0))
	var cz := int(payload.get("cz", 0))
	_chunk_size = float(payload.get("chunk_size", _chunk_size))
	_chunk_resolution = int(payload.get("chunk_resolution", _chunk_resolution))
	var heights: Array = payload.get("heights", []) as Array
	var key := Vector2i(cx, cz)
	if not _chunks.has(key):
		_create_chunk(cx, cz, heights)
	else:
		_update_chunk(key, heights)

func _prune_chunks() -> void:
	if _last_state.is_empty():
		return
	var player: Dictionary = _last_state.get("player", {}) as Dictionary
	var px := float(player.get("x", 0))
	var pz := float(player.get("z", 0))
	var center_x := int(floor(px / _chunk_size))
	var center_z := int(floor(pz / _chunk_size))
	for key in _chunks.keys():
		var k: Vector2i = key
		if abs(k.x - center_x) > view_distance_chunks or abs(k.y - center_z) > view_distance_chunks:
			var chunk: MeshInstance3D = _chunks[k]
			chunk.queue_free()
			_chunks.erase(k)

func _create_chunk(cx: int, cz: int, heights: Array) -> void:
	var mesh := _build_chunk_mesh(heights)
	var chunk := MeshInstance3D.new()
	chunk.mesh = mesh
	chunk.position = Vector3(cx * _chunk_size, 0.0, cz * _chunk_size)
	add_child(chunk)
	_chunks[Vector2i(cx, cz)] = chunk

func _update_chunk(key: Vector2i, heights: Array) -> void:
	var chunk: MeshInstance3D = _chunks[key]
	chunk.mesh = _build_chunk_mesh(heights)

func _build_chunk_mesh(heights: Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	var step := _chunk_size / float(_chunk_resolution)
	var vert_count := (_chunk_resolution + 1) * (_chunk_resolution + 1)
	vertices.resize(vert_count)
	normals.resize(vert_count)
	uvs.resize(vert_count)
	colors.resize(vert_count)

	var min_h: float = INF
	var max_h: float = -INF
	for h in heights:
		var hf := float(h)
		if hf < min_h:
			min_h = hf
		if hf > max_h:
			max_h = hf
	var height_range: float = max(0.001, float(max_h - min_h))

	for z in range(_chunk_resolution + 1):
		for x in range(_chunk_resolution + 1):
			var idx := z * (_chunk_resolution + 1) + x
			var height := 0.0
			if idx < heights.size():
				height = float(heights[idx])
			vertices[idx] = Vector3(x * step, height, z * step)
			uvs[idx] = Vector2(float(x) / float(_chunk_resolution), float(z) / float(_chunk_resolution))
			var t: float = (height - min_h) / height_range
			colors[idx] = Color(0.1 + 0.2 * t, 0.3 + 0.5 * t, 0.1 + 0.2 * t)

			var h_l := height
			var h_r := height
			var h_d := height
			var h_u := height
			if x > 0:
				h_l = float(heights[idx - 1])
			if x < _chunk_resolution:
				h_r = float(heights[idx + 1])
			if z > 0:
				h_d = float(heights[idx - (_chunk_resolution + 1)])
			if z < _chunk_resolution:
				h_u = float(heights[idx + (_chunk_resolution + 1)])
			var normal := Vector3(h_l - h_r, 2.0 * step, h_d - h_u).normalized()
			normals[idx] = normal

	for z in range(_chunk_resolution):
		for x in range(_chunk_resolution):
			var i0 := z * (_chunk_resolution + 1) + x
			var i1 := i0 + 1
			var i2 := i0 + (_chunk_resolution + 1)
			var i3 := i2 + 1
			indices.append(i0)
			indices.append(i1)
			indices.append(i2)
			indices.append(i1)
			indices.append(i3)
			indices.append(i2)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.2, 0.35, 0.25)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.vertex_color_use_as_albedo = true
	mesh.surface_set_material(0, material)
	return mesh
