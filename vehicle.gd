class_name Vehicle
extends Node3D

## Vehicle with exterior physics and proxy interior system
## Exterior body exists in world or dock proxy, interior is stable proxy space

@export var physics_proxy: PhysicsProxy
@export_enum("Single Room", "Two Rooms", "Corridor", "L-Shaped") var interior_type: int = 0

# Multiplayer sync variables
var sync_position: Vector3 = Vector3.ZERO
var sync_rotation: Quaternion = Quaternion.IDENTITY
var sync_linear_velocity: Vector3 = Vector3.ZERO
var sync_angular_velocity: Vector3 = Vector3.ZERO
var sync_is_docked: bool = false

# Vehicle components
var exterior_body: RigidBody3D  # Vehicle exterior in world or dock proxy
var dock_proxy_body: RID  # Vehicle body when docked (in parent container's interior space)
var interior_visuals: Node3D  # Interior geometry (visual only)
var interior_proxy_colliders: Array[RID]  # STATIC colliders in THIS vehicle's interior space
var transition_zone: Area3D  # Zone where player can enter vehicle

# Recursive physics space - each vehicle has its own interior space
var vehicle_interior_space: RID  # This vehicle's OWN interior physics space (for player/objects inside)

# Modular interior system
var interior_layout: InteriorLayout  # Defines the room layout for this vehicle

var is_docked: bool = false
var magnetism_enabled: bool = false

func _ready() -> void:
	_create_interior_layout()  # Create modular interior layout
	_create_vehicle_exterior()  # Creates exterior visual shell only
	_create_vehicle_physics_space()  # Create vehicle's own interior physics space
	_create_proxy_interior_colliders()  # Creates interior collision (for walking inside)
	_create_vehicle_interior_visuals()  # Creates interior visuals for PIP cameras
	_create_vehicle_dock_proxy()
	_create_transition_zone()
	_setup_multiplayer()

func _setup_multiplayer() -> void:
	# Vehicle authority is always the server (peer 1)
	set_multiplayer_authority(1)

	# Create and configure MultiplayerSynchronizer (Godot 4.5 best practice)
	var sync_node = MultiplayerSynchronizer.new()
	sync_node.name = "MultiplayerSynchronizer"
	add_child(sync_node)

	# Configure which properties to sync
	sync_node.root_path = get_path()
	sync_node.replication_config = _create_replication_config()

func _create_replication_config() -> SceneReplicationConfig:
	# Godot 4.5 best practice: Use SceneReplicationConfig for syncing properties
	var config = SceneReplicationConfig.new()

	# Sync vehicle transform and state
	config.add_property(":sync_position")
	config.add_property(":sync_rotation")
	config.add_property(":sync_linear_velocity")
	config.add_property(":sync_angular_velocity")
	config.add_property(":sync_is_docked")

	# Configure sync mode
	config.property_set_sync(":sync_position", true)
	config.property_set_sync(":sync_rotation", true)
	config.property_set_sync(":sync_linear_velocity", true)
	config.property_set_sync(":sync_angular_velocity", true)
	config.property_set_sync(":sync_is_docked", true)

	return config

func _create_interior_layout() -> void:
	# Create interior layout based on exported interior_type
	var size_scale = 3.0
	match interior_type:
		0:  # Single Room
			interior_layout = InteriorLayout.create_single_room(size_scale)
		1:  # Two Rooms
			interior_layout = InteriorLayout.create_two_room_layout(size_scale)
		2:  # Corridor
			interior_layout = InteriorLayout.create_corridor_layout(size_scale)
		3:  # L-Shaped
			interior_layout = InteriorLayout.create_l_shaped_layout(size_scale)
		_:
			interior_layout = InteriorLayout.create_single_room(size_scale)

func _create_vehicle_exterior() -> void:
	# Vehicle exterior visual and physics body - now matches interior layout shape
	exterior_body = RigidBody3D.new()
	exterior_body.name = "ExteriorBody"
	add_child(exterior_body)

	# Generate exterior geometry from interior layout
	_generate_exterior_from_layout()

	# Configure rigid body
	exterior_body.mass = 1000.0
	exterior_body.lock_rotation = false
	exterior_body.gravity_scale = 0.0  # Manual planet-centre gravity via _apply_world_gravity()
	exterior_body.linear_damp = 0.0
	exterior_body.angular_damp = 0.0

