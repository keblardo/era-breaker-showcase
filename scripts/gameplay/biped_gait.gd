# © 2026 Cristian Luis Celie. All rights reserved. Portfolio excerpt from Era Breaker: shared for review only, not licensed for use, copying or redistribution.
class_name BipedGait
extends RefCounted
## Two grounded contacts, not two sine-rotated legs. Only swing feet move in
## world space; the rig solves its fixed-length bones against those contacts.
## Standalone art previews use a labelled virtual treadmill. Gameplay always
## supplies real post-collision motion through set_ground_support().

var feet: Array[Dictionary] = []
var phase := 0.0
var speed_local := 0.0
var walking := 0.0
var landing := 0.0
var ground_normal := Vector2.UP
var grounded := true
var real_support := false
var _rig: Node2D
var _frame := Transform2D.IDENTITY
var _virtual_offset := Vector2.ZERO
var _last_origin := Vector2.ZERO
var _last_facing := 0
var _ready := false
var _was_grounded := true
var _motion := Vector2.ZERO
var _air_speed := 0.0
var _serial := 0
var _support_pending := false
var _last_step := -1
var _travel_sign := 0.0
var step_wave := 0.0
var step_lift := 0.0
var touchdown := 0.0
var support_event_count := 0
var world_velocity := Vector2.ZERO
var vertical_speed := 0.0
var _previous_velocity := Vector2.ZERO
var _double_support := 0.0

func configure(owner_rig: Node2D, front_sole: Vector2, back_sole: Vector2,
		front_half_width: float = 10.0, back_half_width: float = 10.0) -> void:
	_rig = owner_rig
	feet.clear()
	for entry: Array in [["front",front_sole,-25.2,0.0,front_half_width],["back",back_sole,26.7,0.0,back_half_width]]:
		feet.append({"name":entry[0],"sole":entry[1],"rest_x":entry[2],"walk_x":entry[3],
			"planted":true,"anchor":Vector2.ZERO,"point":Vector2.ZERO,
			"start":Vector2.ZERO,"end":Vector2.ZERO,"age":0.0,"duration":0.25,
			"phase":0.0,"roll":0.0,"normal":Vector2.UP,"end_normal":Vector2.UP,"support_id":0,
			"half_width":entry[4],"stance_age":0.0,"stance_phase":0.0,"stance_duration":0.34,"takeoff_roll":0.0,"launch_speed":0.0})
	_ready = false
	real_support = false
	_support_pending = false
	_virtual_offset = Vector2.ZERO
	phase = 0.0
	walking = 0.0
	speed_local = 0.0
	landing = 0.0
	_last_step = -1
	_travel_sign = 0.0
	step_wave = 0.0
	step_lift = 0.0
	touchdown = 0.0
	support_event_count = 0
	_previous_velocity = Vector2.ZERO
	_double_support = 0.0

func set_ground_support(normal: Vector2, on_floor: bool, world_velocity: Vector2) -> void:
	ground_normal = normal.normalized() if normal.length_squared()>0.01 else Vector2.UP
	grounded = on_floor
	_motion = world_velocity
	_support_pending = true

