# © 2026 Cristian Luis Celie. All rights reserved. Portfolio excerpt from Era Breaker: shared for review only, not licensed for use, copying or redistribution.
class_name QuadrupedMotion
extends RefCounted
## Physical locomotion only. Enemy/PrimalEnemyAI own goals and attack permission;
## this controller never moves positions directly or causes damage.
const GRAVITY := 1800.0
const RUN_ACCEL := 420.0
const TURN_BRAKE := 680.0
const WINDUP_BRAKE := 740.0
const LAND_BRAKE := 900.0
const IMPACT_DRAG := 220.0
const MAX_LEAP_SPEED := 420.0
const SOLE_SIZE := Vector2(98,4)
const SOLE_CENTER_X := 0.0

var ground_normal := Vector2.UP
var measured_velocity := Vector2.ZERO
var landing_strength := 0.0
var leap_active := false
var leap_age := 0.0
var leap_duration := 0.0
var phase := "ground"
var correction_count := 0
var _before := Vector2.ZERO
var _before_velocity := Vector2.ZERO
var _was_grounded := false
var _terrain_cd := 0.0
var _route_wait := 0.0
var _route_goal := Vector2.ZERO
var _edge_direction := 0.0

func configure(e: CharacterBody2D) -> void:
	e.floor_stop_on_slope = true
	e.floor_constant_speed = true
	e.floor_snap_length = 14.0
	e.floor_max_angle = deg_to_rad(48.0)
	e.safe_margin = 0.04
	_before = e.global_position
	ground_normal = _terrain_normal(e)
	fit_support(e)

func begin_step(e: CharacterBody2D, delta: float) -> void:
	_before = e.global_position
	_before_velocity = e.velocity
	_was_grounded = e.is_on_floor()
	_terrain_cd = maxf(0.0,_terrain_cd-delta)
	landing_strength = move_toward(landing_strength,0.0,delta*4.0)
	if leap_active:
		leap_age += delta
	if e.is_on_floor():
		ground_normal = e.get_floor_normal()
	elif not leap_active:
		ground_normal = _terrain_normal(e)

func drive(e: CharacterBody2D, wanted_x: float, delta: float, state: String = "run") -> void:
	# Once launched, neither chasing nor recovery may steer a committed leap.
	# Collision resolution and incoming impulses remain authoritative in air.
	if not e.is_on_floor() or e.velocity.y < -1.0:
		return
	if _route_wait > 0.0 and state == "run":
		return
	if state == "run" and phase == "edge_wait":
		if signf(wanted_x) == _edge_direction:
			wanted_x = 0.0
		else:
			phase = "ground"
			_edge_direction = 0.0
	if state == "run" and signf(wanted_x) != e.rig.facing and absf(e.velocity.x) <= 22.0:
		# Let the rig perform its visible turn at rest before accelerating out
		# of it. Actual facing, not a requested-but-unfinished mirror, wins.
		wanted_x = 0.0
	if state == "run" and absf(wanted_x) > 0.01:
		wanted_x = _pack_speed(e,wanted_x)
	var rate := RUN_ACCEL
	if state == "hurt":
		rate = IMPACT_DRAG
	elif state in ["windup","telegraph"]:
		rate = WINDUP_BRAKE
	elif state in ["recover","landing"]:
		rate = LAND_BRAKE
	elif is_zero_approx(wanted_x) or e.velocity.x * wanted_x < 0.0:
		rate = TURN_BRAKE
	e.velocity.x = move_toward(e.velocity.x,wanted_x,rate*delta)

func launch_attack(e: CharacterBody2D, old_target: Vector2) -> float:
	_route_wait = 0.0
	var head_offset: float = e.rig.head_target_global().x-e.global_position.x
	var direction := -1.0 if old_target.x < e.global_position.x else 1.0
	# Commit the jaw, not the hindquarters, to the announced point. A close
	# target produces a short bite leap instead of a forced 330-px/s overshoot.
	var travel := maxf(0.0,(old_target.x-head_offset-e.global_position.x)*direction)
	travel = minf(travel,220.0)
	var goal := Vector2(e.global_position.x+direction*travel,e.global_position.y)
	var floor_y := _floor(e,goal.x)
	if is_finite(floor_y):
		goal.y = clampf(floor_y,e.global_position.y-80.0,e.global_position.y+80.0)
	var flight := clampf(travel/340.0,0.42,0.58)
	return _launch(e,goal,flight)