func _generate_exterior_from_layout() -> void:
	# Generate exterior shell from interior layout
	if not interior_layout:
		return

	var exterior_material := StandardMaterial3D.new()
	exterior_material.albedo_color = Color(0.8, 0.3, 0.3)
	exterior_material.metallic = 0.3
	exterior_material.roughness = 0.7
	exterior_material.grow = true
	exterior_material.grow_amount = 0.02  # Push exterior surface outward to prevent z-fighting

	for room in interior_layout.rooms:
		var half_ext = room.get_half_extents()
		var room_pos = room.get_world_position()

		if room.has_floor:
			var mesh := MeshInstance3D.new()
			mesh.mesh = BoxMesh.new()
			mesh.mesh.size = Vector3(room.dimensions.x, 0.2, room.dimensions.z)
			mesh.material_override = exterior_material
			mesh.position = room_pos + Vector3(0, -half_ext.y + 0.1, 0)
			mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			exterior_body.add_child(mesh)
			var col := CollisionShape3D.new()
			col.shape = BoxShape3D.new()
			col.shape.size = Vector3(room.dimensions.x, 0.2, room.dimensions.z)
			col.position = mesh.position
			exterior_body.add_child(col)
		if room.has_ceiling:
			var mesh := MeshInstance3D.new()
			mesh.mesh = BoxMesh.new()
			mesh.mesh.size = Vector3(room.dimensions.x, 0.2, room.dimensions.z)
			mesh.material_override = exterior_material
			mesh.position = room_pos + Vector3(0, half_ext.y - 0.1, 0)
			exterior_body.add_child(mesh)
			var col := CollisionShape3D.new()
			col.shape = BoxShape3D.new()
			col.shape.size = Vector3(room.dimensions.x, 0.2, room.dimensions.z)
			col.position = mesh.position
			exterior_body.add_child(col)
		if room.has_left_wall:
			var mesh := MeshInstance3D.new()
			mesh.mesh = BoxMesh.new()
			mesh.mesh.size = Vector3(0.2, room.dimensions.y, room.dimensions.z)
			mesh.material_override = exterior_material
			mesh.position = room_pos + Vector3(-half_ext.x, 0, 0)
			exterior_body.add_child(mesh)
			var col := CollisionShape3D.new()
			col.shape = BoxShape3D.new()
			col.shape.size = Vector3(0.2, room.dimensions.y, room.dimensions.z)
			col.position = mesh.position
			exterior_body.add_child(col)
		if room.has_right_wall:
			var mesh := MeshInstance3D.new()
			mesh.mesh = BoxMesh.new()
			mesh.mesh.size = Vector3(0.2, room.dimensions.y, room.dimensions.z)
			mesh.material_override = exterior_material
			mesh.position = room_pos + Vector3(half_ext.x, 0, 0)
			exterior_body.add_child(mesh)
			var col := CollisionShape3D.new()
			col.shape = BoxShape3D.new()
			col.shape.size = Vector3(0.2, room.dimensions.y, room.dimensions.z)
			col.position = mesh.position
			exterior_body.add_child(col)
		if room.has_front_wall:
			var mesh := MeshInstance3D.new()
			mesh.mesh = BoxMesh.new()
			mesh.mesh.size = Vector3(room.dimensions.x, room.dimensions.y, 0.2)
			mesh.material_override = exterior_material
			mesh.position = room_pos + Vector3(0, 0, half_ext.z)
			exterior_body.add_child(mesh)
			var col := CollisionShape3D.new()
			col.shape = BoxShape3D.new()
			col.shape.size = Vector3(room.dimensions.x, room.dimensions.y, 0.2)
			col.position = mesh.position
			exterior_body.add_child(col)
		if room.has_back_wall:
			var mesh := MeshInstance3D.new()
			mesh.mesh = BoxMesh.new()
			mesh.mesh.size = Vector3(room.dimensions.x, room.dimensions.y, 0.2)
			mesh.material_override = exterior_material
			mesh.position = room_pos + Vector3(0, 0, -half_ext.z)
			exterior_body.add_child(mesh)
			var col := CollisionShape3D.new()
			col.shape = BoxShape3D.new()
			col.shape.size = Vector3(room.dimensions.x, room.dimensions.y, 0.2)
			col.position = mesh.position
			exterior_body.add_child(col)

