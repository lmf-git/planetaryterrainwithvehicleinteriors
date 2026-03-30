class_name PlanetTerrain
extends Node3D

## Smooth planetary terrain — NMS-style heightmap with domain-warped noise,
## per-tile LOD streaming, real-time crater destruction, and M-key orbit map.
##
## Surface sits at world y = 0 in the flat spawn zone.
## Terrain rises above y = 0 outside FLAT_RADIUS.

# ── Tile / vertex dimensions ──────────────────────────────────────────────────
const TILE_GRID      : int   = 16      # Quads per tile side at LOD0 → 17×17 vertices (fast build)
const VERT_SPACING   : float = 16.0    # World units between vertices at LOD0
const TILE_WORLD_SIZE: float = TILE_GRID * VERT_SPACING   # 256 world units

const MAX_HEIGHT     : float = 450.0   # Dramatic NMS-style elevation range
const PLANET_RADIUS  : float = 50000.0 # Very large planet — negligible local curvature
const WATER_LEVEL    : float = -5.0    # Sea surface: 5 units below sphere_y (PLANET_RADIUS + WATER_LEVEL)

# ── LOD ───────────────────────────────────────────────────────────────────────
const LOD_STEPS  : Array = [1,    2,     4,     8    ]   # Vertex stride per LOD
const LOD_RANGES : Array = [768.0, 1536.0, 3072.0, 6144.0]  # Max dist for each LOD
const UNLOAD_RANGE       : float = 7000.0

const HIGH_SPOT_THRESH : float = 40.0   # Height (world units) for "high-spot" bonus
const HIGH_SPOT_EXTEND : float = 1.6    # Range multiplier for high-spot tiles
const MAX_NEW_TILES    : int   = 24     # Tiles loaded per streaming tick
const UPDATE_INTERVAL  : float = 0.10

# ── Runtime state ─────────────────────────────────────────────────────────────
var tiles        : Dictionary = {}
var player_pos   : Vector3   = Vector3.ZERO
var update_timer : float     = 0.0

var terrain_material : StandardMaterial3D
var noise_warp  : FastNoiseLite
var noise_base  : FastNoiseLite
var noise_ridge : FastNoiseLite
var noise_detail: FastNoiseLite

# ── Map / orbit camera ────────────────────────────────────────────────────────
var map_mode        : bool     = false
var map_camera      : Camera3D
var map_orbit_yaw   : float    = 0.0
var map_orbit_pitch : float    = -60.0
var map_orbit_dist  : float    = 400.0
var map_pivot       : Vector3  = Vector3.ZERO
var map_dragging    : bool     = false

## Set by GameManager after dual_camera and local_player exist.
var main_camera_ref : Camera3D
var dual_camera_ref : DualCameraView


# ═════════════════════════════════════════════════════════════════════════════
# Inner class – one heightmap tile
# ═════════════════════════════════════════════════════════════════════════════
class HeightmapTile:
	var coord         : Vector2i
	var heights       : PackedFloat32Array   # (TILE_GRID+1)² heights
	var mesh_instance : MeshInstance3D
	var static_body   : StaticBody3D
	var current_lod   : int   = -1
	var max_height    : float = 0.0
	var dirty         : bool  = true
	var origin        : Vector3   # World-space XZ origin (Y always 0)

	func _init(c: Vector2i) -> void:
		coord  = c
		origin = Vector3(c.x * PlanetTerrain.TILE_WORLD_SIZE, 0.0,
						 c.y * PlanetTerrain.TILE_WORLD_SIZE)
		var n := PlanetTerrain.TILE_GRID + 1
		heights = PackedFloat32Array()
		heights.resize(n * n)
		heights.fill(0.0)

	func hidx(xi: int, zi: int) -> int:
		return zi * (PlanetTerrain.TILE_GRID + 1) + xi

	func get_h(xi: int, zi: int) -> float:
		var n := PlanetTerrain.TILE_GRID + 1
		xi = clampi(xi, 0, n - 1)
		zi = clampi(zi, 0, n - 1)
		return heights[hidx(xi, zi)]

	func set_h(xi: int, zi: int, h: float) -> void:
		var n := PlanetTerrain.TILE_GRID + 1
		if xi < 0 or xi >= n or zi < 0 or zi >= n:
			return
		heights[hidx(xi, zi)] = h
		dirty = true