func update(delta: float, requested_speed: float, airborne: bool) -> void:
	var dt := maxf(0.0001,delta)
	var had_real_support := real_support
	real_support = _support_pending
	_support_pending = false
	if had_real_support!=real_support:
		_ready = false
		_virtual_offset = Vector2.ZERO
	if not real_support: ground_normal = Vector2.UP
	var size := maxf(0.01,absf(_rig.global_scale.x))
	var velocity := _motion if real_support else Vector2(requested_speed,0)
	var acceleration_x := clampf((velocity.x-_previous_velocity.x)/dt,-1400.0,1400.0)
	_previous_velocity = velocity
	world_velocity = velocity
	vertical_speed = velocity.y/size
	var on_floor := grounded if real_support else not airborne
	_frame = _rig.global_transform
	if not real_support:
		_virtual_offset.x += requested_speed*dt
		_frame.origin += _virtual_offset
	var local_velocity := velocity.x*float(_rig.facing)/size
	if absf(local_velocity)>3.0 and signf(local_velocity)!=_travel_sign:
		_last_step = -1
		_travel_sign = signf(local_velocity)
	speed_local = lerpf(speed_local,local_velocity,1.0-exp(-dt*10.0))
	walking = move_toward(walking,clampf(absf(local_velocity)/90.0,0,1),dt*7.0)
	landing = move_toward(landing,0,dt*4.5)
	touchdown = move_toward(touchdown,0.0,dt*7.5)
	_double_support = maxf(0.0,_double_support-dt)
	step_wave = 0.0
	step_lift = 0.0
	var reset := not _ready or _rig.global_position.distance_to(_last_origin)>100.0
	if reset or (on_floor and not _was_grounded):
		_reset_feet()
		if not reset:
			landing = clampf(_air_speed/750.0,0.12,1.0)
	elif on_floor and _last_facing!=_rig.facing:
		# Preserve the two visible support positions when a side-view actor
		# mirrors. Swap near/far feet rather than dragging them across the floor.
		var near_point: Vector2 = feet[0].point
		var far_point: Vector2 = feet[1].point
		var near_anchor: Vector2 = feet[0].anchor
		var far_anchor: Vector2 = feet[1].anchor
		# A swing point is NOT a ground contact. Re-project on the new
		# support before swapping, otherwise turning then stopping froze an
		# elevated boot in mid-air.
		_turn_plant(feet[0],far_point,far_anchor)
		_turn_plant(feet[1],near_point,near_anchor)
		_last_step = -1
	if not on_floor:
		_air_speed = maxf(0,velocity.y)
		for foot: Dictionary in feet: foot.planted = false
	else:
		var stride := clampf(23.0+absf(speed_local)*0.24,25.0,66.0)
		var fast := clampf((absf(local_velocity)-160.0)/104.0,0.0,1.0)
		var step_duration := lerpf(lerpf(0.32,0.27,clampf(absf(local_velocity)/160.0,0.0,1.0)),0.18,fast)
		var overlap := lerpf(0.050,0.025,fast)
		var swinging := false
		for index: int in feet.size():
			var foot: Dictionary = feet[index]
			if foot.planted:
				foot.point = foot.anchor
				foot.stance_age += dt
				foot.stance_phase = clampf(foot.stance_age/foot.stance_duration,0.0,1.0)
				# Heel strike -> full sole -> toe off, around the real support
				# plane. Compensated ankle height keeps the opaque boot out of it.
				var stance: float = foot.stance_phase
				var heel := -0.10*(1.0-_ease(clampf(stance/0.25,0.0,1.0)))
				var toe := 0.19*_ease(clampf((stance-0.65)/0.35,0.0,1.0))
				foot.roll = (heel+toe)*walking*(1.0 if local_velocity>=0 else -1.0)
				continue
			swinging = true
			foot.duration = move_toward(float(foot.duration),step_duration,dt*0.9)
			foot.age += dt
			var u := clampf(foot.age/foot.duration,0,1)
			# Start/stop acceleration belongs to the step itself. A frozen
			# landing predicted at the first 15px/s tick was left far behind
			# a player accelerating to132, forcing the whole pelvis to collapse.
			if u<0.45 or (u<0.80 and absf(acceleration_x)>500.0) or absf(local_velocity)<absf(float(foot.launch_speed))*0.55:
				var remaining := maxf(0.0,float(foot.duration)-float(foot.age))
				var lead := signf(local_velocity)*clampf(absf(speed_local)*(step_duration+overlap)*0.50,8.0,26.0) if absf(local_velocity)>3.0 else 0.0
				var desired_home: float = float(foot.walk_x)+foot.sole.x if absf(local_velocity)>3.0 else _home(foot)
				var desired := _frame*Vector2(desired_home+lead,0)
				desired.x += velocity.x*remaining+acceleration_x*remaining*remaining*0.08
				if absf(local_velocity)>3.0:
					var support: Dictionary = feet[1-index]
					var separation := clampf(stride*1.42,40.0,94.0)*size
					desired.x = clampf(desired.x,support.point.x-separation,support.point.x+separation)
				var surface := _surface(desired,foot)
				if is_finite(surface.y):
					foot.end = Vector2(foot.end).lerp(surface,1.0-exp(-dt*26.0))
			var ease := _ease(u)
			foot.phase = u
			# Body rhythm follows the actual alternating support, not a second
			# clock that can bob the shoulders between unrelated touchdowns.
			phase = fposmod(float(index)*0.5+u*0.5,1.0)
			step_lift = sin(u*PI)
			step_wave = step_lift*(1.0 if index==0 else -1.0)
			foot.point = foot.start.lerp(foot.end,ease)
			# Readable knee lift, with zero lift velocity at the endpoints.
			# Retreat keeps a shorter clearance than the forward march.
			var lift := lerpf(5.0,8.0,walking)*lerpf(1.0,1.25,fast)
			lift *= 0.78 if local_velocity<0.0 else 1.0
			foot.point.y -= step_lift*lift*size
			foot.roll = lerpf(float(foot.takeoff_roll),-0.10*(1.0 if local_velocity>=0 else -1.0),ease)
			if u>=1.0:
				_plant(foot,foot.end)
				touchdown = maxf(touchdown,walking)
				support_event_count += 1
				_double_support = overlap
				foot.stance_duration = step_duration+overlap*2.0
				swinging = false
		if not swinging and _double_support<=0.0:
			var candidate := -1
			var worst := 0.0
			for index: int in feet.size():
				# March alternates legs. Picking only the largest home error
				# let wide boots repeatedly hop one leg while the other stayed
				# behind until its reach ran out. Idle re-centering is exempt.
				if absf(local_velocity)>3.0 and index==_last_step: continue
				var foot: Dictionary = feet[index]
				var home := _home(foot)
				var relative: Vector2 = _frame.affine_inverse()*foot.point
				var error := (home-relative.x)*signf(local_velocity)
				if absf(local_velocity)>3.0:
					if error>stride*0.18 and error>worst:
						candidate = index
						worst = error
				elif walking<0.15 and absf(relative.x-home)>6.0:
					if absf(relative.x-home)>worst:
						candidate = index
						worst = absf(relative.x-home)
			if candidate>=0:
				var foot: Dictionary = feet[candidate]
				var duration := step_duration
				var lead := signf(local_velocity)*clampf(absf(speed_local)*(duration+overlap)*0.50,8.0,26.0) if absf(local_velocity)>3.0 else 0.0
				# Place ahead of the FUTURE pelvis. A destination relative to the
				# current root is already behind it by touchdown, causing squats.
				var placement_home: float = float(foot.walk_x)+foot.sole.x if absf(local_velocity)>3.0 else _home(foot)
				var predicted := _frame*Vector2(placement_home+lead,0)
				# The first stride must anticipate acceleration too. A fixed
				# constant-speed landing fell behind a rapidly accelerating root,
				# leaving the opposite support almost a whole leg behind it.
				predicted.x += velocity.x*duration+acceleration_x*duration*duration*0.08
				if absf(local_velocity)>3.0:
					# A fast actor must not put one boot a whole body-width
					# beyond the supporting boot. That overstride collapsed
					# the pelvis, especially with the zombie's broad footwear.
					var support: Dictionary = feet[1-candidate]
					var separation := clampf(stride*1.42,40.0,94.0)*size
					predicted.x = clampf(predicted.x,support.point.x-separation,
						support.point.x+separation)
				var destination := _surface(predicted,foot)
				if is_finite(destination.y):
					_last_step = candidate
					foot.planted = false
					foot.takeoff_roll = foot.roll
					foot.launch_speed = local_velocity
					foot.start = foot.point
					foot.end = destination
					foot.age = 0.0
					foot.phase = 0.0
					foot.duration = duration
	grounded = on_floor
	_was_grounded = on_floor
	_last_origin = _rig.global_position
	_last_facing = _rig.facing