func _create_vehicle_physics_space() -> void:
	# Each vehicle has its own interior physics space for recursive nesting
	# This allows ships inside containers, containers inside containers, etc.
	if not physics_proxy:
		push_warning("PhysicsProxy not assigned to Vehicle")
		return

	vehicle_interior_space = PhysicsServer3D.space_create()
	PhysicsServer3D.space_set_active(vehicle_interior_space, false)  # Start inactive, activate on demand

	# Create gravity area for this vehicle's interior
	# UNIVERSAL: Match world gravity (9.81) for consistency across all spaces
	var gravity_area = PhysicsServer3D.area_create()
	PhysicsServer3D.area_set_space(gravity_area, vehicle_interior_space)
	PhysicsServer3D.area_set_param(gravity_area, PhysicsServer3D.AREA_PARAM_GRAVITY, 9.81)
	PhysicsServer3D.area_set_param(gravity_area, PhysicsServer3D.AREA_PARAM_GRAVITY_VECTOR, Vector3(0, -1, 0))
	PhysicsServer3D.area_set_param(gravity_area, PhysicsServer3D.AREA_PARAM_GRAVITY_IS_POINT, false)

	# Make the gravity area large enough to cover the vehicle interior
	var large_box_shape = PhysicsServer3D.box_shape_create()
	PhysicsServer3D.shape_set_data(large_box_shape, Vector3(1000, 1000, 1000))
	PhysicsServer3D.area_add_shape(gravity_area, large_box_shape)
	PhysicsServer3D.area_set_shape_transform(gravity_area, 0, Transform3D(Basis(), Vector3.ZERO))

func _create_vehicle_interior_visuals() -> void:
	# Use InteriorGenerator to create visual meshes from layout
	# These are for PIP cameras to show interior, created as separate node
	if not interior_layout:
		push_warning("Interior layout not created")
		return

	# Create interior visuals parented to exterior_body so they rotate with the ship
	# These have no collision and are offset inward from exterior walls to avoid overlap
	interior_visuals = InteriorGenerator.generate_visuals(interior_layout, exterior_body)

	# Make interior visuals slightly transparent to distinguish from exterior
	if interior_visuals:
		for child in interior_visuals.get_children():
			if child is MeshInstance3D:
				var mat = child.get_surface_override_material(0)
				if not mat:
					mat = child.material_override
				if mat is StandardMaterial3D:
					mat.albedo_color.a = 0.8  # Slight transparency

func _create_proxy_interior_colliders() -> void:
	# Use InteriorGenerator to create STATIC colliders from layout
	if not vehicle_interior_space.is_valid():
		push_warning("Vehicle interior space not created")
		return

	if not interior_layout:
		push_warning("Interior layout not created")
		return

	# Generate colliders from modular layout
	interior_proxy_colliders = InteriorGenerator.generate_colliders(interior_layout, vehicle_interior_space)