# ═════════════════════════════════════════════════════════════════════════════
# Lifecycle
# ═════════════════════════════════════════════════════════════════════════════
func _ready() -> void:
	_setup_noise()
	_setup_material()
	_setup_map_camera()
	_create_water_sphere()


func _setup_noise() -> void:
	# All noises: frequency=1.0 — feature scale controlled entirely by coord scaling

	# Domain warp: used at two scales to create organic continental shapes
	noise_warp = FastNoiseLite.new()
	noise_warp.noise_type         = FastNoiseLite.TYPE_PERLIN
	noise_warp.seed               = 7
	noise_warp.frequency          = 1.0
	noise_warp.fractal_type       = FastNoiseLite.FRACTAL_FBM
	noise_warp.fractal_octaves    = 4
	noise_warp.fractal_lacunarity = 2.0
	noise_warp.fractal_gain       = 0.5

	# Continent: large-scale biome distribution — ocean / coast / plains / mountains
	noise_base = FastNoiseLite.new()
	noise_base.noise_type         = FastNoiseLite.TYPE_PERLIN
	noise_base.seed               = 42
	noise_base.frequency          = 1.0
	noise_base.fractal_type       = FastNoiseLite.FRACTAL_FBM
	noise_base.fractal_octaves    = 6
	noise_base.fractal_lacunarity = 2.0
	noise_base.fractal_gain       = 0.5

	# Ridge: knife-edge mountains using RIDGED fractal (output [0,1], peaks=1)
	noise_ridge = FastNoiseLite.new()
	noise_ridge.noise_type                = FastNoiseLite.TYPE_PERLIN
	noise_ridge.seed                      = 13
	noise_ridge.frequency                 = 1.0
	noise_ridge.fractal_type              = FastNoiseLite.FRACTAL_RIDGED
	noise_ridge.fractal_octaves           = 6
	noise_ridge.fractal_lacunarity        = 2.1
	noise_ridge.fractal_gain              = 0.5
	noise_ridge.fractal_weighted_strength = 0.7  # Pronounced inter-octave ridging

	# Detail: player-scale surface rocks, erosion bumps, grit
	noise_detail = FastNoiseLite.new()
	noise_detail.noise_type         = FastNoiseLite.TYPE_PERLIN
	noise_detail.seed               = 99
	noise_detail.frequency          = 1.0
	noise_detail.fractal_type       = FastNoiseLite.FRACTAL_FBM
	noise_detail.fractal_octaves    = 5
	noise_detail.fractal_lacunarity = 2.0
	noise_detail.fractal_gain       = 0.55


func _setup_material() -> void:
	terrain_material = StandardMaterial3D.new()
	terrain_material.vertex_color_use_as_albedo = true
	terrain_material.roughness    = 0.92
	terrain_material.metallic     = 0.02
	terrain_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	terrain_material.cull_mode    = BaseMaterial3D.CULL_BACK  # Back-face culled (normals point up)


func _setup_map_camera() -> void:
	map_camera         = Camera3D.new()
	map_camera.name    = "MapOrbitCamera"
	map_camera.fov     = 60.0
	map_camera.far     = 3000.0
	map_camera.current = false
	add_child(map_camera)


# ═════════════════════════════════════════════════════════════════════════════
# Per-frame
# ═════════════════════════════════════════════════════════════════════════════
func _process(delta: float) -> void:
	update_timer -= delta
	if update_timer <= 0.0:
		update_timer = UPDATE_INTERVAL
		_update_tiles()
	if map_mode:
		_update_map_camera()