func _home(foot: Dictionary) -> float:
	return lerpf(float(foot.rest_x),float(foot.walk_x),walking)+foot.sole.x

func _ease(u: float) -> float:
	# Continuous velocity, without concentrating the entire step in its
	# middle as a quintic curve would at the fastest supported speed.
	return u*u*(3.0-2.0*u)

func _surface(point: Vector2, foot: Dictionary = {}) -> Vector2:
	if real_support:
		# Probe at placement and during swing replanning, never on every
		# planted-foot tick. An invalid gap replan must keep both the previous
		# destination AND its normal, not replace only the latter.
		# World layer1 also includes crates: floor_y_at alone would put the
		# boots down through a crate that the real CharacterBody stands on.
		var size := maxf(0.01,absf(_rig.global_scale.y))
		var slope := -ground_normal.x/minf(-0.01,ground_normal.y)
		var plane_y := _frame.origin.y+slope*(point.x-_frame.origin.x)
		var query := PhysicsRayQueryParameters2D.create(Vector2(point.x,plane_y-26*size),
			Vector2(point.x,plane_y+42*size),1)
		var hit := _rig.get_world_2d().direct_space_state.intersect_ray(query)
		if not hit.is_empty():
			if not foot.is_empty(): foot.end_normal = Vector2(hit.normal).normalized()
			return Vector2(point.x,hit.position.y)
		var level: Node = _rig.get_tree().get_first_node_in_group("level")
		if level!=null and level.has_method("floor_y_at"):
			point.y = float(level.floor_y_at(point.x))
			if is_finite(point.y) and not foot.is_empty(): foot.end_normal = ground_normal
			return point
	var slope := -ground_normal.x/minf(-0.01,ground_normal.y)
	point.y = _frame.origin.y+slope*(point.x-_frame.origin.x)
	if is_finite(point.y) and not foot.is_empty(): foot.end_normal = ground_normal
	return point

