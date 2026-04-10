class_name CharacterController
extends Node3D

## Character controller with world/proxy physics switching
## Handles movement in both world space and proxy interior spaces

@export var physics_proxy: PhysicsProxy
@export var move_speed: float = 5.0
@export var run_speed: float = 10.0
@export var jump_force: float = 5.0

# Multiplayer
var player_id: int = 1  # Set by GameManager on spawn

# Network-synced properties (using @export with MultiplayerSynchronizer)
@export var sync_position: Vector3 = Vector3.ZERO
@export var sync_velocity: Vector3 = Vector3.ZERO
@export var sync_is_in_vehicle: bool = false
@export var sync_is_in_container: bool = false

# Debug flags for network sync
var last_sync_pos: Vector3 = Vector3.ZERO
var sync_frame_count: int = 0

# Character bodies
var world_body_node: RigidBody3D  # Node wrapper so continuous_cd is accessible
var world_body: RID  # Character in main world (when outside vehicles)
var proxy_body: RID  # Character in proxy interior (when inside vehicles)
var character_visual: MeshInstance3D  # Character mesh

# State
var is_in_vehicle: bool = false  # Start OUTSIDE vehicle
var is_in_container: bool = false
var current_space: String = "space"  # Start in world space: 'vehicle_interior', 'space', 'container_interior'
var transition_lock: bool = false  # Prevents movement during transition frame

# Visual orientation transition
# Transitions smoothly when moving between spaces, but stays fixed when space rotates
var target_visual_basis: Basis = Basis.IDENTITY
var current_visual_basis: Basis = Basis.IDENTITY
var visual_orientation_speed: float = 5.0  # How fast to transition orientation
var is_reorienting: bool = false  # True during space transitions, false otherwise

# Input
var input_direction: Vector3 = Vector3.ZERO
var jump_pressed: bool = false
var is_running: bool = false

func _ready() -> void:
	_create_character_visual()
	_setup_multiplayer()

	# Create dynamic physics bodies for ALL players (local and remote)
	# This allows proper physics interaction and collisions
	# Remote players will have their position corrected to network position each frame
	_create_world_body()
	_create_proxy_body()

	# Start OUTSIDE vehicle in world space
	is_in_vehicle = false
	current_space = "space"

func _setup_multiplayer() -> void:
	# Setup multiplayer synchronizer for this character
	# Set authority for this node
	if player_id > 0:
		set_multiplayer_authority(player_id)
	else:
		set_multiplayer_authority(1)  # Default to server

	# Create and configure MultiplayerSynchronizer (Godot 4.5 best practice)
	var sync_node = MultiplayerSynchronizer.new()
	sync_node.name = "MultiplayerSynchronizer"

	# Configure BEFORE adding to tree
	sync_node.replication_config = _create_replication_config()

	add_child(sync_node)

	# Set root path AFTER adding to tree
	sync_node.root_path = get_path()

	# Different color for different players
	var has_authority = is_multiplayer_authority()

	if has_authority:
		# Local player - green
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.2, 1.0, 0.2)
		material.emission_enabled = true
		material.emission = Color(0.1, 0.3, 0.1)
		material.emission_energy_multiplier = 0.5
		character_visual.material_override = material
	else:
		# Remote player - blue
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.2, 0.2, 1.0)
		material.emission_enabled = true
		material.emission = Color(0.1, 0.1, 0.3)
		material.emission_energy_multiplier = 0.5
		character_visual.material_override = material