func _input(event: InputEvent) -> void:
	# M key: toggle map mode
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_M:
			_toggle_map_mode()
			get_viewport().set_input_as_handled()
			return
		# Backtick: toggle wireframe view of the whole scene
		if event.keycode == KEY_QUOTELEFT:
			var vp := get_viewport()
			if vp.debug_draw == Viewport.DEBUG_DRAW_WIREFRAME:
				vp.debug_draw = Viewport.DEBUG_DRAW_DISABLED
			else:
				vp.debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
			get_viewport().set_input_as_handled()
			return

	# Right-click: carve terrain (FPS mode only)
	if not map_mode and event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_carve_terrain()

	# Map orbit controls
	if map_mode:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			match mb.button_index:
				MOUSE_BUTTON_LEFT:
					map_dragging = mb.pressed
				MOUSE_BUTTON_WHEEL_UP:
					map_orbit_dist = max(40.0, map_orbit_dist * 0.88)
				MOUSE_BUTTON_WHEEL_DOWN:
					map_orbit_dist = min(2000.0, map_orbit_dist * 1.14)
		elif event is InputEventMouseMotion and map_dragging:
			var mm := event as InputEventMouseMotion
			map_orbit_yaw   -= mm.relative.x * 0.25
			map_orbit_pitch  = clamp(map_orbit_pitch - mm.relative.y * 0.20, -88.0, -5.0)


# ═════════════════════════════════════════════════════════════════════════════
# Map / orbit camera
# ═════════════════════════════════════════════════════════════════════════════
func _toggle_map_mode() -> void:
	map_mode = not map_mode
	if map_mode:
		map_pivot = player_pos
		_update_map_camera()
		map_camera.current = true
		if is_instance_valid(dual_camera_ref):
			dual_camera_ref.map_mode_active = true
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	else:
		map_camera.current = false
		if is_instance_valid(dual_camera_ref):
			dual_camera_ref.map_mode_active = false
		if is_instance_valid(main_camera_ref):
			main_camera_ref.current = true
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _update_map_camera() -> void:
	var yaw   := deg_to_rad(map_orbit_yaw)
	var pitch := deg_to_rad(map_orbit_pitch)
	map_camera.global_position = map_pivot + Vector3(
		map_orbit_dist * cos(pitch) * sin(yaw),
		map_orbit_dist * -sin(pitch),
		map_orbit_dist * cos(pitch) * cos(yaw)
	)
	map_camera.look_at(map_pivot, Vector3.UP)


# ═════════════════════════════════════════════════════════════════════════════
## Returns true if the tile's world-space centre is inside (or near) the camera frustum.
## Falls back to true when no camera is available so off-screen tiles still load.
func _is_in_frustum(tile_world_center: Vector3) -> bool:
	if not is_instance_valid(main_camera_ref):
		return true
	var planes : Array[Plane] = main_camera_ref.get_frustum()
	var margin : float = TILE_WORLD_SIZE  # allow tiles one tile-width outside edge
	for plane in planes:
		if plane.distance_to(tile_world_center) < -margin:
			return false
	return true