func _update_interior_colliders_position(dock_transform: Transform3D) -> void:
	# Update interior collider positions to match dock_proxy_body when docked
	# This ensures the player walks on floors that move with the ship
	if interior_proxy_colliders.size() == 0:
		return

	var size_scale = 3.0

	# The interior colliders were created with these RELATIVE positions:
	# Floor: (0, -1.5*scale + 0.1, 0) - matches exterior
	# Left wall: (-3.0 * size_scale, 0, 0)
	# Right wall: (3.0 * size_scale, 0, 0)
	# Back wall: (0, 0, -5.0 * size_scale)
	# Ceiling: (0, 1.5*scale - 0.1, 0) - matches exterior

	var relative_positions = [
		Vector3(0, -1.5 * size_scale + 0.1, 0),  # Floor
		Vector3(-3.0 * size_scale, 0, 0),   # Left wall
		Vector3(3.0 * size_scale, 0, 0),    # Right wall
		Vector3(0, 0, -5.0 * size_scale),   # Back wall
		Vector3(0, 1.5 * size_scale - 0.1, 0)     # Ceiling
	]

	# Update each collider's position to be relative to dock_proxy_body
	for i in range(min(interior_proxy_colliders.size(), relative_positions.size())):
		var collider = interior_proxy_colliders[i]
		if collider.is_valid():
			# Transform relative position by dock_proxy_body's transform
			var world_pos = dock_transform.origin + dock_transform.basis * relative_positions[i]
			var collider_transform = Transform3D(dock_transform.basis, world_pos)
			PhysicsServer3D.body_set_state(collider, PhysicsServer3D.BODY_STATE_TRANSFORM, collider_transform)

func _create_proxy_interior_visuals() -> void:
	# Create visual geometry in proxy space for PIP cameras to see
	# This is the STABLE interior that doesn't move with the ship
	# These need to be in a separate scene/world that the PIP viewport can see

	# NOTE: This requires creating a separate World3D for the viewport
	# which will be done in the dual_camera_view.gd
	# For now, we'll create the visual nodes that can be added to that world
	pass  # Implemented in dual_camera_view

func _create_vehicle_dock_proxy() -> void:
	# Create vehicle physics body for when docked in a container using modular layout
	if not interior_layout:
		push_warning("Interior layout not created")
		return

	dock_proxy_body = PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(dock_proxy_body, PhysicsServer3D.BODY_MODE_RIGID)
	PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), Vector3.ZERO))

	# Generate shapes from modular layout
	var shapes = InteriorGenerator.generate_dock_shapes(interior_layout)
	for i in range(shapes.size()):
		var shape_data = shapes[i]
		var shape_rid = shape_data[0]
		var shape_transform = shape_data[1]
		PhysicsServer3D.body_add_shape(dock_proxy_body, shape_rid)
		PhysicsServer3D.body_set_shape_transform(dock_proxy_body, i, shape_transform)

	# Enable collision with container interiors (layer 1, mask 1)
	PhysicsServer3D.body_set_collision_layer(dock_proxy_body, 1)
	PhysicsServer3D.body_set_collision_mask(dock_proxy_body, 1)

	# Physics parameters for docked ship
	PhysicsServer3D.body_set_param(dock_proxy_body, PhysicsServer3D.BODY_PARAM_GRAVITY_SCALE, 1.0)
	PhysicsServer3D.body_set_param(dock_proxy_body, PhysicsServer3D.BODY_PARAM_LINEAR_DAMP, 0.1)
	PhysicsServer3D.body_set_param(dock_proxy_body, PhysicsServer3D.BODY_PARAM_ANGULAR_DAMP, 0.1)
	PhysicsServer3D.body_set_param(dock_proxy_body, PhysicsServer3D.BODY_PARAM_MASS, 1000.0)
	PhysicsServer3D.body_set_param(dock_proxy_body, PhysicsServer3D.BODY_PARAM_BOUNCE, 0.0)
	PhysicsServer3D.body_set_param(dock_proxy_body, PhysicsServer3D.BODY_PARAM_FRICTION, 1.0)
	PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_CAN_SLEEP, true)

func _create_transition_zone() -> void:
	# Create invisible transition zone at vehicle entrance (front opening)
	transition_zone = Area3D.new()
	transition_zone.name = "TransitionZone"
	add_child(transition_zone)  # Add to vehicle, not exterior_body

	# Zone is just used for logic, no visible collision shape needed
	# Transition detection is done via position checks in game_manager

func _process(_delta: float) -> void:
	# Update visual every frame for smooth rendering (not just physics frames)
	_update_vehicle_visual_position()

