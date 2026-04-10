class_name CityGenerator
extends Node3D

## Procedural block-based city and town generator.
## Cities are laid out on a grid of blocks separated by roads and pavements.
## Airports (where present) are placed at one edge of the city; the runway
## extends outward from that edge with no overlap with the building blocks.
## Terrain around each city is flattened by registering zones with PlanetTerrain.

# ── City placement ────────────────────────────────────────────────────────────
@export var num_cities     : int   = 6
@export var min_dist       : float = 2000.0   # Distance from world origin (spawn)
@export var max_dist       : float = 7000.0
@export var airport_chance : float = 0.35     # Fraction of cities that get airports

const CITY_SEED   : int = 31337
const LAYOUT_SEED : int = 98765

# ── Block grid ────────────────────────────────────────────────────────────────
const BLOCK_SIZE : float = 50.0   # City block footprint (square, world units)
const ROAD_W     : float = 10.0   # Road width kerb-to-kerb
const CURB_W     : float = 2.0    # Pavement/sidewalk width on each side of road
const CURB_H     : float = 0.25   # Raised kerb height (visual)
const MIN_BLOCKS : int   = 3      # Minimum blocks per axis
const MAX_BLOCKS : int   = 7      # Maximum blocks per axis

# ── Buildings ─────────────────────────────────────────────────────────────────
const BUILD_MIN_W : float = 7.0
const BUILD_MAX_W : float = 17.0
const BUILD_MIN_H : float = 5.0
const BUILD_MAX_H : float = 42.0
const BUILD_GAP   : float = 2.0   # Minimum gap between buildings in a slot

# ── Airport runway ────────────────────────────────────────────────────────────
# The airport sits on ONE edge of the city. The runway is entirely outside the
# city block footprint, parallel to that edge and connected by a short apron.
const RUNWAY_W    : float = 22.0
const RUNWAY_L    : float = 600.0
const RUNWAY_H    : float = 0.15   # Slab thickness
const APRON_DEPTH : float = 30.0   # Taxiway gap between city edge and runway

# ── Terrain flat zones (registered with PlanetTerrain) ───────────────────────
# Larger radii to ensure the runway area (outside the city) is also flat.
const FLAT_INNER : float = 400.0   # Fully flat core (covers city + immediate apron)
const FLAT_OUTER : float = 900.0   # Blends back to natural terrain beyond here

# ── Runtime ───────────────────────────────────────────────────────────────────
var _terrain : PlanetTerrain
var _cities  : Array = []   # {cx, cz, has_airport}

var _mat_road     : StandardMaterial3D
var _mat_pavement : StandardMaterial3D
var _mat_runway   : StandardMaterial3D
var _mat_marking  : StandardMaterial3D

var _bcolors : Array[Color] = [
	Color(0.85, 0.85, 0.88),   # White concrete
	Color(0.28, 0.28, 0.32),   # Dark glass
	Color(0.62, 0.52, 0.42),   # Brick
	Color(0.72, 0.80, 0.88),   # Glass blue
	Color(0.52, 0.60, 0.52),   # Tinted concrete
	Color(0.80, 0.72, 0.60),   # Sandstone
	Color(0.42, 0.42, 0.50),   # Slate
	Color(0.88, 0.78, 0.66),   # Beige
]


## Called by GameManager immediately after PlanetTerrain is created.
func setup(terrain: PlanetTerrain) -> void:
	_terrain = terrain
	_init_materials()
	_pick_locations()
	terrain.set_city_flat_zones(_flat_zone_data())
	call_deferred("_build_all")


func _init_materials() -> void:
	_mat_road     = _solid_mat(Color(0.18, 0.18, 0.20), 0.95)
	_mat_pavement = _solid_mat(Color(0.70, 0.66, 0.60), 0.90)
	_mat_runway   = _solid_mat(Color(0.28, 0.28, 0.30), 0.93)
	_mat_marking  = _solid_mat(Color(0.96, 0.92, 0.60), 0.85)


