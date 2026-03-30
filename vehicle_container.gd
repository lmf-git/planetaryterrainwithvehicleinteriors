class_name VehicleContainer
extends Node3D

## VehicleContainer with exterior physics and proxy interior system
## Similar to vehicle but larger, with docking bay for vehicles

@export var physics_proxy: PhysicsProxy
@export var size_multiplier: float = 5.0  # How many times larger than ship (default: 5x ship = 15x base)
@export_enum("Single Room", "Two Rooms", "Corridor", "L-Shaped") var interior_type: int = 0

# Multiplayer sync variables
var sync_position: Vector3 = Vector3.ZERO
var sync_rotation: Quaternion = Quaternion.IDENTITY
var sync_linear_velocity: Vector3 = Vector3.ZERO
var sync_angular_velocity: Vector3 = Vector3.ZERO
var sync_is_docked: bool = false

# Station proxy Y offset in proxy space - MUST be different from ship to avoid overlap!
# Ship floor: y=-4.2, Station floor: y=50 (small), y=100 (medium), y=150 (large)
# Each container size gets its own Y offset to avoid collisions in proxy space
const STATION_PROXY_Y_OFFSET_BASE: float = 50.0
var station_proxy_y_offset: float = 0.0  # Set in _ready()

# VehicleContainer components
var exterior_body: RigidBody3D  # VehicleContainer exterior in world
var interior_proxy_colliders: Array[RID]  # Static colliders in this container's proxy space
var container_interior_space: RID  # This container's OWN proxy interior space
var dock_proxy_body: RID  # This container's body when docked in a larger container
var transition_zone: Area3D  # Zone where vehicles/players can transition to interior
var is_docked: bool = false  # Is this container docked in a larger container?
var docked_in_container: VehicleContainer = null  # Reference to parent container when docked

# Modular interior system
var interior_layout: InteriorLayout  # Defines the room layout for this container

func _ready() -> void:
	# Calculate unique Y offset based on size to avoid proxy space collisions
	# Small (5x): Y=50, Medium (10x): Y=100, Large (15x): Y=150
	station_proxy_y_offset = STATION_PROXY_Y_OFFSET_BASE * (size_multiplier / 5.0)

	# Create modular interior layout
	_create_interior_layout()

	# Create this container's OWN physics space for its interior
	_create_container_physics_space()

	_create_container_exterior()  # Creates exterior visual shell only
	_create_container_proxy_interior()  # Creates interior collision (for walking inside)
	_create_container_interior_visuals()  # Creates interior visuals for PIP cameras
	_create_container_dock_proxy()
	_create_transition_zone()
	_setup_multiplayer()

func _setup_multiplayer() -> void:
	# Container authority is always the server (peer 1)
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

	# Sync container transform and state
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
	# Create interior layout based on exported interior_type (scaled by size_multiplier)
	var size_scale = 3.0 * size_multiplier
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

func _create_container_physics_space() -> void:
	# Each container has its own interior physics space for recursive nesting
	container_interior_space = PhysicsServer3D.space_create()
	PhysicsServer3D.space_set_active(container_interior_space, false)  # Start inactive, activate on demand

	# Create gravity for this container's interior
	# UNIVERSAL: Match world gravity (9.81) for consistency across all spaces
	var gravity_area = PhysicsServer3D.area_create()
	PhysicsServer3D.area_set_space(gravity_area, container_interior_space)
	PhysicsServer3D.area_set_param(gravity_area, PhysicsServer3D.AREA_PARAM_GRAVITY, 9.81)
	PhysicsServer3D.area_set_param(gravity_area, PhysicsServer3D.AREA_PARAM_GRAVITY_VECTOR, Vector3(0, -1, 0))
	PhysicsServer3D.area_set_param(gravity_area, PhysicsServer3D.AREA_PARAM_GRAVITY_IS_POINT, false)

	var large_box_shape = PhysicsServer3D.box_shape_create()
	PhysicsServer3D.shape_set_data(large_box_shape, Vector3(10000, 10000, 10000))
	PhysicsServer3D.area_add_shape(gravity_area, large_box_shape)
	PhysicsServer3D.area_set_shape_transform(gravity_area, 0, Transform3D(Basis(), Vector3.ZERO))

func _physics_process(_delta: float) -> void:
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
	# Sync container state to clients
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

func _is_player_in_container() -> bool:
	# Check if player is in this container's interior
	var game_manager = get_parent()
	if not game_manager:
		return false

	for child in game_manager.get_children():
		if child is CharacterController:
			return child.is_in_container

	return false