# Tile streaming
# ═════════════════════════════════════════════════════════════════════════════
func _update_tiles() -> void:
	var px    := player_pos.x
	var pz    := player_pos.z
	var cx    := int(floor(px / TILE_WORLD_SIZE))
	var cz    := int(floor(pz / TILE_WORLD_SIZE))
	var max_r := int(ceil(UNLOAD_RANGE * HIGH_SPOT_EXTEND / TILE_WORLD_SIZE)) + 1

	var needed : Dictionary = {}

	for dz in range(-max_r, max_r + 1):
		for dx in range(-max_r, max_r + 1):
			var coord := Vector2i(cx + dx, cz + dz)
			var tc_x  := (coord.x + 0.5) * TILE_WORLD_SIZE
			var tc_z  := (coord.y + 0.5) * TILE_WORLD_SIZE
			var dist  := Vector2(px, pz).distance_to(Vector2(tc_x, tc_z))

			var extend := 1.0
			if coord in tiles:
				var t := tiles[coord] as HeightmapTile
				if t.max_height >= HIGH_SPOT_THRESH:
					extend = HIGH_SPOT_EXTEND

			if dist > UNLOAD_RANGE * extend:
				continue

			var req_lod := LOD_RANGES.size() - 1
			for li in range(LOD_RANGES.size()):
				if dist <= LOD_RANGES[li] * extend:
					req_lod = li
					break

			needed[coord] = req_lod

	# Unload far tiles
	var to_remove : Array = []
	for coord in tiles:
		if not coord in needed:
			to_remove.append(coord)
	for coord in to_remove:
		_unload_tile(coord)

	# LOD transitions for already-loaded tiles (fast: heights already computed)
	for coord in needed:
		if coord in tiles:
			var t    := tiles[coord] as HeightmapTile
			var rlod : int = needed[coord]
			if t.current_lod != rlod or t.dirty:
				_build_mesh(t, rlod)

	# New tile loads — throttled and sorted closest-first
	var to_load : Array = []
	for coord in needed:
		if not coord in tiles:
			to_load.append(coord)

	to_load.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var ca := Vector3((a.x + 0.5) * TILE_WORLD_SIZE, 0.0, (a.y + 0.5) * TILE_WORLD_SIZE)
		var cb := Vector3((b.x + 0.5) * TILE_WORLD_SIZE, 0.0, (b.y + 0.5) * TILE_WORLD_SIZE)
		var a_vis : int = 1 if _is_in_frustum(ca) else 0
		var b_vis : int = 1 if _is_in_frustum(cb) else 0
		if a_vis != b_vis:
			return a_vis > b_vis  # visible tiles first
		var da := Vector2(px, pz).distance_squared_to(Vector2(ca.x, ca.z))
		var db := Vector2(px, pz).distance_squared_to(Vector2(cb.x, cb.z))
		return da < db
	)

	var loaded := 0
	for coord in to_load:
		if loaded >= MAX_NEW_TILES:
			break
		_load_tile(coord, needed[coord])
		loaded += 1


func _load_tile(coord: Vector2i, lod: int) -> void:
	var t := HeightmapTile.new(coord)
	tiles[coord] = t
	_gen_heights(t)
	_build_mesh(t, lod)


func _unload_tile(coord: Vector2i) -> void:
	var t := tiles[coord] as HeightmapTile
	if is_instance_valid(t.mesh_instance):
		t.mesh_instance.queue_free()
	if is_instance_valid(t.static_body):
		t.static_body.queue_free()
	tiles.erase(coord)


# ═════════════════════════════════════════════════════════════════════════════
# Height generation  —  NMS-style: domain-warped FBM + ridge mountains
# ═════════════════════════════════════════════════════════════════════════════
func _gen_heights(t: HeightmapTile) -> void:
	var n  := TILE_GRID + 1
	var mh := 0.0
	for zi in range(n):
		for xi in range(n):
			var wx := t.origin.x + xi * VERT_SPACING
			var wz := t.origin.z + zi * VERT_SPACING
			var h  := _sample_height(wx, wz)
			t.heights[t.hidx(xi, zi)] = h
			if h > mh:
				mh = h
	t.max_height = mh
	t.dirty      = false