## Corner-based buoyancy. Each bottom corner submerged below the water surface
## contributes an upward force proportional to depth. Water drag is also applied.
const BUOY_FACTOR  : float = 2.0   # lift multiple at 1 unit submersion (>1 → object floats high)
const WATER_DRAG   : float = 1.5   # linear / angular damp when any corner is wet
const GRAVITY_STRENGTH : float = 20.0  # m/s² toward planet centre

func _apply_world_gravity(delta: float) -> void:
	if not exterior_body or is_docked:
		return
	var planet_center := Vector3(0.0, -PlanetTerrain.PLANET_RADIUS, 0.0)
	var to_center     := (planet_center - exterior_body.global_position).normalized()
	# Direct velocity accumulation — identical to how the player applies gravity,
	# so both fall at exactly the same rate.
	exterior_body.linear_velocity += to_center * GRAVITY_STRENGTH * delta

func _apply_buoyancy() -> void:
	if not exterior_body or is_docked or not interior_layout or interior_layout.rooms.is_empty():
		return

	# Bounding box of the full layout in local space
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for room in interior_layout.rooms:
		var rp : Vector3 = room.get_world_position()
		var he : Vector3 = room.get_half_extents()
		lo = lo.min(rp - he)
		hi = hi.max(rp + he)

	var bt  : Transform3D = exterior_body.global_transform
	# Buoyancy coefficient per corner (N per unit depth)
	var k   : float = exterior_body.mass * 9.8 * BUOY_FACTOR * 0.25

	var corners : Array[Vector3] = [
		Vector3(lo.x, lo.y, lo.z),
		Vector3(hi.x, lo.y, lo.z),
		Vector3(lo.x, lo.y, hi.z),
		Vector3(hi.x, lo.y, hi.z),
	]

	var any_wet : bool = false
	for lc in corners:
		var wc    : Vector3 = bt * lc
		var wy    : float   = PlanetTerrain.water_surface_y(wc.x, wc.z)
		var depth : float   = wy - wc.y
		if depth > 0.0:
			# position arg = global-space offset from body origin to corner
			exterior_body.apply_force(Vector3(0.0, k * depth, 0.0), bt.basis * lc)
			any_wet = true

	exterior_body.linear_damp  = WATER_DRAG if any_wet else 0.0
	exterior_body.angular_damp = WATER_DRAG if any_wet else 0.0

func _physics_process(delta: float) -> void:
	_apply_world_gravity(delta)
	_apply_buoyancy()
	# Multiplayer synchronization (only if multiplayer is active)
	var has_enet_peer = multiplayer.multiplayer_peer != null and multiplayer.multiplayer_peer is ENetMultiplayerPeer
	if has_enet_peer:
		var peer = multiplayer.multiplayer_peer as ENetMultiplayerPeer
		if peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			if is_multiplayer_authority():
				_sync_state_to_network()
			else:
				_apply_synced_state()
	else:
		# Single-player mode - always sync locally
		_sync_state_to_network()

func _sync_state_to_network() -> void:
	# Sync vehicle state to clients
	if is_docked and dock_proxy_body.is_valid():
		var proxy_transform = PhysicsServer3D.body_get_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_TRANSFORM)
		sync_position = proxy_transform.origin
		sync_rotation = Quaternion(proxy_transform.basis)
		sync_linear_velocity = PhysicsServer3D.body_get_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
		sync_angular_velocity = PhysicsServer3D.body_get_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
	elif exterior_body:
		sync_position = exterior_body.global_position
		sync_rotation = Quaternion(exterior_body.global_transform.basis)
		sync_linear_velocity = exterior_body.linear_velocity
		sync_angular_velocity = exterior_body.angular_velocity
	sync_is_docked = is_docked

func _apply_synced_state() -> void:
	# Apply synced state from server for clients
	if sync_is_docked and dock_proxy_body.is_valid():
		var new_transform = Transform3D(Basis(sync_rotation), sync_position)
		PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_TRANSFORM, new_transform)
		PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, sync_linear_velocity)
		PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, sync_angular_velocity)
	elif exterior_body:
		exterior_body.global_position = sync_position
		exterior_body.global_transform.basis = Basis(sync_rotation)
		exterior_body.linear_velocity = sync_linear_velocity
		exterior_body.angular_velocity = sync_angular_velocity