func _create_replication_config() -> SceneReplicationConfig:
	# Godot 4.5 best practice: Use SceneReplicationConfig for syncing properties
	var config = SceneReplicationConfig.new()

	# Sync position and state - using explicit NodePath syntax
	config.add_property(NodePath(".:sync_position"))
	config.add_property(NodePath(".:sync_velocity"))
	config.add_property(NodePath(".:sync_is_in_vehicle"))
	config.add_property(NodePath(".:sync_is_in_container"))

	# Configure sync mode - enable replication for all properties
	config.property_set_spawn(NodePath(".:sync_position"), true)
	config.property_set_spawn(NodePath(".:sync_velocity"), true)
	config.property_set_spawn(NodePath(".:sync_is_in_vehicle"), true)
	config.property_set_spawn(NodePath(".:sync_is_in_container"), true)

	config.property_set_replication_mode(NodePath(".:sync_position"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	config.property_set_replication_mode(NodePath(".:sync_velocity"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	config.property_set_replication_mode(NodePath(".:sync_is_in_vehicle"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	config.property_set_replication_mode(NodePath(".:sync_is_in_container"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)

	print("[SYNC_CONFIG] Created replication config for %s" % get_path())
	print("[SYNC_CONFIG]   Properties: sync_position, sync_velocity, sync_is_in_vehicle, sync_is_in_container")
	print("[SYNC_CONFIG]   Mode: REPLICATION_MODE_ALWAYS")

	return config

func _create_character_visual() -> void:
	# Character visual mesh
	character_visual = MeshInstance3D.new()
	character_visual.name = "CharacterVisual"
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.3
	capsule.height = 1.4
	character_visual.mesh = capsule
	character_visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.2, 1.0, 0.2)
	material.emission_enabled = true
	material.emission = Color(0.1, 0.3, 0.1)
	material.emission_energy_multiplier = 0.5
	character_visual.material_override = material

	add_child(character_visual)

func _create_world_body() -> void:
	# PhysicsServer3D.BODY_FLAG_CONTINUOUS_COLLISION_DETECTION is not exposed to GDScript in
	# Godot 4.7, so we use a RigidBody3D node which does expose continuous_cd.
	# All existing PhysicsServer3D calls still work via world_body_node.get_rid().
	world_body_node = RigidBody3D.new()
	world_body_node.name = "WorldBody"
	world_body_node.gravity_scale = 0.0   # Manual spherical gravity applied in _handle_movement
	world_body_node.lock_rotation = true  # No tumbling
	world_body_node.continuous_cd = true  # Sweep capsule each frame — no tunneling through terrain
	world_body_node.can_sleep = false
	world_body_node.collision_layer = 1
	world_body_node.collision_mask = 1
	world_body_node.linear_damp = 0.0
	world_body_node.angular_damp = 0.0

	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.3
	capsule.height = 1.4
	var cs := CollisionShape3D.new()
	cs.shape = capsule
	world_body_node.add_child(cs)

	add_child(world_body_node)
	world_body = world_body_node.get_rid()

	# Position at spawn point
	PhysicsServer3D.body_set_state(world_body, PhysicsServer3D.BODY_STATE_TRANSFORM,
			Transform3D(Basis(), global_position))

func _create_proxy_body() -> void:
	# Character body for proxy interiors (vehicles/containers)
	# Space will be dynamically set based on which vehicle/container player enters
	# Each vehicle/container has its own interior physics space for recursive nesting
	var capsule_shape := PhysicsServer3D.capsule_shape_create()
	PhysicsServer3D.shape_set_data(capsule_shape, {"radius": 0.3, "height": 1.4})

	proxy_body = PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(proxy_body, PhysicsServer3D.BODY_MODE_RIGID)
	# NOTE: Space not set here - will be dynamically set when entering vehicle/container
	PhysicsServer3D.body_add_shape(proxy_body, capsule_shape)
	PhysicsServer3D.body_set_state(proxy_body, PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), Vector3.ZERO))

	# Lock rotations for character
	PhysicsServer3D.body_set_axis_lock(proxy_body, PhysicsServer3D.BODY_AXIS_ANGULAR_X, true)
	PhysicsServer3D.body_set_axis_lock(proxy_body, PhysicsServer3D.BODY_AXIS_ANGULAR_Y, true)
	PhysicsServer3D.body_set_axis_lock(proxy_body, PhysicsServer3D.BODY_AXIS_ANGULAR_Z, true)

	# Enable collision settings
	PhysicsServer3D.body_set_collision_layer(proxy_body, 1)
	PhysicsServer3D.body_set_collision_mask(proxy_body, 1)
	PhysicsServer3D.body_set_state(proxy_body, PhysicsServer3D.BODY_STATE_CAN_SLEEP, false)

	# Add damping for stability in proxy space
	PhysicsServer3D.body_set_param(proxy_body, PhysicsServer3D.BODY_PARAM_LINEAR_DAMP, 0.1)
	PhysicsServer3D.body_set_param(proxy_body, PhysicsServer3D.BODY_PARAM_ANGULAR_DAMP, 1.0)

func _physics_process(delta: float) -> void:
	# Handle movement and synchronization
	var has_enet_peer = multiplayer.multiplayer_peer != null and multiplayer.multiplayer_peer is ENetMultiplayerPeer
	if has_enet_peer:
		var peer = multiplayer.multiplayer_peer as ENetMultiplayerPeer
		if peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			# Multiplayer mode - only local player moves
			if is_multiplayer_authority():
				_handle_movement(delta)
				_sync_state_to_network()
			else:
				# Remote player - apply synced state
				_apply_synced_state()
		else:
			# Connection not ready, don't do anything
			pass
	else:
		# Single-player mode - always handle movement
		_handle_movement(delta)
		_sync_state_to_network()

	# Clear transition lock AFTER movement is processed
	# This ensures movement is blocked for the full physics frame after position change
	if transition_lock:
		transition_lock = false

func _sync_state_to_network() -> void:
	# Sync position and state to other clients
	var current_body = proxy_body if is_in_vehicle or is_in_container else world_body
	if current_body.is_valid():
		var new_pos = PhysicsServer3D.body_get_state(current_body, PhysicsServer3D.BODY_STATE_TRANSFORM).origin
		var new_vel = PhysicsServer3D.body_get_state(current_body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)

		# Debug: Log when position changes significantly
		if sync_position.distance_to(new_pos) > 0.1:
			print("[SYNC_DEBUG] Player %d syncing position: %v -> %v" % [player_id, sync_position, new_pos])

		sync_position = new_pos
		sync_velocity = new_vel
	sync_is_in_vehicle = is_in_vehicle
	sync_is_in_container = is_in_container

func _apply_synced_state() -> void:
	# Apply synced state from network for remote players
	# Remote players have dynamic bodies that are position-corrected to network position
	if not is_multiplayer_authority():
		# Debug: Log sync_position every frame to see if it's changing
		sync_frame_count += 1
		if sync_frame_count % 60 == 0:  # Log every 60 frames
			print("[APPLY_SYNC_DEBUG] Player %d sync_position at frame %d: %v" % [player_id, sync_frame_count, sync_position])

		# Debug: Log when sync_position changes
		if last_sync_pos.distance_to(sync_position) > 0.01:  # Lower threshold
			print("[APPLY_SYNC_DEBUG] Player %d received position update: %v -> %v (distance: %.3f)" % [player_id, last_sync_pos, sync_position, last_sync_pos.distance_to(sync_position)])
			last_sync_pos = sync_position

		# Update state flags for remote players
		is_in_vehicle = sync_is_in_vehicle
		is_in_container = sync_is_in_container

		# Position correction for dynamic body
		# Smoothly move the body toward the networked position
		var current_body = proxy_body if is_in_vehicle or is_in_container else world_body
		if current_body.is_valid():
			var current_pos = PhysicsServer3D.body_get_state(current_body, PhysicsServer3D.BODY_STATE_TRANSFORM).origin
			var position_error = sync_position - current_pos

			# If error is large, teleport. Otherwise use velocity correction
			if position_error.length() > 2.0:
				# Large error - teleport
				var body_transform = Transform3D(Basis(), sync_position)
				PhysicsServer3D.body_set_state(current_body, PhysicsServer3D.BODY_STATE_TRANSFORM, body_transform)
				PhysicsServer3D.body_set_state(current_body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
			else:
				# Small error - use velocity to smoothly correct
				var correction_velocity = position_error * 10.0  # Correction strength
				PhysicsServer3D.body_set_state(current_body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, correction_velocity)

		# Visual position will be updated in _update_character_visual_position
		# based on the actual physics body position

func _process(delta: float) -> void:
	# Update visual orientation transition (only when changing spaces)
	_update_visual_orientation_transition(delta)
	
	# Update visual every frame for smooth rendering (not just physics frames)
	_update_character_visual_position(delta)

func _update_visual_orientation_transition(delta: float) -> void:
	# During space transitions, smoothly interpolate toward target
	# During normal movement within a space, instantly match the space orientation
	# This is controlled by is_reorienting flag set during space changes

	if is_reorienting and not current_visual_basis.is_equal_approx(target_visual_basis):
		# Use slerp for smooth rotation transition between spaces
		var current_quat = Quaternion(current_visual_basis)
		var target_quat = Quaternion(target_visual_basis)
		var interpolated_quat = current_quat.slerp(target_quat, visual_orientation_speed * delta)
		current_visual_basis = Basis(interpolated_quat)

		# Check if transition is complete
		if current_visual_basis.is_equal_approx(target_visual_basis):
			is_reorienting = false
	else:
		# Not transitioning - instantly match the target (which tracks current space)
		current_visual_basis = target_visual_basis

func _handle_movement(delta: float) -> void:
	# Use appropriate physics body based on current space
	var current_body = proxy_body if is_in_vehicle or is_in_container else world_body
	if not current_body.is_valid():
		return

	# Block movement during transition frame
	if transition_lock:
		return

	# Get current velocity
	var velocity: Vector3 = PhysicsServer3D.body_get_state(current_body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)

	# Track grounded state and gravity direction for movement section below
	var is_grounded := false
	var to_center   := Vector3.DOWN   # updated in world-space branch

	# Apply gravity manually in all spaces
	if is_in_vehicle or is_in_container:
		# Proxy interior: flat -Y gravity
		if physics_proxy and physics_proxy.gravity_enabled:
			velocity.y -= 9.81 * delta
	else:
		# World space: gravity toward planet center (spherical planet)
		var body_tf: Transform3D = PhysicsServer3D.body_get_state(current_body, PhysicsServer3D.BODY_STATE_TRANSFORM)
		to_center = (Vector3(0.0, -PlanetTerrain.PLANET_RADIUS, 0.0) - body_tf.origin).normalized()
		velocity += to_center * 20.0 * delta

		# Atmospheric drag — no effect below DRAG_START so slow movements are unaffected.
		# Above it, drag scales linearly to equal gravity at TERMINAL_VELOCITY (40 m/s).
		const TERMINAL_VELOCITY : float = 40.0
		const DRAG_START        : float = 5.0
		var fall_speed : float = velocity.dot(to_center)   # positive = falling inward
		if fall_speed > DRAG_START:
			var drag_accel : float = ((fall_speed - DRAG_START) / (TERMINAL_VELOCITY - DRAG_START)) * 20.0
			velocity -= to_center * drag_accel * delta

		# ── Buoyancy: 4 bottom corners of the player capsule ──────────────────
		# The capsule is ~0.4 radius, ~1.8 tall — corners at foot level.
		const PLAYER_HW : float = 0.4
		const PLAYER_HH : float = 0.9
		var up : Vector3 = -to_center
		var total_depth : float = 0.0
		var wet_count   : int   = 0
		var foot_corners : Array[Vector3] = [
			Vector3(-PLAYER_HW, -PLAYER_HH, -PLAYER_HW),
			Vector3( PLAYER_HW, -PLAYER_HH, -PLAYER_HW),
			Vector3(-PLAYER_HW, -PLAYER_HH,  PLAYER_HW),
			Vector3( PLAYER_HW, -PLAYER_HH,  PLAYER_HW),
		]
		for lc in foot_corners:
			var wc    : Vector3 = body_tf * lc
			var wy    : float   = PlanetTerrain.water_surface_y(wc.x, wc.z)
			var depth : float   = wy - wc.y
			if depth > 0.0:
				total_depth += depth
				wet_count   += 1
		if wet_count > 0:
			var avg_depth  : float = total_depth / float(wet_count)
			# Cap effective depth so being far underwater doesn't launch the player
			# violently past the surface. Equilibrium: buoyancy = gravity at 1 unit depth.
			var buoy_depth : float = minf(avg_depth, 2.0)
			velocity += up * (buoy_depth * 20.0) * delta
			# Water drag — apply after so full-speed swimmers slow gradually
			var drag : float = 1.0 - clamp(4.0 * delta, 0.0, 0.7)
			velocity *= drag

	# Grounded check — used to switch between tight ground control and airborne 6DOF
	is_grounded = _check_ground(current_body)

	# Apply horizontal movement
	# Grounded (or proxy interior): hard-override lateral velocity for tight ground control.
	# Airborne (world space, not grounded): gentle 6DOF air-control — add acceleration without
	# zeroing momentum so the player drifts naturally while still being steerable.
	if is_in_vehicle or is_in_container:
		if input_direction.length() > 0:
			var current_speed = run_speed if is_running else move_speed
			var move_vec = input_direction.normalized() * current_speed
			velocity.x = move_vec.x
			velocity.z = move_vec.z
		else:
			velocity.x = lerp(velocity.x, 0.0, 0.5)
			velocity.z = lerp(velocity.z, 0.0, 0.5)
			if abs(velocity.x) < 0.1:
				velocity.x = 0.0
			if abs(velocity.z) < 0.1:
				velocity.z = 0.0
	elif is_grounded:
		if input_direction.length() > 0:
			var current_speed = run_speed if is_running else move_speed
			var move_vec = input_direction.normalized() * current_speed
			velocity.x = move_vec.x
			velocity.z = move_vec.z
		else:
			velocity.x = lerp(velocity.x, 0.0, 0.5)
			velocity.z = lerp(velocity.z, 0.0, 0.5)
			if abs(velocity.x) < 0.1:
				velocity.x = 0.0
			if abs(velocity.z) < 0.1:
				velocity.z = 0.0
	else:
		# Airborne 6DOF: accelerate toward input direction; preserve existing momentum.
		if input_direction.length() > 0:
			const AIR_ACCEL       : float = 15.0
			const AIR_MAX_LATERAL : float = 20.0
			var up := -to_center
			# Strip gravity-aligned component so input stays on the surface plane
			var lateral_input := input_direction - up * input_direction.dot(up)
			if lateral_input.length() > 0.001:
				velocity += lateral_input.normalized() * AIR_ACCEL * delta
				# Cap lateral speed so the player can't accelerate indefinitely in air
				var fall_component := to_center * velocity.dot(to_center)
				var lat_vel        := velocity - fall_component
				if lat_vel.length() > AIR_MAX_LATERAL:
					velocity = lat_vel.normalized() * AIR_MAX_LATERAL + fall_component

	# Jump (only when on ground - use raycast)
	if jump_pressed:
		var can_jump = _check_ground(current_body)
		if can_jump:
			if is_in_vehicle or is_in_container:
				velocity.y = jump_force
			else:
				# World space: jump away from planet center
				var body_tf2: Transform3D = PhysicsServer3D.body_get_state(current_body, PhysicsServer3D.BODY_STATE_TRANSFORM)
				var up: Vector3 = (body_tf2.origin - Vector3(0.0, -PlanetTerrain.PLANET_RADIUS, 0.0)).normalized()
				velocity += up * jump_force

	# Set velocity
	PhysicsServer3D.body_set_state(current_body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, velocity)

func _update_character_visual_position(delta: float) -> void:
	# Handle smooth orientation transition when changing spaces
	if is_reorienting:
		# Slerp current_visual_basis toward target_visual_basis
		if not current_visual_basis.is_equal_approx(target_visual_basis):
			var current_quat = Quaternion(current_visual_basis)
			var target_quat = Quaternion(target_visual_basis)
			var interpolated_quat = current_quat.slerp(target_quat, visual_orientation_speed * delta)
			current_visual_basis = Basis(interpolated_quat)

			# Check if transition is complete
			if current_visual_basis.is_equal_approx(target_visual_basis):
				is_reorienting = false
		else:
			is_reorienting = false

	# REMOTE PLAYER: Use synced position directly (no physics body)
	# Only for remote players in actual multiplayer (not offline/single-player)
	var has_enet_peer = multiplayer.multiplayer_peer != null and multiplayer.multiplayer_peer is ENetMultiplayerPeer
	if has_enet_peer:
		var peer = multiplayer.multiplayer_peer as ENetMultiplayerPeer
		if peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			if not is_multiplayer_authority():
				_update_remote_player_visual()
				return

	# LOCAL PLAYER: Update character visual based on current physics space
	# Uses transitioning basis for smooth orientation changes
	# Also updates target orientation to match current space
	if is_in_container and proxy_body.is_valid():
		# Character in container interior - position relative to container
		# With recursive nesting, proxy_pos is already in container's local coordinate system
		var proxy_transform: Transform3D = PhysicsServer3D.body_get_state(proxy_body, PhysicsServer3D.BODY_STATE_TRANSFORM)
		var proxy_pos = proxy_transform.origin

		# Find the SPECIFIC container that the player is in by checking physics spaces
		var player_space = PhysicsServer3D.body_get_space(proxy_body)
		var game_manager = get_parent()
		if game_manager:
			for child in game_manager.get_children():
				if child is VehicleContainer:
					var container := child as VehicleContainer
					var container_space: RID = container.get_interior_space()
					# Check if this is the container the player is actually in
					if container_space == player_space and container.exterior_body:
						# Get the container's world transform (handles recursive nesting)
						var container_world_transform: Transform3D = VehicleContainer.get_world_transform(container)
						var container_world_basis: Basis = container_world_transform.basis

						# Update target to track container's world orientation
						target_visual_basis = container_world_basis

						# Transform proxy position to world space
						var world_pos = container_world_transform.origin + container_world_basis * proxy_pos
						character_visual.global_position = world_pos
						character_visual.global_transform.basis = current_visual_basis

						break
	elif is_in_vehicle and proxy_body.is_valid():
		# Character in vehicle interior - position relative to vehicle
		var proxy_transform: Transform3D = PhysicsServer3D.body_get_state(proxy_body, PhysicsServer3D.BODY_STATE_TRANSFORM)
		var proxy_pos = proxy_transform.origin

		# Find vehicle through parent tree
		var game_manager = get_parent()
		if game_manager:
			for child in game_manager.get_children():
				if child is Vehicle:
					var vehicle := child as Vehicle

					# CRITICAL: If vehicle is docked, need to use dock_proxy position + container transform
					if vehicle.is_docked and vehicle.dock_proxy_body.is_valid():
						# Get ship's dock_proxy position in container space
						var ship_dock_transform: Transform3D = PhysicsServer3D.body_get_state(vehicle.dock_proxy_body, PhysicsServer3D.BODY_STATE_TRANSFORM)

						# Transform player proxy_pos (in ship interior space) to container space
						var container_proxy_pos = ship_dock_transform.origin + ship_dock_transform.basis * proxy_pos

						# Find which container the ship is docked in
						var docked_container = vehicle._get_docked_container()
						if docked_container and docked_container.exterior_body:
							# CRITICAL: Use recursive transform to handle nested containers
							var container_world_transform = VehicleContainer.get_world_transform(docked_container)
							var container_basis = container_world_transform.basis

							# Update target to track ship's orientation in world space
							var ship_world_basis = container_basis * ship_dock_transform.basis
							target_visual_basis = ship_world_basis

							# Transform to world space through (potentially nested) container
							var world_pos = container_world_transform.origin + container_basis * container_proxy_pos
							character_visual.global_position = world_pos
							# Use transitioning basis (smoothly follows target)
							character_visual.global_transform.basis = current_visual_basis
					elif vehicle.exterior_body:
						# Vehicle not docked - use exterior body transform
						var vehicle_transform = vehicle.exterior_body.global_transform
						var vehicle_basis = vehicle_transform.basis

						# Update target to track ship's orientation
						target_visual_basis = vehicle_basis

						# Transform proxy position to world space
						var world_pos = vehicle_transform.origin + vehicle_basis * proxy_pos
						character_visual.global_position = world_pos
						# Use transitioning basis (smoothly follows target)
						character_visual.global_transform.basis = current_visual_basis
					break
	elif not is_in_vehicle and not is_in_container and world_body.is_valid():
		# Character in world space
		var world_transform: Transform3D = PhysicsServer3D.body_get_state(world_body, PhysicsServer3D.BODY_STATE_TRANSFORM)
		character_visual.global_position = world_transform.origin

		# Update target to world up
		target_visual_basis = Basis.IDENTITY

		# Use transitioning basis (smoothly follows target)
		character_visual.global_transform.basis = current_visual_basis

	# Character visibility handled by camera system
	# Don't set visibility here - let dual_camera_view control it

func _update_remote_player_visual() -> void:
	# For remote players (no physics bodies), position visual based on synced data
	var game_manager = get_parent()
	if not game_manager:
		character_visual.global_position = sync_position
		return

	# Remote player in container
	if sync_is_in_container:
		# Find which container by checking all containers
		for child in game_manager.get_children():
			if child is VehicleContainer:
				var container = child
				if is_instance_valid(container) and container.exterior_body:
					# Use recursive transform to handle nested containers
					var container_world_transform = VehicleContainer.get_world_transform(container)
					var container_world_basis = container_world_transform.basis

					# Transform sync_position (in container's local space) to world space
					var world_pos = container_world_transform.origin + container_world_basis * sync_position
					character_visual.global_position = world_pos
					character_visual.global_transform.basis = container_world_basis
					return

	# Remote player in vehicle
	elif sync_is_in_vehicle:
		# Find vehicle
		for child in game_manager.get_children():
			if child is Vehicle:
				var vehicle = child
				if is_instance_valid(vehicle):
					# Check if vehicle is docked
					if vehicle.is_docked and vehicle.dock_proxy_body.is_valid():
						var ship_dock_transform = PhysicsServer3D.body_get_state(vehicle.dock_proxy_body, PhysicsServer3D.BODY_STATE_TRANSFORM)
						var container_proxy_pos = ship_dock_transform.origin + ship_dock_transform.basis * sync_position

						var docked_container = vehicle._get_docked_container()
						if docked_container and docked_container.exterior_body:
							var container_world_transform = VehicleContainer.get_world_transform(docked_container)
							var container_basis = container_world_transform.basis
							var world_pos = container_world_transform.origin + container_basis * container_proxy_pos
							character_visual.global_position = world_pos
							character_visual.global_transform.basis = container_basis * ship_dock_transform.basis
					elif vehicle.exterior_body:
						# Vehicle not docked
						var vehicle_transform = vehicle.exterior_body.global_transform
						var vehicle_basis = vehicle_transform.basis
						var world_pos = vehicle_transform.origin + vehicle_basis * sync_position
						character_visual.global_position = world_pos
						character_visual.global_transform.basis = vehicle_basis
					return

	# Remote player in world space
	else:
		character_visual.global_position = sync_position
		character_visual.global_transform.basis = Basis.IDENTITY

func _check_ground(body: RID) -> bool:
	# Raycast downward to check if on ground
	if not body.is_valid():
		return false

	# Get body position
	var body_transform: Transform3D = PhysicsServer3D.body_get_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM)
	var from = body_transform.origin
	# "Down" toward planet center in world space; flat -Y in proxy interiors
	var down := Vector3(0.0, -1.0, 0.0)
	if not (is_in_vehicle or is_in_container):
		down = (Vector3(0.0, -PlanetTerrain.PLANET_RADIUS, 0.0) - from).normalized()
	var to = from + down * 1.15  # capsule bottom (1.0) + small skin

	# Get the space the body is in
	var space = PhysicsServer3D.body_get_space(body)

	# Create ray parameters
	var ray_params = PhysicsRayQueryParameters3D.new()
	ray_params.from = from
	ray_params.to = to
	ray_params.exclude = [body]  # Don't hit self

	# Perform raycast using PhysicsDirectSpaceState3D
	var space_state = PhysicsServer3D.space_get_direct_state(space)
	var result = space_state.intersect_ray(ray_params)

	return not result.is_empty()

func set_input_direction(direction: Vector3) -> void:
	input_direction = direction

func set_jump(pressed: bool) -> void:
	jump_pressed = pressed

func set_running(running: bool) -> void:
	is_running = running

func enter_vehicle(should_transition: bool = true, initial_basis: Basis = Basis.IDENTITY) -> void:
	is_in_vehicle = true
	current_space = "vehicle_interior"
	is_reorienting = should_transition  # Start smooth orientation transition only if requested

	# Set target for smooth transition
	if should_transition:
		target_visual_basis = initial_basis

func exit_vehicle(should_transition: bool = true, target_basis: Basis = Basis.IDENTITY) -> void:
	is_in_vehicle = false
	current_space = "space"
	is_reorienting = should_transition  # Start smooth orientation transition only if requested

	# Set target for smooth transition
	if should_transition:
		target_visual_basis = target_basis

func enter_container(should_transition: bool = true, target_basis: Basis = Basis.IDENTITY) -> void:
	is_in_container = true
	is_in_vehicle = false
	current_space = "container_interior"
	is_reorienting = should_transition  # Start smooth orientation transition only if requested

	# Set target for smooth transition
	if should_transition:
		target_visual_basis = target_basis

func exit_container(should_transition: bool = true, target_basis: Basis = Basis.IDENTITY) -> void:
	is_in_container = false
	current_space = "space"
	is_reorienting = should_transition  # Start smooth orientation transition only if requested

	# Set target for smooth transition
	if should_transition:
		target_visual_basis = target_basis

func set_target_visual_orientation(new_basis: Basis) -> void:
	# Set target orientation for smooth transition between spaces
	# NOTE: This function is no longer used - orientation is tracked automatically
	target_visual_basis = new_basis

func initialize_visual_orientation(initial_basis: Basis) -> void:
	# Initialize orientation at game start (no transition)
	# Sets both current and target so there's no initial lerp
	target_visual_basis = initial_basis
	current_visual_basis = initial_basis

func get_proxy_position() -> Vector3:
	if proxy_body.is_valid():
		var body_transform: Transform3D = PhysicsServer3D.body_get_state(proxy_body, PhysicsServer3D.BODY_STATE_TRANSFORM)
		return body_transform.origin
	return Vector3.ZERO

func get_world_position() -> Vector3:
	if world_body.is_valid():
		var body_transform: Transform3D = PhysicsServer3D.body_get_state(world_body, PhysicsServer3D.BODY_STATE_TRANSFORM)
		return body_transform.origin
	return Vector3.ZERO

func get_proxy_velocity() -> Vector3:
	if proxy_body.is_valid():
		return PhysicsServer3D.body_get_state(proxy_body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
	return Vector3.ZERO

func get_world_velocity() -> Vector3:
	if world_body.is_valid():
		return PhysicsServer3D.body_get_state(world_body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
	return Vector3.ZERO

func set_proxy_position(pos: Vector3, velocity: Vector3 = Vector3.ZERO) -> void:
	if proxy_body.is_valid():
		var body_transform: Transform3D = PhysicsServer3D.body_get_state(proxy_body, PhysicsServer3D.BODY_STATE_TRANSFORM)
		body_transform.origin = pos
		PhysicsServer3D.body_set_state(proxy_body, PhysicsServer3D.BODY_STATE_TRANSFORM, body_transform)
		# Preserve velocity for seamless transition (or reset if Vector3.ZERO passed)
		PhysicsServer3D.body_set_state(proxy_body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, velocity)
		PhysicsServer3D.body_set_state(proxy_body, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
		# Lock movement for one frame to prevent input from pushing player
		transition_lock = true

func set_world_position(pos: Vector3, velocity: Vector3 = Vector3.ZERO) -> void:
	if world_body.is_valid():
		var body_transform: Transform3D = PhysicsServer3D.body_get_state(world_body, PhysicsServer3D.BODY_STATE_TRANSFORM)
		body_transform.origin = pos
		PhysicsServer3D.body_set_state(world_body, PhysicsServer3D.BODY_STATE_TRANSFORM, body_transform)
		# Preserve velocity for seamless transition (or reset if Vector3.ZERO passed)
		PhysicsServer3D.body_set_state(world_body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, velocity)
		PhysicsServer3D.body_set_state(world_body, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
		# Lock movement for one frame to prevent input from pushing player
		transition_lock = true

## Multiplayer RPC methods for interior transitions
@rpc("any_peer", "call_remote", "reliable")
func rpc_enter_vehicle_interior(_interior_space_id: int, local_pos: Vector3, local_velocity: Vector3, should_transition: bool, target_basis_data: Array) -> void:
	# Called on remote clients when a player enters a vehicle
	var target_basis = Basis(Vector3(target_basis_data[0], target_basis_data[1], target_basis_data[2]),
							 Vector3(target_basis_data[3], target_basis_data[4], target_basis_data[5]),
							 Vector3(target_basis_data[6], target_basis_data[7], target_basis_data[8]))
	enter_vehicle(should_transition, target_basis)
	set_proxy_position(local_pos, local_velocity)

@rpc("any_peer", "call_remote", "reliable")
func rpc_exit_vehicle_interior(world_pos: Vector3, world_velocity: Vector3, should_transition: bool, target_basis_data: Array) -> void:
	# Called on remote clients when a player exits a vehicle
	var target_basis = Basis(Vector3(target_basis_data[0], target_basis_data[1], target_basis_data[2]),
							 Vector3(target_basis_data[3], target_basis_data[4], target_basis_data[5]),
							 Vector3(target_basis_data[6], target_basis_data[7], target_basis_data[8]))
	exit_vehicle(should_transition, target_basis)
	set_world_position(world_pos, world_velocity)

@rpc("any_peer", "call_remote", "reliable")
func rpc_enter_container_interior(_interior_space_id: int, local_pos: Vector3, local_velocity: Vector3, should_transition: bool, target_basis_data: Array) -> void:
	# Called on remote clients when a player enters a container
	var target_basis = Basis(Vector3(target_basis_data[0], target_basis_data[1], target_basis_data[2]),
							 Vector3(target_basis_data[3], target_basis_data[4], target_basis_data[5]),
							 Vector3(target_basis_data[6], target_basis_data[7], target_basis_data[8]))
	enter_container(should_transition, target_basis)
	set_proxy_position(local_pos, local_velocity)

@rpc("any_peer", "call_remote", "reliable")
func rpc_exit_container_interior(world_pos: Vector3, world_velocity: Vector3, should_transition: bool, target_basis_data: Array) -> void:
	# Called on remote clients when a player exits a container
	var target_basis = Basis(Vector3(target_basis_data[0], target_basis_data[1], target_basis_data[2]),
							 Vector3(target_basis_data[3], target_basis_data[4], target_basis_data[5]),
							 Vector3(target_basis_data[6], target_basis_data[7], target_basis_data[8]))
	exit_container(should_transition, target_basis)
	set_world_position(world_pos, world_velocity)

func _exit_tree() -> void:
	# Clean up physics bodies
	if world_body.is_valid():
		PhysicsServer3D.free_rid(world_body)
	if proxy_body.is_valid():
		PhysicsServer3D.free_rid(proxy_body)