func _sample_height(wx: float, wz: float) -> float:
	# ── Spherical base ─────────────────────────────────────────────────────────
	var r2 := wx * wx + wz * wz
	if r2 >= PLANET_RADIUS * PLANET_RADIUS:
		return -PLANET_RADIUS
	var sphere_y : float = sqrt(PLANET_RADIUS * PLANET_RADIUS - r2) - PLANET_RADIUS

	# ── Domain warp: two scales ────────────────────────────────────────────────
	# Macro warp ~3000u — organic continental masses and ocean basin shapes
	const S_W1 := 0.00033
	var wx1 := wx + 250.0 * noise_warp.get_noise_2d(wx  * S_W1,        wz  * S_W1)
	var wz1 := wz + 250.0 * noise_warp.get_noise_2d(wx  * S_W1 + 31.7, wz  * S_W1 + 17.3)
	# Mid warp ~500u — local distortion of ridges and coastlines
	const S_W2 := 0.00200
	var wx2 := wx1 + 50.0 * noise_warp.get_noise_2d(wx1 * S_W2 + 100.0, wz1 * S_W2 + 200.0)
	var wz2 := wz1 + 50.0 * noise_warp.get_noise_2d(wx1 * S_W2 + 300.0, wz1 * S_W2 + 400.0)

	# ── Continent / biome map at ~3000u ────────────────────────────────────────
	# [-1, 1]: negative = ocean basin, zero = coastline, positive = land / mountains
	var continent := noise_base.get_noise_2d(wx1 * 0.00033, wz1 * 0.00033)

	# ── Rolling plains at ~700u ────────────────────────────────────────────────
	var plains := noise_base.get_noise_2d(wx2 * 0.00140 + 500.0, wz2 * 0.00140 + 900.0)
	plains = (plains + 1.0) * 0.5  # [0, 1]

	# ── Ridged mountains at ~400u (FRACTAL_RIDGED → peaks at 1.0) ─────────────
	var ridge := noise_ridge.get_noise_2d(wx2 * 0.00250, wz2 * 0.00250)
	ridge = clamp(ridge, 0.0, 1.0)
	ridge = sqrt(ridge) * ridge  # broadened base, sharpened tip

	# ── Thermal fractures at ~100u (cracks and crevices on mountain faces) ─────
	var fracture := noise_ridge.get_noise_2d(wx2 * 0.0100 + 700.0, wz2 * 0.0100 + 800.0)
	fracture = clamp(fracture, 0.0, 1.0) * fracture  # sharpen

	# ── Surface detail: rocks ~30u, grit ~10u ─────────────────────────────────
	var d1 := noise_detail.get_noise_2d(wx * 0.033, wz * 0.033) * 0.045
	var d2 := noise_detail.get_noise_2d(wx * 0.100 + 111.1, wz * 0.100 + 222.2) * 0.015

	# ── Biome masks ────────────────────────────────────────────────────────────
	# ocean_depth: 0 at coast (continent = -0.25), 1 at deep ocean (continent = -1)
	var ocean_depth   : float = clamp((-continent - 0.25) / 0.75, 0.0, 1.0)
	# mountain_mask: 0 at plains (continent ≤ 0.35), 1 at high mountains (continent ≥ 0.85)
	var mountain_mask : float = clamp((continent - 0.35) / 0.50, 0.0, 1.0)
	mountain_mask = mountain_mask * mountain_mask  # sharp onset

	# ── Height by biome (normalised — multiplied by MAX_HEIGHT at end) ─────────
	var ocean_h    : float = -(ocean_depth * 0.08 + 0.02)          # [−0.10, −0.02]
	var plains_h   : float = plains * 0.10 + d1 + d2               # [ 0.00,  0.11]
	var mountain_h : float = ridge * 0.76 + fracture * 0.10 + d1 * 1.5 + d2

	# ── Blend ocean → land ─────────────────────────────────────────────────────
	var land_blend : float = clamp((continent + 0.25) / 0.40, 0.0, 1.0)
	land_blend = land_blend * land_blend
	var land_h   : float = lerp(plains_h, mountain_h, mountain_mask)
	var combined : float = lerp(ocean_h, land_h, land_blend)

	# ── Spawn flat zone: y=0 within 1500u, smoothly fades to full terrain by 2000u ──
	# Both noise AND sphere_y are suppressed so the spawn pad is geometrically flat,
	# not just noise-free. Containers and ships land level regardless of planet curvature.
	var dist_from_origin : float = sqrt(wx * wx + wz * wz)
	var flat_blend : float = clamp((dist_from_origin - 1500.0) / 500.0, 0.0, 1.0)
	flat_blend = flat_blend * flat_blend

	# Allow negative (ocean floor below sea level), cap at 1.0 (flat mesa tops)
	return lerp(0.0, sphere_y, flat_blend) + clamp(combined, -0.12, 1.0) * MAX_HEIGHT * flat_blend