func _refresh_interior_colliders() -> void:
	# Re-set collider transforms to keep them active for collision detection
	# Station colliders are stationary, but need to be refreshed each frame
	if interior_proxy_colliders.size() == 0:
		return

	# Ship is 3x base, container is size_multiplier times ship
	var size_scale = 3.0 * size_multiplier

	# Fixed positions for container interior colliders in its own coordinate system
	var collider_positions = [
		Vector3(0, -1.4 * size_scale, 0),  # Floor
		Vector3(-3.0 * size_scale, 0, 0),  # Left wall
		Vector3(3.0 * size_scale, 0, 0),  # Right wall
		Vector3(0, 0, -5.0 * size_scale),  # Back wall
		Vector3(0, 1.4 * size_scale, 0)  # Ceiling
	]

	# Update each collider to maintain collision detection
	for i in range(min(interior_proxy_colliders.size(), collider_positions.size())):
		var collider = interior_proxy_colliders[i]
		if collider.is_valid():
			var collider_transform = Transform3D(Basis(), collider_positions[i])
			PhysicsServer3D.body_set_state(collider, PhysicsServer3D.BODY_STATE_TRANSFORM, collider_transform)

func _create_container_exterior() -> void:
	# Create container exterior - matches interior layout shape
	exterior_body = RigidBody3D.new()
	exterior_body.name = "ExteriorBody"
	exterior_body.mass = 50000.0 * size_multiplier  # Heavy but controllable - 50x ship mass (1000 kg)
	exterior_body.gravity_scale = 1.0  # UNIVERSAL: Same gravity everywhere (world and all interiors)
	exterior_body.linear_damp = 0.0
	exterior_body.angular_damp = 0.0
	add_child(exterior_body)

	# Generate exterior geometry from interior layout
	_generate_container_exterior_from_layout()

func _generate_container_exterior_from_layout() -> void:
	# Generate exterior shell from interior layout
	if not interior_layout:
		return

	var material := StandardMaterial3D.new()
	# Use slightly different color than ship to distinguish containers
	material.albedo_color = Color(0.7, 0.75, 0.8)  # Slightly blue-gray
	material.metallic = 0.3
	material.roughness = 0.7
	material.grow = true
	material.grow_amount = 0.02  # Push exterior surface outward to prevent z-fighting

	for room in interior_layout.rooms:
		var half_ext = room.get_half_extents()
		var room_pos = room.get_world_position()

		if room.has_floor:
			var mesh := MeshInstance3D.new()
			mesh.mesh = BoxMesh.new()
			mesh.mesh.size = Vector3(room.dimensions.x, 0.2, room.dimensions.z)
			mesh.material_override = material
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
			mesh.material_override = material
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
			mesh.material_override = material
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
			mesh.material_override = material
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
			mesh.material_override = material
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
			mesh.material_override = material
			mesh.position = room_pos + Vector3(0, 0, -half_ext.z)
			exterior_body.add_child(mesh)
			var col := CollisionShape3D.new()
			col.shape = BoxShape3D.new()
			col.shape.size = Vector3(room.dimensions.x, room.dimensions.y, 0.2)
			col.position = mesh.position
			exterior_body.add_child(col)

func _create_container_proxy_interior() -> void:
	# Use InteriorGenerator to create STATIC colliders from layout
	if not container_interior_space.is_valid():
		push_warning("Container interior space not created")
		return

	if not interior_layout:
		push_warning("Interior layout not created")
		return

	# Generate colliders from modular layout
	interior_proxy_colliders = InteriorGenerator.generate_colliders(interior_layout, container_interior_space)

func _create_container_interior_visuals() -> void:
	# Use InteriorGenerator to create visual meshes from layout
	# These are for PIP cameras to show interior
	if not interior_layout:
		push_warning("Interior layout not created")
		return

	# Generate visuals from modular layout (parented to exterior_body so they rotate with container)
	var interior_visuals_node = InteriorGenerator.generate_visuals(interior_layout, exterior_body)

	# Make interior visuals slightly transparent to distinguish from exterior
	if interior_visuals_node:
		for child in interior_visuals_node.get_children():
			if child is MeshInstance3D:
				var mat = child.get_surface_override_material(0)
				if not mat:
					mat = child.material_override
				if mat is StandardMaterial3D:
					mat.albedo_color.a = 0.8  # Slight transparency