func _launch(e: CharacterBody2D, goal: Vector2, flight: float) -> float:
	var displacement := goal-e.global_position
	e.velocity = Vector2(clampf(displacement.x/flight,-MAX_LEAP_SPEED,MAX_LEAP_SPEED),
		displacement.y/flight-GRAVITY*flight*0.5)
	leap_active = true
	leap_age = 0.0
	leap_duration = flight
	phase = "leap"
	_edge_direction = 0.0
	_terrain_cd = 0.75
	return flight

func prepare_physics(e: CharacterBody2D, delta: float, allow_route: bool) -> void:
	fit_support(e)
	if e.is_on_floor() and e.velocity.y >= 0.0:
		# Small real gravity pressure keeps contact stable when stopping on ramps.
		e.velocity.y = GRAVITY*delta
	elif not e.is_on_floor():
		e.velocity.y += GRAVITY*delta
	if not allow_route or e._stagger > 0.0:
		_route_wait = 0.0
		return
	if _route_wait > 0.0:
		_route_wait -= delta
		drive(e,0.0,delta,"windup")
		e.rig.set_action("windup",1.0-_route_wait/0.18)
		if _route_wait <= 0.0 and e.is_on_floor():
			_launch(e,_route_goal,clampf(absf(_route_goal.x-e.global_position.x)/380.0,0.43,0.80))
		return
	if not e.is_on_floor() or leap_active or _terrain_cd > 0.0:
		return
	var direction := signf(e.velocity.x) if absf(e.velocity.x)>=12.0 else _edge_direction
	if is_zero_approx(direction):
		return
	var size := absf(e.rig.scale.x)
	var ahead := e.global_position.x+direction*(39.0*size+26.0)
	var here_y := _floor(e,e.global_position.x)
	var ahead_y := _floor(e,ahead)
	if not is_finite(here_y):
		return
	if is_finite(ahead_y) and ahead_y >= here_y-16.0:
		if phase == "edge_wait":
			phase = "ground"
			_edge_direction = 0.0
		return
	var destination := Vector2.ZERO
	var found := false
	for distance: float in range(110,341,12):
		var landing_x := e.global_position.x+direction*distance
		var landing_y := _floor(e,landing_x)
		if not is_finite(landing_y) or absf(landing_y-here_y) > 96.0:
			continue
		# Both foot pairs and their real support span must land on the platform,
		# not only a snout/root probe that leaves hind paws over the abyss.
		var landing_root := landing_x+direction*30.0*size
		var root_y := _floor(e,landing_root)
		if not is_finite(root_y) or absf(root_y-landing_y) > 30.0:
			continue
		var half_span := SOLE_SIZE.x*size*0.5+6.0
		var front_y := _floor(e,landing_root+half_span)
		var rear_y := _floor(e,landing_root-half_span)
		if not is_finite(front_y) or not is_finite(rear_y) \
				or absf(front_y-root_y)>30.0 or absf(rear_y-root_y)>30.0:
			continue
		if absf(landing_root-e.global_position.x) > MAX_LEAP_SPEED*0.80:
			continue
		destination = Vector2(landing_root,root_y)
		found = true
		break
	if found:
		_route_goal = destination
		_route_wait = 0.18
		phase = "windup"
		_edge_direction = 0.0
	else:
		# A gap beyond the physical leap stays a gap. Brake at the edge, never
		# teleport to the player or jump toward a nonexistent landing surface.
		drive(e,0.0,delta,"landing")
		phase = "edge_wait"
		_edge_direction = direction

func fit_support(e: CharacterBody2D) -> void:
	if not is_instance_valid(e._quad_foot_support):
		return
	var normal := ground_normal.normalized()
	if normal.y > -0.25:
		normal = Vector2.UP
	var slope := -normal.x/normal.y
	var size := absf(e.rig.scale.y)
	var middle: float = SOLE_CENTER_X*e.rig.scale.x
	e._quad_foot_support.position = Vector2(middle,slope*middle)+normal*(SOLE_SIZE.y*size*0.5)
	e._quad_foot_support.rotation = atan(slope)