func _update_vehicle_visual_position() -> void:
	# Update vehicle visual based on current physics space
	if is_docked and dock_proxy_body.is_valid() and exterior_body:
		# Vehicle is docked in container - sync exterior visual with proxy physics
		var proxy_transform: Transform3D = PhysicsServer3D.body_get_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_TRANSFORM)

		# Get parent container
		var container = _get_docked_container()
		if container and container.exterior_body:
			# Use recursive helper to get container's world transform (handles nested containers)
			var container_world_transform = VehicleContainer.get_world_transform(container)

			# Transform proxy position (in container's interior space) to world space
			var world_transform = container_world_transform * proxy_transform

			# Update exterior body to match proxy position
			exterior_body.global_transform = world_transform
	# When not docked, exterior_body is already in world space and doesn't need updating

func _is_player_in_ship() -> bool:
	# Check if player is in this ship's interior
	var game_manager = get_parent()
	if not game_manager:
		return false

	for child in game_manager.get_children():
		if child is CharacterController:
			return child.is_in_vehicle

	return false

func _refresh_interior_colliders_at_origin() -> void:
	# Keep KINEMATIC colliders active when ship is free-flying
	# Colliders are stationary at origin in proxy space
	if interior_proxy_colliders.size() == 0:
		return

	var size_scale = 3.0

	var collider_positions = [
		Vector3(0, -1.5 * size_scale + 0.1, 0),  # Floor - matches exterior
		Vector3(-3.0 * size_scale, 0, 0),   # Left wall
		Vector3(3.0 * size_scale, 0, 0),    # Right wall
		Vector3(0, 0, -5.0 * size_scale),   # Back wall
		Vector3(0, 1.5 * size_scale - 0.1, 0)     # Ceiling - matches exterior
	]

	for i in range(min(interior_proxy_colliders.size(), collider_positions.size())):
		var collider = interior_proxy_colliders[i]
		if collider.is_valid():
			var collider_transform = Transform3D(Basis(), collider_positions[i])
			PhysicsServer3D.body_set_state(collider, PhysicsServer3D.BODY_STATE_TRANSFORM, collider_transform)

func apply_thrust(direction: Vector3, force: float) -> void:
	if is_docked and dock_proxy_body.is_valid():
		# Apply thrust in proxy interior space
		# Direction comes in world space from exterior_body.basis
		# Need to transform to the space where dock_proxy_body exists
		var container = _get_docked_container()
		if container:
			# CRITICAL: Use recursive world transform to handle nested containers
			var container_world_transform = VehicleContainer.get_world_transform(container)
			# Transform world direction to container's interior space
			var proxy_direction = container_world_transform.basis.inverse() * direction

			# Full thrust power when docked, but clamp resulting velocity to safe limits
			var mass = PhysicsServer3D.body_get_param(dock_proxy_body, PhysicsServer3D.BODY_PARAM_MASS)
			var acceleration = force / mass
			var impulse = proxy_direction * acceleration * get_process_delta_time()
			var current_vel = PhysicsServer3D.body_get_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
			var new_vel = current_vel + impulse

			# Clamp to high max speeds - only prevent physics explosions, not normal flight
			new_vel.x = clamp(new_vel.x, -30.0, 30.0)
			new_vel.y = clamp(new_vel.y, -20.0, 20.0)
			new_vel.z = clamp(new_vel.z, -30.0, 30.0)

			PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, new_vel)
	elif exterior_body:
		# Apply thrust in world
		exterior_body.apply_central_force(direction * force)