func _create_container_dock_proxy() -> void:
	# Create THIS container's body for when it's docked in a LARGER container using modular layout
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

	# Enable collision with parent container interiors (layer 1, mask 1)
	PhysicsServer3D.body_set_collision_layer(dock_proxy_body, 1)
	PhysicsServer3D.body_set_collision_mask(dock_proxy_body, 1)

	# Physics parameters for docked container
	PhysicsServer3D.body_set_param(dock_proxy_body, PhysicsServer3D.BODY_PARAM_GRAVITY_SCALE, 1.0)
	PhysicsServer3D.body_set_param(dock_proxy_body, PhysicsServer3D.BODY_PARAM_LINEAR_DAMP, 0.1)
	PhysicsServer3D.body_set_param(dock_proxy_body, PhysicsServer3D.BODY_PARAM_ANGULAR_DAMP, 0.1)
	PhysicsServer3D.body_set_param(dock_proxy_body, PhysicsServer3D.BODY_PARAM_MASS, 50000.0 * size_multiplier)
	PhysicsServer3D.body_set_param(dock_proxy_body, PhysicsServer3D.BODY_PARAM_BOUNCE, 0.0)
	PhysicsServer3D.body_set_param(dock_proxy_body, PhysicsServer3D.BODY_PARAM_FRICTION, 1.0)
	PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_CAN_SLEEP, true)

func _create_transition_zone() -> void:
	# Create invisible trigger zone at container entrance
	# Match ship entrance zone proportions scaled by size_multiplier
	transition_zone = Area3D.new()
	transition_zone.name = "TransitionZone"
	add_child(transition_zone)

	var zone_shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	# Ship entrance zone: Vector3(10, 8, 3) at z=16.5
	# Container entrance zone: size_multiplier times larger
	box_shape.size = Vector3(10 * size_multiplier, 8 * size_multiplier, 3 * size_multiplier)
	zone_shape.shape = box_shape
	transition_zone.add_child(zone_shape)

	transition_zone.position = Vector3(0, 0, 16.5 * size_multiplier)  # At container entrance
	transition_zone.monitoring = true
	transition_zone.monitorable = true

func apply_rotation(axis: Vector3, torque: float) -> void:
	# CRITICAL: Apply torque to dock_proxy_body if docked, otherwise exterior_body
	if is_docked and dock_proxy_body.is_valid():
		PhysicsServer3D.body_apply_torque(dock_proxy_body, axis * torque)
	elif exterior_body:
		exterior_body.apply_torque(axis * torque)

func apply_thrust(direction: Vector3, force: float) -> void:
	# CRITICAL: Apply force to dock_proxy_body if docked, otherwise exterior_body
	if is_docked and dock_proxy_body.is_valid():
		PhysicsServer3D.body_apply_central_force(dock_proxy_body, direction * force)
	elif exterior_body:
		exterior_body.apply_central_force(direction * force)

func get_interior_space() -> RID:
	# Return this container's interior physics space
	return container_interior_space

func _get_docked_container() -> VehicleContainer:
	# Return the container this container is docked in (if any)
	return docked_in_container