func after_physics(e: CharacterBody2D, delta: float) -> void:
	measured_velocity = (e.global_position-_before)/maxf(0.001,delta)
	var landing_event := 0.0
	if e.is_on_floor():
		ground_normal = e.get_floor_normal()
		if not _was_grounded and _before_velocity.y > 70.0:
			landing_strength = clampf(_before_velocity.y/600.0,0.0,1.0)
			landing_event = landing_strength
			phase = "landing"
		if leap_active and leap_age > 0.06:
			leap_active = false
		elif not leap_active and landing_strength < 0.05 and _route_wait <= 0.0 and phase != "edge_wait":
			phase = "ground"
	if leap_active:
		e.rig.set_action("leap",1.0)
	if e.rig.has_method("set_leap_phase"):
		e.rig.set_leap_phase(clampf(leap_age/maxf(0.01,leap_duration),0.0,1.0) if leap_active else -1.0,
			e.velocity)
	if e.rig.has_method("set_ground_support"):
		e.rig.set_ground_support(ground_normal,e.is_on_floor(),measured_velocity,landing_event)
	if e.rig.has_method("set_altitude"):
		var chest_x: float = e.rig.to_global(Vector2(SOLE_CENTER_X,0)).x
		var shadow_floor := _floor(e,chest_x)
		# The signed offset also matters on slopes: the support under the chest
		# can be higher than the hind-foot origin. INF means no ground shadow.
		e.rig.set_altitude(shadow_floor-e.rig.global_position.y \
			if is_finite(shadow_floor) else INF)

func impact(e: CharacterBody2D, direction: Vector2, fraction: float) -> void:
	var strength := clampf(fraction,0.0,1.0)
	var impulse := direction.normalized()*(55.0+strength*165.0)
	e.velocity.x = clampf(e.velocity.x+impulse.x,-520.0,520.0)
	if strength >= 0.26 and e.is_on_floor():
		e.velocity.y = minf(e.velocity.y,-45.0-strength*45.0)
	e._stagger = maxf(e._stagger,0.10+strength*0.20)
	_route_wait = 0.0
	phase = "hurt"

func _terrain_normal(e: CharacterBody2D) -> Vector2:
	var a := _floor(e,e.global_position.x-12.0)
	var b := _floor(e,e.global_position.x+12.0)
	if is_finite(a) and is_finite(b) and absf(a-b) < 20.0:
		return Vector2((b-a)/24.0,-1.0).normalized()
	return Vector2.UP

func _pack_speed(e: CharacterBody2D, wanted_x: float) -> float:
	# Dogs collide physically with the world only. A ground pack queues using
	# chest spacing and measured leader speed, never treats a neck as a floor
	# and never generates an upward separation impulse or position correction.
	var direction := signf(wanted_x)
	var allowed := absf(wanted_x)
	var own_body: CollisionShape2D = e.get_node("Hitbox")
	for other: Node in e.get_tree().get_nodes_in_group("enemies"):
		if other == e or not is_instance_valid(other) or bool(other.get("dead")) \
				or other.get("_quad_motion") == null or not other.is_on_floor():
			continue
		var body: CollisionShape2D = other.get_node("Hitbox")
		var ahead: float = (body.global_position.x-own_body.global_position.x)*direction
		if absf(body.global_position.y-own_body.global_position.y) > 35.0:
			continue
		if ahead < -0.5 or (absf(ahead) <= 0.5 and other.get_instance_id() > e.get_instance_id()):
			continue
		var spacing: float = (own_body.shape.size.x+body.shape.size.x)*0.5+12.0
		if ahead > spacing+60.0:
			continue
		var lead_speed: float = maxf(0.0,other._quad_motion.measured_velocity.x*direction)
		allowed = minf(allowed,maxf(0.0,lead_speed+(ahead-spacing)*2.8))
	return direction*allowed

func _floor(e: Node2D, x: float) -> float:
	var level := e.get_tree().get_first_node_in_group("level")
	return float(level.floor_y_at(x)) if level != null and level.has_method("floor_y_at") else INF