func _reset_feet() -> void:
	_last_step = -1
	_double_support = 0.0
	for foot: Dictionary in feet:
		var point := _surface(_frame*Vector2(_home(foot),0),foot)
		if not is_finite(point.y): point = _frame*Vector2(_home(foot),0)
		_plant(foot,point)
	_ready = true

func _turn_plant(foot: Dictionary, point: Vector2, previous_anchor: Vector2) -> void:
	var projected := _surface(point,foot)
	# A turn over the lip of a gap can put the raised boot outside any
	# floor. Keep its last valid support, never feed INF to the leg solver.
	if not is_finite(projected.y): projected = _surface(previous_anchor,foot)
	if not is_finite(projected.y): projected = previous_anchor
	_plant(foot,projected)

func _plant(foot: Dictionary, point: Vector2) -> void:
	foot.planted = true
	foot.anchor = point
	foot.point = point
	foot.age = 0.0
	foot.phase = 0.0
	foot.stance_age = 0.0
	foot.stance_phase = 0.0
	foot.roll = -0.10*walking*(1.0 if speed_local>=0.0 else -1.0)
	foot.normal = foot.end_normal
	_serial += 1
	foot.support_id = _serial

func foot_angle(foot: Dictionary) -> float:
	# Each support retains the normal it actually touched: a boot on flat
	# ground must not tilt because the other foot/actor just reached a ramp.
	var normal: Vector2 = foot.normal
	if not foot.planted:
		var u: float = foot.phase
		normal = normal.lerp(foot.end_normal,_ease(u)).normalized()
	var tangent := Vector2(-normal.y,normal.x)
	var local := _frame.basis_xform_inv(tangent)
	return fposmod(local.angle()+PI*0.5,PI)-PI*0.5+float(foot.roll)

func ankle_target(foot: Dictionary) -> Vector2:
	var sole: Vector2 = foot.sole
	var angle := foot_angle(foot)
	var height := float(foot.half_width)*absf(sin(float(foot.roll)))
	var normal: Vector2 = _frame.basis_xform_inv(foot.normal).normalized()
	return _frame.affine_inverse()*foot.point-sole.rotated(angle)+normal*height

func contact_local(foot: Dictionary) -> Vector2:
	return Vector2(foot.sole)+Vector2(float(foot.half_width)*signf(float(foot.roll)),0)

func sole_world(foot: Dictionary) -> Vector2:
	var height := float(foot.half_width)*absf(sin(float(foot.roll)))
	return anchor_world(foot)+Vector2(foot.normal)*height*absf(_rig.global_scale.x)

func anchor_world(foot: Dictionary) -> Vector2:
	return foot.point if real_support else foot.point-_virtual_offset

func contact_world(foot: Dictionary) -> Vector2:
	var ankle := ankle_target(foot)
	var point := _frame*(ankle+contact_local(foot).rotated(foot_angle(foot)))
	return point if real_support else point-_virtual_offset