func apply_rotation(axis: Vector3, torque: float) -> void:
	if is_docked and dock_proxy_body.is_valid():
		# Apply rotation in proxy interior space
		# Axis comes in world space, need to transform to container's interior space
		var container = _get_docked_container()
		if container:
			# CRITICAL: Use recursive world transform to handle nested containers
			var container_world_transform = VehicleContainer.get_world_transform(container)
			var local_axis = container_world_transform.basis.inverse() * axis

			# Full rotation power when docked, but clamp resulting angular velocity
			var mass = PhysicsServer3D.body_get_param(dock_proxy_body, PhysicsServer3D.BODY_PARAM_MASS)
			var angular_acceleration = torque / mass
			var angular_impulse = local_axis * angular_acceleration * get_process_delta_time()
			var current_angvel = PhysicsServer3D.body_get_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
			var new_angvel = current_angvel + angular_impulse

			# Clamp angular velocity to reasonable rotation speeds (3.0 rad/s = ~172 deg/s)
			new_angvel.x = clamp(new_angvel.x, -3.0, 3.0)
			new_angvel.y = clamp(new_angvel.y, -3.0, 3.0)
			new_angvel.z = clamp(new_angvel.z, -3.0, 3.0)

			PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, new_angvel)
	elif exterior_body:
		# Apply rotation in world - use same physics as docked for consistency
		var mass = exterior_body.mass
		var angular_acceleration = torque / mass
		var angular_impulse = axis * angular_acceleration * get_process_delta_time()
		var current_angvel = exterior_body.angular_velocity
		var new_angvel = current_angvel + angular_impulse

		# Clamp angular velocity to same limits as docked (3.0 rad/s = ~172 deg/s)
		new_angvel.x = clamp(new_angvel.x, -3.0, 3.0)
		new_angvel.y = clamp(new_angvel.y, -3.0, 3.0)
		new_angvel.z = clamp(new_angvel.z, -3.0, 3.0)

		exterior_body.angular_velocity = new_angvel
		print("[VEHICLE] Applied rotation to FREE ship - new_angvel: ", new_angvel)
	else:
		print("[VEHICLE] Cannot apply rotation - no valid body!")

func toggle_magnetism() -> void:
	# Toggle artificial gravity in THIS vehicle's interior space
	if vehicle_interior_space.is_valid():
		magnetism_enabled = !magnetism_enabled
		# Note: In the new architecture, each vehicle has its own gravity area
		# which was created in _create_vehicle_physics_space()
		# We would need to store the gravity_area RID to toggle it
		# For now, this is a placeholder for future implementation