# ═════════════════════════════════════════════════════════════════════════════
# Mesh building
# ═════════════════════════════════════════════════════════════════════════════
func _build_mesh(t: HeightmapTile, lod: int) -> void:
	if is_instance_valid(t.mesh_instance):
		t.mesh_instance.queue_free()
		t.mesh_instance = null
	if is_instance_valid(t.static_body):
		t.static_body.queue_free()
		t.static_body = null

	var stride  : int   = LOD_STEPS[lod]
	@warning_ignore("integer_division")
	var n       : int   = TILE_GRID / stride        # Quads per side at this LOD
	var spacing : float = VERT_SPACING * stride
	var vc      : int   = (n + 1) * (n + 1)

	var verts   := PackedVector3Array()
	var norms   := PackedVector3Array()
	var colors  := PackedColorArray()
	var indices := PackedInt32Array()
	verts.resize(vc)
	norms.resize(vc)
	colors.resize(vc)

	# ── Vertex positions, normals, colours ───────────────────────────────────
	for zi in range(n + 1):
		for xi in range(n + 1):
			var idx := zi * (n + 1) + xi
			var h   := t.get_h(xi * stride, zi * stride)
			verts[idx] = Vector3(xi * spacing, h, zi * spacing)

			# Central-difference surface normal
			var h_l := t.get_h(max(0, xi - 1) * stride, zi * stride)
			var h_r := t.get_h(min(n, xi + 1) * stride, zi * stride)
			var h_d := t.get_h(xi * stride, max(0, zi - 1) * stride)
			var h_u := t.get_h(xi * stride, min(n, zi + 1) * stride)

			var sx : float = spacing * (2.0 if (xi > 0 and xi < n) else 1.0)
			var sz : float = spacing * (2.0 if (zi > 0 and zi < n) else 1.0)
			var nm  := Vector3(-(h_r - h_l) / sx, 1.0, -(h_u - h_d) / sz).normalized()
			norms[idx]  = nm
			colors[idx] = _terrain_color(h, nm)

	# ── Triangle indices (CCW from above → front normals point UP) ───────────
	for zi in range(n):
		for xi in range(n):
			var bi := zi * (n + 1) + xi
			indices.append_array([bi,     bi + 1,     bi + n + 1,
								  bi + 1, bi + n + 2, bi + n + 1])

	# ── Build ArrayMesh ───────────────────────────────────────────────────────
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR]  = colors
	arr[Mesh.ARRAY_INDEX]  = indices

	var amesh := ArrayMesh.new()
	amesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	amesh.surface_set_material(0, terrain_material)

	t.mesh_instance          = MeshInstance3D.new()
	t.mesh_instance.mesh     = amesh
	t.mesh_instance.position = t.origin
	t.mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(t.mesh_instance)

	# ── Collision (LOD0 + LOD1, trimesh) — LOD1 safety net prevents fall-through ─
	if lod <= 1:
		t.static_body          = StaticBody3D.new()
		t.static_body.position = t.origin
		add_child(t.static_body)

		var cv := PackedVector3Array()
		for zi in range(n):
			for xi in range(n):
				var v00 := verts[ zi      * (n + 1) + xi    ]
				var v10 := verts[ zi      * (n + 1) + xi + 1]
				var v01 := verts[(zi + 1) * (n + 1) + xi    ]
				var v11 := verts[(zi + 1) * (n + 1) + xi + 1]
				cv.append_array([v00, v10, v01, v10, v11, v01])

		var cs    := CollisionShape3D.new()
		var shape := ConcavePolygonShape3D.new()
		shape.backface_collision = true   # Collide from both sides as a safety net
		shape.set_faces(cv)
		cs.shape = shape
		t.static_body.add_child(cs)

	t.current_lod = lod
	t.dirty       = false