func _solid_mat(col: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness    = rough
	return m


func _pick_locations() -> void:
	_cities.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = CITY_SEED
	for _i in range(num_cities):
		for _attempt in range(30):
			var angle := rng.randf() * TAU
			var dist  := rng.randf_range(min_dist, max_dist)
			var pos   := Vector2(cos(angle) * dist, sin(angle) * dist)
			var ok    := true
			for c in _cities:
				if pos.distance_to(Vector2(c.cx, c.cz)) < FLAT_OUTER * 2.1:
					ok = false
					break
			if ok:
				_cities.append({cx = pos.x, cz = pos.y,
					has_airport = rng.randf() < airport_chance})
				break


func _flat_zone_data() -> Array:
	var out : Array = []
	for c in _cities:
		out.append([c.cx, c.cz, FLAT_INNER, FLAT_OUTER])
	return out


func _build_all() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = LAYOUT_SEED
	for c in _cities:
		var gy := _terrain.sample_height_at(c.cx, c.cz)
		_build_city(c.cx, c.cz, gy, c.has_airport, rng)


# ═════════════════════════════════════════════════════════════════════════════
# City layout
# ═════════════════════════════════════════════════════════════════════════════
func _build_city(cx: float, cz: float, gy: float,
				 has_airport: bool, rng: RandomNumberGenerator) -> void:
	var bx := rng.randi_range(MIN_BLOCKS, MAX_BLOCKS)
	var bz := rng.randi_range(MIN_BLOCKS, MAX_BLOCKS)
	# Total footprint
	var tw := float(bx) * BLOCK_SIZE + float(bx + 1) * ROAD_W
	var td := float(bz) * BLOCK_SIZE + float(bz + 1) * ROAD_W

	# Root node: origin at bottom-left corner of city at ground level
	var root := Node3D.new()
	root.name = "City_%d_%d" % [int(cx), int(cz)]
	add_child(root)
	root.global_position = Vector3(cx - tw * 0.5, gy, cz - td * 0.5)

	# Airport runway placed FIRST so buildings sit over/across it
	if has_airport:
		_build_airport(root, tw, td, rng)

	# Road grid with pavements
	_build_roads(root, bx, bz, tw, td)

	# Buildings on each block
	for row in range(bz):
		for col in range(bx):
			var lx := ROAD_W + float(col) * (BLOCK_SIZE + ROAD_W)
			var lz := ROAD_W + float(row) * (BLOCK_SIZE + ROAD_W)
			_build_block(root, lx, lz, rng)


# ═════════════════════════════════════════════════════════════════════════════
# Airport  –  placed at one edge of the city, runway entirely outside blocks
# ═════════════════════════════════════════════════════════════════════════════
func _build_airport(root: Node3D, tw: float, td: float,
					rng: RandomNumberGenerator) -> void:
	# 0 = +Z edge (north), 1 = -Z edge (south), 2 = +X edge (east), 3 = -X edge (west)
	var edge := rng.randi() % 4

	# Runway and apron run parallel to the chosen city edge.
	# The runway centre is positioned just outside the city footprint.
	match edge:
		0:  # North (+Z) – runway runs E-W beyond the +Z edge
			var rz := td + APRON_DEPTH + RUNWAY_W * 0.5
			_add_apron(root, Vector3(tw * 0.5, RUNWAY_H * 0.5, td + APRON_DEPTH * 0.5),
					   Vector3(RUNWAY_W * 1.5, RUNWAY_H, APRON_DEPTH))
			_add_box(root, Vector3(tw * 0.5, RUNWAY_H * 0.5, rz),
					 Vector3(RUNWAY_L, RUNWAY_H, RUNWAY_W), _mat_runway, true)
			_runway_markings_x(root, tw * 0.5, rz)

		1:  # South (-Z) – runway runs E-W beyond the -Z edge
			var rz := -(APRON_DEPTH + RUNWAY_W * 0.5)
			_add_apron(root, Vector3(tw * 0.5, RUNWAY_H * 0.5, -APRON_DEPTH * 0.5),
					   Vector3(RUNWAY_W * 1.5, RUNWAY_H, APRON_DEPTH))
			_add_box(root, Vector3(tw * 0.5, RUNWAY_H * 0.5, rz),
					 Vector3(RUNWAY_L, RUNWAY_H, RUNWAY_W), _mat_runway, true)
			_runway_markings_x(root, tw * 0.5, rz)

		2:  # East (+X) – runway runs N-S beyond the +X edge
			var rx := tw + APRON_DEPTH + RUNWAY_W * 0.5
			_add_apron(root, Vector3(tw + APRON_DEPTH * 0.5, RUNWAY_H * 0.5, td * 0.5),
					   Vector3(APRON_DEPTH, RUNWAY_H, RUNWAY_W * 1.5))
			_add_box(root, Vector3(rx, RUNWAY_H * 0.5, td * 0.5),
					 Vector3(RUNWAY_W, RUNWAY_H, RUNWAY_L), _mat_runway, true)
			_runway_markings_z(root, rx, td * 0.5)

		3:  # West (-X) – runway runs N-S beyond the -X edge
			var rx := -(APRON_DEPTH + RUNWAY_W * 0.5)
			_add_apron(root, Vector3(-APRON_DEPTH * 0.5, RUNWAY_H * 0.5, td * 0.5),
					   Vector3(APRON_DEPTH, RUNWAY_H, RUNWAY_W * 1.5))
			_add_box(root, Vector3(rx, RUNWAY_H * 0.5, td * 0.5),
					 Vector3(RUNWAY_W, RUNWAY_H, RUNWAY_L), _mat_runway, true)
			_runway_markings_z(root, rx, td * 0.5)


func _add_apron(root: Node3D, pos: Vector3, size: Vector3) -> void:
	# Taxiway / apron slab between city edge and runway (no collision needed – terrain is flat)
	_add_box(root, pos, size, _mat_runway, false)


func _runway_markings_x(root: Node3D, cx: float, cz: float) -> void:
	var y := RUNWAY_H + 0.01
	for side : float in [-1.0, 1.0]:
		_add_box(root, Vector3(cx, y, cz + side * (RUNWAY_W * 0.5 - 0.5)),
				 Vector3(RUNWAY_L, 0.02, 0.7), _mat_marking, false)
	for i in range(12):
		var dx := -RUNWAY_L * 0.45 + float(i) * (RUNWAY_L * 0.9 / 11.0)
		_add_box(root, Vector3(cx + dx, y, cz), Vector3(18.0, 0.02, 0.4), _mat_marking, false)


func _runway_markings_z(root: Node3D, cx: float, cz: float) -> void:
	var y := RUNWAY_H + 0.01
	for side : float in [-1.0, 1.0]:
		_add_box(root, Vector3(cx + side * (RUNWAY_W * 0.5 - 0.5), y, cz),
				 Vector3(0.7, 0.02, RUNWAY_L), _mat_marking, false)
	for i in range(12):
		var dz := -RUNWAY_L * 0.45 + float(i) * (RUNWAY_L * 0.9 / 11.0)
		_add_box(root, Vector3(cx, y, cz + dz), Vector3(0.4, 0.02, 18.0), _mat_marking, false)


# ═════════════════════════════════════════════════════════════════════════════
# Road grid
# ═════════════════════════════════════════════════════════════════════════════
func _build_roads(root: Node3D, bx: int, bz: int, tw: float, td: float) -> void:
	const SLAB_H := 0.08

	# Road surface slabs — full-width strips are fine; coplanar overlap at crossings is invisible
	for row in range(bz + 1):
		var z_c := float(row) * (BLOCK_SIZE + ROAD_W) + ROAD_W * 0.5
		_add_box(root, Vector3(tw * 0.5, SLAB_H * 0.5, z_c),
				 Vector3(tw, SLAB_H, ROAD_W), _mat_road, true)
	for col in range(bx + 1):
		var x_c := float(col) * (BLOCK_SIZE + ROAD_W) + ROAD_W * 0.5
		_add_box(root, Vector3(x_c, SLAB_H * 0.5, td * 0.5),
				 Vector3(ROAD_W, SLAB_H, td), _mat_road, true)

	# Kerbs — one segment per block face only, so they never overlap at crossings.
	# Horizontal roads: kerb spans one block width in X, skipping the crossing zone.
	for row in range(bz + 1):
		var z_c := float(row) * (BLOCK_SIZE + ROAD_W) + ROAD_W * 0.5
		for col in range(bx):
			var seg_cx := float(col) * (BLOCK_SIZE + ROAD_W) + ROAD_W + BLOCK_SIZE * 0.5
			for side : float in [-1.0, 1.0]:
				var pz := z_c + side * (ROAD_W * 0.5 - CURB_W * 0.5)
				_add_box(root, Vector3(seg_cx, CURB_H * 0.5, pz),
						 Vector3(BLOCK_SIZE, CURB_H, CURB_W), _mat_pavement, true)
	# Vertical roads: kerb spans one block depth in Z.
	for col in range(bx + 1):
		var x_c := float(col) * (BLOCK_SIZE + ROAD_W) + ROAD_W * 0.5
		for row in range(bz):
			var seg_cz := float(row) * (BLOCK_SIZE + ROAD_W) + ROAD_W + BLOCK_SIZE * 0.5
			for side : float in [-1.0, 1.0]:
				var px := x_c + side * (ROAD_W * 0.5 - CURB_W * 0.5)
				_add_box(root, Vector3(px, CURB_H * 0.5, seg_cz),
						 Vector3(CURB_W, CURB_H, BLOCK_SIZE), _mat_pavement, true)


# ═════════════════════════════════════════════════════════════════════════════
# Building blocks
# ═════════════════════════════════════════════════════════════════════════════
func _build_block(root: Node3D, lx: float, lz: float,
				  rng: RandomNumberGenerator) -> void:
	# Subdivide block into a grid of building slots
	var slots_x := rng.randi_range(1, 3)
	var slots_z := rng.randi_range(1, 3)
	var cell_w  := BLOCK_SIZE / float(slots_x)
	var cell_d  := BLOCK_SIZE / float(slots_z)

	for si in range(slots_z):
		for sj in range(slots_x):
			var bx := lx + (float(sj) + 0.5) * cell_w
			var bz := lz + (float(si) + 0.5) * cell_d
			# Building fits within its slot with a minimum gap around it
			var bw := minf(rng.randf_range(BUILD_MIN_W, BUILD_MAX_W), cell_w - BUILD_GAP)
			var bd := minf(rng.randf_range(BUILD_MIN_W, BUILD_MAX_W), cell_d - BUILD_GAP)
			var bh := rng.randf_range(BUILD_MIN_H, BUILD_MAX_H)
			_add_building(root, Vector3(bx, bh * 0.5, bz), Vector3(bw, bh, bd), rng)


func _add_building(root: Node3D, lpos: Vector3, size: Vector3,
				   rng: RandomNumberGenerator) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _bcolors[rng.randi() % _bcolors.size()]
	mat.roughness    = rng.randf_range(0.55, 0.92)
	mat.metallic     = rng.randf_range(0.00, 0.22)

	var mi := MeshInstance3D.new()
	mi.mesh = _box_mesh(size)
	mi.set_surface_override_material(0, mat)
	mi.position = lpos
	root.add_child(mi)

	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	sb.add_child(cs)
	mi.add_child(sb)


## Place a visual box mesh. with_collision adds a static physics body (used for runway).
func _add_box(root: Node3D, lpos: Vector3, size: Vector3,
			  mat: StandardMaterial3D, with_collision: bool) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = _box_mesh(size)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.set_surface_override_material(0, mat)
	mi.position = lpos
	root.add_child(mi)

	if with_collision:
		var sb := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var sh := BoxShape3D.new()
		sh.size = size
		cs.shape = sh
		sb.add_child(cs)
		mi.add_child(sb)


func _box_mesh(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m