func set_docked(docked: bool, parent_container: VehicleContainer = null) -> void:
	if docked and not is_docked:
		# Container entering dock in parent container
		if exterior_body and dock_proxy_body.is_valid() and parent_container:
			# Store reference to parent container
			docked_in_container = parent_container

			# CRITICAL: Use recursive transform for parent in case it's also docked
			var parent_world_transform = VehicleContainer.get_world_transform(parent_container)
			var world_transform = exterior_body.global_transform

			# Transform world position to parent container's local space (preserve current position)
			var relative_transform = parent_world_transform.inverse() * world_transform

			# UNIVERSAL: No position clamping - rely entirely on hysteresis system
			# Hysteresis (position + velocity checks) prevents unwanted transitions

			var proxy_transform = relative_transform

			# CRITICAL: Preserve velocity for seamless docking (like ship docking)
			# Transform from world space to parent container's local space
			var world_velocity = exterior_body.linear_velocity
			var local_velocity = parent_world_transform.basis.inverse() * world_velocity

			# Light damping (keep 70% of velocity) for smooth transition - no clamping
			var damped_velocity = local_velocity * 0.7

			# Preserve angular velocity with light damping for stability
			var world_angvel = exterior_body.angular_velocity
			var local_angvel = parent_world_transform.basis.inverse() * world_angvel

			# CRITICAL: Set transform and velocities BEFORE adding to space
			# This prevents spawning at (0,0,0) and teleporting
			PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_TRANSFORM, proxy_transform)
			PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_SLEEPING, false)
			PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, damped_velocity)
			PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, local_angvel * 0.7)

			# CRITICAL: NOW add to space AFTER all state is configured
			var parent_interior_space = parent_container.get_interior_space()
			if not parent_interior_space.is_valid():
				push_error("Parent container interior space not valid!")
				return

			# Activate parent container space if not already active
			if not PhysicsServer3D.space_is_active(parent_interior_space):
				PhysicsServer3D.space_set_active(parent_interior_space, true)

			PhysicsServer3D.body_set_space(dock_proxy_body, parent_interior_space)

			# CRITICAL: State might be reset when adding to space - set it AGAIN after adding
			PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_TRANSFORM, proxy_transform)
			PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, damped_velocity)
			PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, local_angvel * 0.7)
			PhysicsServer3D.body_set_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_SLEEPING, false)

			# Make exterior_body kinematic (not frozen) - it becomes a visual follower
			# Similar to how ship's exterior_body follows dock_proxy_body when docked
			exterior_body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
			exterior_body.freeze = true  # Enable kinematic mode

			# CRITICAL: Disable collision on exterior_body to prevent physics conflicts
			# Only dock_proxy_body should have active physics when docked
			exterior_body.collision_layer = 0
			exterior_body.collision_mask = 0
	elif not docked and is_docked:
		# Container leaving dock - transfer position from parent's interior space to world
		if exterior_body and dock_proxy_body.is_valid() and parent_container:
			# CRITICAL: Use recursive transform for parent in case it's also docked
			var parent_world_transform = VehicleContainer.get_world_transform(parent_container)
			var dock_transform = PhysicsServer3D.body_get_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_TRANSFORM)

			# Transform dock proxy position (in parent's interior space) to world space
			var world_transform = parent_world_transform * dock_transform

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

			# NOW set correct velocities from parent's interior space to world space
			var local_velocity = PhysicsServer3D.body_get_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
			var world_velocity = parent_world_transform.basis * local_velocity
			exterior_body.linear_velocity = world_velocity

			# Copy angular velocity
			var local_angvel = PhysicsServer3D.body_get_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
			var world_angvel = parent_world_transform.basis * local_angvel
			exterior_body.angular_velocity = world_angvel

			# Remove dock_proxy_body from parent's interior space
			PhysicsServer3D.body_set_space(dock_proxy_body, RID())

			# Clear reference to parent container
			docked_in_container = null

	is_docked = docked

static func get_world_transform(container: VehicleContainer) -> Transform3D:
	# Recursively calculate the world transform of a container
	# Handles arbitrary nesting depth (container in container in container...)
	if not container or not container.exterior_body:
		return Transform3D.IDENTITY

	if not container.is_docked or not container.dock_proxy_body.is_valid():
		# Container not docked - use exterior body directly
		return container.exterior_body.global_transform

	# Container is docked - calculate through parent
	var dock_transform = PhysicsServer3D.body_get_state(container.dock_proxy_body, PhysicsServer3D.BODY_STATE_TRANSFORM)
	var parent_container = container._get_docked_container()

	if parent_container and parent_container.exterior_body:
		# Recursively get parent's world transform
		var parent_world_transform = get_world_transform(parent_container)
		# Combine parent's world transform with this container's dock transform
		var result = parent_world_transform * dock_transform
		return result
	else:
		# Fallback if parent not found
		return container.exterior_body.global_transform

func _process(_delta: float) -> void:
	# Update exterior body visual based on docked state
	# This is needed for nested containers - the small container's exterior must follow its dock_proxy_body
	if is_docked and dock_proxy_body.is_valid() and exterior_body:
		# Container is docked: use recursive transform through parent chain
		var parent_container = _get_docked_container()
		if parent_container:
			var proxy_transform: Transform3D = PhysicsServer3D.body_get_state(dock_proxy_body, PhysicsServer3D.BODY_STATE_TRANSFORM)
			# Use recursive helper to get parent's world transform (handles nested containers)
			var parent_world_transform = VehicleContainer.get_world_transform(parent_container)
			# Transform from parent's interior space to world space
			var world_transform = parent_world_transform * proxy_transform
			exterior_body.global_transform = world_transform
	elif exterior_body:
		# Container in world space: exterior_body controls its own position
		pass

func _exit_tree() -> void:
	# Clean up proxy colliders
	for collider in interior_proxy_colliders:
		if collider.is_valid():
			PhysicsServer3D.free_rid(collider)

	# Clean up this container's physics space
	if container_interior_space.is_valid():
		PhysicsServer3D.free_rid(container_interior_space)

	# Clean up dock proxy body
	if dock_proxy_body.is_valid():
		PhysicsServer3D.free_rid(dock_proxy_body)