func _terrain_color(h: float, normal: Vector3) -> Color:
	var t     : float = clamp(h / MAX_HEIGHT, -0.15, 1.0)
	var slope : float = 1.0 - clamp(normal.dot(Vector3.UP), 0.0, 1.0)

	# Full biome colour ramp: deep ocean floor → coast → plains → peaks
	var hc : Color
	if t < -0.04:
		hc = Color(0.08, 0.12, 0.22)                                                        # Deep ocean floor
	elif t < 0.0:
		hc = Color(0.08, 0.12, 0.22).lerp(Color(0.18, 0.18, 0.16), (t + 0.04) / 0.04)    # Shallow floor
	elif t < 0.06:
		hc = Color(0.18, 0.18, 0.16).lerp(Color(0.48, 0.38, 0.22), t / 0.06)              # Sandy coast
	elif t < 0.25:
		hc = Color(0.48, 0.38, 0.22).lerp(Color(0.42, 0.30, 0.16), (t - 0.06) / 0.19)    # Low rock
	elif t < 0.55:
		hc = Color(0.42, 0.30, 0.16).lerp(Color(0.68, 0.54, 0.36), (t - 0.25) / 0.30)    # Mid rock
	else:
		hc = Color(0.68, 0.54, 0.36).lerp(Color(0.80, 0.74, 0.62), (t - 0.55) / 0.45)    # Pale stone peaks

	var cliff := Color(0.38, 0.34, 0.30)
	var steep : float = clamp((slope - 0.25) / 0.40, 0.0, 1.0)
	return hc.lerp(cliff, steep * 0.65)


# ═════════════════════════════════════════════════════════════════════════════
# Water sphere — transparent globe at sea level (PLANET_RADIUS + WATER_LEVEL)
# Ocean biome terrain dips below sphere_y, making water visible there.
# ═════════════════════════════════════════════════════════════════════════════
func _create_water_sphere() -> void:
	var radius := PLANET_RADIUS + WATER_LEVEL  # 11995.0

	var sphere := SphereMesh.new()
	sphere.radius          = radius
	sphere.height          = radius * 2.0
	sphere.radial_segments = 96
	sphere.rings           = 64

	var mat := StandardMaterial3D.new()
	mat.albedo_color    = Color(0.06, 0.22, 0.52, 0.70)
	mat.transparency    = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness       = 0.04
	mat.metallic        = 0.15
	mat.cull_mode       = BaseMaterial3D.CULL_BACK  # Outer face visible from land

	var mi := MeshInstance3D.new()
	mi.name              = "WaterSphere"
	mi.mesh              = sphere
	mi.material_override = mat
	mi.position          = Vector3(0.0, -PLANET_RADIUS, 0.0)
	mi.cast_shadow       = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


# ═════════════════════════════════════════════════════════════════════════════
# Terrain destruction — smooth Gaussian crater
# ═════════════════════════════════════════════════════════════════════════════
func _carve_terrain() -> void:
	if not is_instance_valid(main_camera_ref):
		return

	var from := main_camera_ref.global_position
	var fwd  := -main_camera_ref.global_transform.basis.z
	var to   := from + fwd * 30.0

	var ss  := get_world_3d().direct_space_state
	var qry := PhysicsRayQueryParameters3D.create(from, to)
	var hit := ss.intersect_ray(qry)
	if hit.is_empty():
		return

	var hp     : Vector3 = hit["position"]
	var cr     := 5.0     # Crater radius (world units)
	var depth  := 4.5     # Max carve depth

	var dirty  : Dictionary = {}
	var tile_r := int(ceil(cr / TILE_WORLD_SIZE)) + 1
	var btc    := Vector2i(int(floor(hp.x / TILE_WORLD_SIZE)),
						   int(floor(hp.z / TILE_WORLD_SIZE)))

	for dtz in range(-tile_r, tile_r + 1):
		for dtx in range(-tile_r, tile_r + 1):
			var tc := Vector2i(btc.x + dtx, btc.y + dtz)
			if not tc in tiles:
				continue
			var tile := tiles[tc] as HeightmapTile
			var ng   := TILE_GRID + 1
			for zi in range(ng):
				for xi in range(ng):
					var vx  := tile.origin.x + xi * VERT_SPACING
					var vz  := tile.origin.z + zi * VERT_SPACING
					var d   := Vector2(vx - hp.x, vz - hp.z).length()
					if d < cr:
						var f := 1.0 - d / cr
						tile.heights[tile.hidx(xi, zi)] -= f * f * depth
						dirty[tc] = true

	for tc in dirty:
		var tile := tiles[tc] as HeightmapTile
		if tile.current_lod == 0:
			_build_mesh(tile, 0)