func set_docked(docked: bool, parent_container: VehicleContainer = null) -> void:
	if docked and not is_docked:
		# Ship is entering dock - transfer position from world to container's interior space
		if exterior_body and dock_proxy_body.is_valid():
			# Get container to transform world position to container local space
			# If not provided, try to find VehicleContainerSmall (backwards compatibility)
			var container = parent_container
			if not container:
				container = get_parent().get_node_or_null("VehicleContainerSmall")
			if container and container.exterior_body:
				var container_transform = container.exterior_body.global_transform
				var world_transform = exterior_body.global_transform

				# Transform world position to container local space (preserve current position)
				var relative_transform = container_transform.inverse() * world_transform

				# UNIVERSAL: No position clamping - rely entirely on hysteresis system
				# Hysteresis (position + velocity checks) prevents unwanted transitions

				# CRITICAL: Set transform and velocities BEFORE adding to space
				# This prevents spawning at (0,0,0) inside floor collider
				PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_TRANSFORM, relative_transform)

				# Preserve velocity for seamless entry
				# Transform from world space to container local space
				var world_velocity = exterior_body.linear_velocity
				var local_velocity = container_transform.basis.inverse() * world_velocity

				# Light damping (keep 70% of velocity) for smooth transition - no clamping
				var damped_velocity = local_velocity * 0.7

				# CRITICAL: Wake up the body BEFORE setting velocities
				# Otherwise physics engine might ignore velocity on a sleeping body
				PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_SLEEPING, false)

				# Set velocities
				PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, damped_velocity)

				# Preserve angular velocity with light damping for stability
				var world_angvel = exterior_body.angular_velocity
				var local_angvel = container_transform.basis.inverse() * world_angvel
				# Apply 30% damping to match linear velocity damping
				PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, local_angvel * 0.7)

				# Force wake up again after setting velocities
				PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_SLEEPING, false)

				# CRITICAL: NOW add to space AFTER all state is configured
				# This prevents spawning at origin and getting ejected from floor
				var container_interior_space = container.get_interior_space()
				if not container_interior_space.is_valid():
					push_error("Container interior space not valid!")
					return

				# Activate container space if not already active
				if not PhysicsServer3D.space_is_active(container_interior_space):
					PhysicsServer3D.space_set_active(container_interior_space, true)

				PhysicsServer3D.body_set_space(dock_proxy_body, container_interior_space)

				# CRITICAL: State might be reset when adding to space - set it AGAIN after adding
				PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_TRANSFORM, relative_transform)
				PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, damped_velocity)
				PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, local_angvel * 0.7)
				PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_SLEEPING, false)

				# Make exterior_body kinematic (not frozen) - it becomes a visual follower
				# Similar to how player's world_body continues to exist when in vehicle/container
				exterior_body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
				exterior_body.freeze = true  # Enable kinematic mode

				# CRITICAL: Disable collision on exterior_body to prevent physics conflicts
				# Only dock_proxy_body should have active physics when docked
				exterior_body.collision_layer = 0
				exterior_body.collision_mask = 0
	elif not docked and is_docked:
		# Ship is leaving dock - transfer position from container's interior space to world
		if exterior_body and dock_proxy_body.is_valid():
			# Get container (if not provided, try to find VehicleContainerSmall)
			var container = parent_container
			if not container:
				container = get_parent().get_node_or_null("VehicleContainerSmall")
			if container and container.exterior_body:
				var container_transform = container.exterior_body.global_transform
				var dock_transform = PhysicsServer3D.body_get_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_TRANSFORM)

				# Transform dock proxy position (in container's interior space) to world space
				var world_transform = container_transform * dock_transform

				# Set exterior body to this world position
				exterior_body.global_transform = world_transform

				# CRITICAL: Zero velocities BEFORE unfreezing to clear phantom velocities from kinematic mode
				exterior_body.linear_velocity = Vector3.ZERO
				exterior_body.angular_velocity = Vector3.ZERO

				# CRITICAL: Restore exterior_body to rigid mode after undocking
				# Exterior_body is now the active physics body again
				exterior_body.freeze = false  # Disable kinematic

				# Re-enable collision on exterior_body
				exterior_body.collision_layer = 1
				exterior_body.collision_mask = 1

				# NOW set correct velocities from container's interior space to world space
				var local_velocity = PhysicsServer3D.body_get_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
				var world_velocity = container_transform.basis * local_velocity
				exterior_body.linear_velocity = world_velocity

				# Copy angular velocity
				var local_angvel = PhysicsServer3D.body_get_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
				var world_angvel = container_transform.basis * local_angvel
				exterior_body.angular_velocity = world_angvel

				# Remove dock_proxy_body from container's interior space
				# (it will be added to a new space when docking again)
				PhysicsServer3D.body_set_space(dock_proxy_body, RID())

	is_docked = docked

func get_interior_space() -> RID:
	# Return this vehicle's interior physics space (for recursive nesting)
	return vehicle_interior_space

func _get_docked_container() -> VehicleContainer:
	# Find the container that this ship is currently docked in
	# Returns null if not docked or container not found
	if not is_docked or not dock_proxy_body.is_valid():
		return null

	var game_manager = get_parent()
	if not game_manager:
		return null

	# Find the container whose interior space contains our dock_proxy_body
	var dock_space = PhysicsServer3D.body_get_space(dock_proxy_body)
	for child in game_manager.get_children():
		if child is VehicleContainer:
			var test_container = child as VehicleContainer
			if dock_space == test_container.get_interior_space():
				return test_container

	return null

func _exit_tree() -> void:
	# Clean up proxy colliders
	for collider in interior_proxy_colliders:
		if collider.is_valid():
			PhysicsServer3D.free_rid(collider)

	if dock_proxy_body.is_valid():
		PhysicsServer3D.free_rid(dock_proxy_body)

	# Clean up vehicle's interior physics space
	if vehicle_interior_space.is_valid():
		PhysicsServer3D.free_rid(vehicle_interior_space)
