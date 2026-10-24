# © 2026 Cristian Luis Celie. All rights reserved. Portfolio excerpt from Era Breaker: shared for review only, not licensed for use, copying or redistribution.
class_name Ragdoll
extends Node2D
## Cadáver articulado: cuerpos por segmento físico, unidos con PinJoint2D y
## topes físicos relativos (no el límite angular nativo por vector de origen).
## Cada grupo y sus shapes sólidos chocan con el suelo por su cuenta, así
## que el cuerpo se pliega, rebota y queda tirado como un cuerpo y
## no como una tabla con brazos colgando.
##
## Humanoides: 11 cuerpos (9 sin un brazo), con codos y rodillas separados.
## Solo al morir, mano/bota conserva su pose exacta junto al distal; el rig
## vivo sigue teniendo muñecas/tobillos propios. Criaturas conservan seis.
## Contacto privado por cadáver; nunca bloquean actores u otros cadáveres.

const LIFETIME := 7.0
const FADE := 1.4
const SETTLE_TIME := 1.5
const PAD := 8.0                   ## margen horneado en cada sprite de pieza
const MAX_SEGMENTED_ACTIVE := 4
const MAX_SIMULATED_BODIES := 60   ## mismo techo físico que diez criaturas × seis

## Compatibility topology for quadrupeds, wings, drones and legacy rigs.
const GROUPS := [
	["hips", ["torso"], 5.0, 0.0],
	["head", [], 1.1, 0.65],
	["arm_front", ["forearm_front"], 1.1, 1.65],
	["arm_back", ["forearm_back"], 1.1, 1.65],
	["leg_front", ["shin_front"], 2.0, 1.30],
	["leg_back", ["shin_back"], 2.0, 1.30],
]
## The original six groups are retained: four canine legs, neck and torso.
## A heavy horizontal trunk and restrained neck replace humanoid arm flailing.
const DOG_GROUPS := [
	["hips", ["torso"], 6.0, 0.0],
	["head", [], 0.95, 0.45],
	["arm_front", ["forearm_front"], 1.10, 1.10],
	["arm_back", ["forearm_back"], 1.10, 1.10],
	["leg_front", ["shin_front"], 1.45, 1.15],
	["leg_back", ["shin_back"], 1.45, 1.15],
]
## No full-limb fusion: the elbow/knee remain physical hinges. Hand/boot art
## joins ONLY its distal segment on death, preserving its exact world pose.
## Eleven stable bodies instead of fifteen tiny, fighting terminal joints.
## Mass still totals 12.3, exactly the former six-group humanoid.
const SEGMENTED_GROUPS := [
	["hips", [], 2.0, 0.0], ["torso", [], 3.0, 0.42], ["head", [], 1.1, 0.65],
	["arm_front", [], 0.45, 1.65], ["forearm_front", ["wrist_front"], 0.65, 0.0],
	["arm_back", [], 0.45, 1.65], ["forearm_back", ["wrist_back"], 0.65, 0.0],
	["leg_front", [], 0.90, 1.30], ["shin_front", ["ankle_front"], 1.10, 0.0],
	["leg_back", [], 0.90, 1.30], ["shin_back", ["ankle_back"], 1.10, 0.0],
]
static var _alpha_rect_cache: Dictionary = {}
static var _birth_serial := 0
## Layers 9..32 are reserved for private corpse contact; gameplay uses 1..8.
## FX caps active corpses at ten. Release before fading so slots are reusable.
static var _self_layers_in_use := 0

var rig: CharacterRig
var pending: Dictionary = {}       ## lo rellena Level.spawn_ragdoll antes de entrar al arbol

var _bodies: Array[RigidBody2D] = []
var _root_body: RigidBody2D        ## el torso (o la cadera): impulso y referencia
var _age := 0.0
var _settle := 0.0
var _retiring := false
var _detached_parts := PackedStringArray()
var _canine := false
var _rig_kind := ""
var _self_layer := 0
var _segmented := false
var _serial := 0
var _hinges: Array[Dictionary] = []
var _facing := 1.0
var _constraint_ticks := 0
var _constraint_projections := 0
var _max_linear_projection := 0.0
var _max_angular_projection := 0.0
var _contact_pairs: Array[Array] = []
var _shape_nodes: Dictionary = {}
var _contact_projections := 0
var _rig_scale := 1.0
var _rest_constraints: Dictionary = {}


func _ready() -> void:
	if pending.is_empty():
		return
	_setup(pending["rig"], pending["impulse"], pending["torque"],
		pending.get("detached_parts", pending.get("detached_arm", "")))
	pending.clear()


func _setup(source_rig: CharacterRig, impulse: Vector2, torque: float,
		detached_parts: Variant = "") -> void:
	rig = source_rig
	_canine = rig.rig_type == "quad"
	_rig_kind = rig.rig_type
	_segmented = rig is HoodedConceptRig and rig.get("wrist_front") is Node2D \
		and rig.get("ankle_front") is Node2D
	_facing = -1.0 if rig.global_transform.determinant() < 0.0 else 1.0
	_rig_scale = maxf(0.01, rig.global_transform.x.length())
	_birth_serial += 1
	_serial = _birth_serial
	_self_layer = _acquire_self_layer()
	var inherited_velocity: Vector2 = rig.get_meta("death_velocity",Vector2.ZERO) \
		if _canine else Vector2.ZERO
	_detached_parts = normalize_detached_parts(detached_parts)
	global_position = rig.global_position
	z_index = -1

	var mat := PhysicsMaterial.new()
	mat.friction = 0.88 if _canine else 0.9
	mat.bounce = 0.04 if _canine else 0.08

	# 1) un cuerpo por grupo de huesos, colocado donde esta el hueso raiz
	var by_bone: Dictionary = {}      # hueso (raiz o extra) -> cuerpo
	var limits: Dictionary = {}       # cuerpo -> limite angular con su padre
	var seen: Array = []
	for g: Array in (SEGMENTED_GROUPS if _segmented else (DOG_GROUPS if _canine else GROUPS)):
		var root: Node2D = rig.get(String(g[0]))
		if root == null or root in seen:
			continue
		var members: Array[Node2D] = [root]
		for extra_name: String in g[1]:
			var extra: Node2D = rig.get(extra_name)
			if extra != null and extra != root and not (extra in seen):
				members.append(extra)
		var body := _make_body(members, String(g[0]), float(g[2]), mat)
		if body == null:
			continue
		for m in members:
			by_bone[m] = body
			seen.append(m)
		limits[body] = float(g[3])
		_bodies.append(body)
		if _root_body == null or (_segmented and String(g[0]) == "torso"):
			_root_body = body
	# Near/far versions project onto each other in this side-view art. They
	# share a support plane but not a depth plane; never let those paired feet
	# fight at spawn. Both still collide with the solid torso and the head.
	for pair: Array in [["arm_front","arm_back"],["leg_front","leg_back"]]:
		var near_body: RigidBody2D = get_node_or_null(String(pair[0]))
		var far_body: RigidBody2D = get_node_or_null(String(pair[1]))
		if near_body!=null and far_body!=null:
			near_body.add_collision_exception_with(far_body)
			far_body.add_collision_exception_with(near_body)
	if _segmented:
		# Neck/shoulder and waist/hip sockets straddle two authored core pieces.
		# These are adjacent seam volumes, not distal limbs made transparent.
		for pair: Array in [["head", "arm_front"], ["head", "arm_back"], ["torso", "leg_front"], ["torso", "leg_back"]]:
			var socket_core: RigidBody2D = get_node_or_null(String(pair[0]))
			var socket_limb: RigidBody2D = get_node_or_null(String(pair[1]))
			if socket_core != null and socket_limb != null:
				socket_core.add_collision_exception_with(socket_limb)
				socket_limb.add_collision_exception_with(socket_core)
		# Front/back art represents separate depth planes. Exclude only paired
		# chains, not torso/head or the opposite species of limb.
		for prefixes: Array in [["arm_", "forearm_"], ["leg_", "shin_"]]:
			for near_prefix: String in prefixes:
				var near_body: RigidBody2D = get_node_or_null(near_prefix + "front")
				for far_prefix: String in prefixes:
					var far_body: RigidBody2D = get_node_or_null(far_prefix + "back")
					if near_body != null and far_body != null:
						near_body.add_collision_exception_with(far_body)
						far_body.add_collision_exception_with(near_body)

	# 2) articulaciones: cada cuerpo con el cuerpo del hueso padre mas cercano
	var joined: Array = []
	for bone: Node2D in by_bone.keys():
		var body: RigidBody2D = by_bone[bone]
		if body in joined:
			continue
		var parent: Node = bone.get_parent()
		while parent != null and parent != rig and (not by_bone.has(parent) or by_bone[parent] == body):
			parent = parent.get_parent()
		if parent == null or parent == rig:
			continue
		joined.append(body)
		# Sever only the proximal socket. Forearm/shin retain their joint and
		# terminal hand/boot artwork: the detached chain still bends physically.
		if String(body.name) in _detached_parts:
			continue
		var mode: String = String(Game.get_meta("ragtest", ""))
		if mode == "nojoints":
			continue
		if _segmented:
			_make_segmented_joint(by_bone[parent], body, bone.global_position,
				float(limits[body]), mode == "nolimits")
		else:
			_make_joint(by_bone[parent], body, bone.global_position,
				0.0 if mode == "nolimits" else float(limits[body]))
	if _segmented:
		for body: RigidBody2D in _bodies: _shape_nodes[body] = body.find_children("*", "CollisionShape2D", false, false)
		for index in _bodies.size():
			for other_index in range(index + 1, _bodies.size()):
				var a := _bodies[index]
				var b := _bodies[other_index]
				if b not in a.get_collision_exceptions(): _contact_pairs.append([a, b])

	# 3) el rig queda vacio: las piezas ya viven en los cuerpos
	rig.queue_free()
	rig = null

	# 4) empujon inicial: todo el cuerpo sale con la misma velocidad y el torso
	#    ademas gira; los miembros reciben un giro suelto para que aleteen
	var total := 0.0
	for b in _bodies:
		total += b.mass
	var v := impulse / maxf(1.0, total)+inherited_velocity
	for b in _bodies:
		var reach: Vector2 = (b.to_global(b.center_of_mass) - _root_body.to_global(_root_body.center_of_mass) \
			if _segmented else b.global_position - _root_body.global_position) \
			if _root_body != null else Vector2.ZERO
		b.linear_velocity = v + Vector2(-reach.y, reach.x) * clampf(torque / (4200.0 if _canine else 2400.0), -1.4, 1.4)
		b.angular_velocity = randf_range(-1.3,1.3) if _canine else randf_range(-2.2,2.2)
		var detached_root := _detachment_root(String(b.name))
		if detached_root in _detached_parts:
			var side := signf(impulse.x) if absf(impulse.x) > 0.01 else 1.0
			var kick := Vector2(side * 135.0, -225.0)
			var spin := 4.5 if _segmented else 9.0
			if detached_root == "head":
				kick = Vector2(side * 165.0, -295.0)
				spin = 9.0 if _segmented else 12.0
			elif detached_root.begins_with("leg_"):
				kick = Vector2(side * 185.0, -160.0)
				spin = 5.0 if _segmented else 7.5
			var chain_root: RigidBody2D = get_node_or_null(detached_root)
			var chain_reach := b.to_global(b.center_of_mass) - chain_root.to_global(chain_root.center_of_mass) if chain_root != null else Vector2.ZERO
			b.linear_velocity += kick + Vector2(-chain_reach.y, chain_reach.x) * side * spin
			b.angular_velocity += side * spin
			# Keep the head's loose tumble, but full severed arms/legs have more
			# rotational drag on landing instead of spinning back through the
			# resting body's contact points long after the fatal impact.
			b.angular_damp = 1.7 if b.name=="head" else 2.8
	if _root_body != null:
		var spin_impulse := torque*0.6+randf_range(-900.0,900.0)
		if _canine:
			spin_impulse = torque*0.35+randf_range(-350.0,350.0)
		_root_body.apply_torque_impulse(spin_impulse)

	FX.register_ragdoll(self)
	_enforce_simulation_budget()


static func normalize_detached_parts(value: Variant) -> PackedStringArray:
	# Accept the old single-arm argument as well as the new multi-part list.
	var candidates := PackedStringArray()
	if value is String or value is StringName:
		candidates.append(String(value))
	elif value is Array or value is PackedStringArray:
		for entry: Variant in value:
			candidates.append(String(entry))
	var parts := PackedStringArray()
	for part: String in candidates:
		if part in ["head", "arm_front", "arm_back", "leg_front", "leg_back"] and not part in parts:
			parts.append(part)
	return parts


func _detachment_root(part: String) -> String:
	if not _segmented: return part
	if part.begins_with("forearm_") or part.begins_with("wrist_"):
		return "arm_" + part.get_slice("_", 1)
	if part.begins_with("shin_") or part.begins_with("ankle_"):
		return "leg_" + part.get_slice("_", 1)
	return part


## Cuerpo rigido con la capsula del tamano real de los sprites de ese hueso.
func _make_body(members: Array[Node2D], name: String, mass: float,
		mat: PhysicsMaterial) -> RigidBody2D:
	var root: Node2D = members[0]
	var root_gt := root.get_global_transform()
	# Physics bodies cannot inherit mirrored/non-unit scale. Express art in an
	# unscaled body's frame instead, preserving the full world-space size of
	# heavies/bosses and baking reflection into the Sprite2D transforms.
	var body_gt := Transform2D(root_gt.get_rotation(), root_gt.origin)
	var inv := body_gt.affine_inverse()

	# sprites de todos los huesos del grupo, con su transform expresado en el
	# espacio local del hueso raiz (los huesos hijos van compuestos)
	var parts: Array = []          # [sprite, transform local al raiz]
	var rect := Rect2()
	var root_rect := Rect2()
	var root_first := true
	var first := true
	for bone in members:
		for c: Node in bone.get_children():
			if not (c is Sprite2D) or (c as Sprite2D).texture == null:
				continue
			var sp := c as Sprite2D
			var local: Transform2D = inv * sp.get_global_transform()
			parts.append([sp, local])
			var size: Vector2 = sp.texture.get_size()
			var origin: Vector2 = sp.offset if not sp.centered else sp.offset - size * 0.5
			if _canine and sp.texture.resource_path.get_file() in ["tail.png","jaw.png"]:
				# Tail/jaw are still transferred art, never a floor-dragging torso
				# collider. Alpha bounds remove transparent 4x bake margins too.
				continue
			var pixels: Rect2 = _used_alpha_rect(sp.texture)
			var r: Rect2 = local * Rect2(origin+pixels.position,pixels.size)
			rect = r if first else rect.merge(r)
			first = false
			if bone == members[0]:
				root_rect = r if root_first else root_rect.merge(r)
				root_first = false
	if first:
		return null

	var body := RigidBody2D.new()
	body.name = name
	# primero al arbol y luego la posicion global: fuera del arbol
	# global_position no conoce al padre y el cuerpo acababa con el
	# desplazamiento duplicado, fuera de pantalla
	add_child(body)
	body.global_position = root_gt.origin
	body.global_rotation = root_gt.get_rotation()
	body.mass = mass
	# Contact proxies omit the interlocking shoulder/elbow region, but this
	# body still carries the FULL arm/leg and its original artwork. Do not
	# let the solver treat that whole limb as a tiny, low-inertia wrist/foot.
	body.center_of_mass_mode = RigidBody2D.CENTER_OF_MASS_MODE_CUSTOM
	body.center_of_mass = rect.get_center()
	body.inertia = maxf(1.0,mass*(rect.size.x*rect.size.x+rect.size.y*rect.size.y)/12.0)
	body.physics_material_override = mat
	body.linear_damp = 0.95 if _canine else 0.6
	body.angular_damp = (3.1 if name=="hips" else 2.3) if _canine else \
		((2.2 if name in ["hips", "torso"] else 1.7) if _segmented else 2.6)
	body.gravity_scale = 1.0
	# sin CCD: los shape-casts de cada capsula contra los poligonos del suelo
	# multiplicaban por diez el coste del tick; nada aqui va tan rapido como
	# para atravesar un suelo de 900 px
	body.continuous_cd = RigidBody2D.CCD_MODE_DISABLED
	body.collision_layer = (1 << 5) | _self_layer
	body.collision_mask = 1 | _self_layer
	# Four constrained paws must not drag the heavier trunk into the ground
	# during landing. Give its world contact priority over limb constraints.
	body.collision_priority = 2.0 if (_canine and name=="hips") or (_segmented and name in ["hips", "torso"]) else 1.0
	body.can_sleep = true

	if _segmented:
		# Each collision proxy comes from THIS part's opaque artwork, never a
		# fused whole-limb AABB. Adjacent sockets are handled by the pin joint;
		# distal parts still contact chest/head and world as independent solids.
		var width := 0.30 if name in ["hips", "torso"] else 0.28
		if name == "head": rect = _trim_toward_tip(rect, 0.25)
		var endpoint_name := ""
		if name.begins_with("arm_"): endpoint_name = "forearm_" + name.get_slice("_", 1)
		elif name.begins_with("forearm_"): endpoint_name = "wrist_" + name.get_slice("_", 1)
		elif name.begins_with("leg_"): endpoint_name = "shin_" + name.get_slice("_", 1)
		elif name.begins_with("shin_"): endpoint_name = "ankle_" + name.get_slice("_", 1)
		if not endpoint_name.is_empty():
			var endpoint: Node2D = rig.get(endpoint_name)
			var tip := inv * endpoint.global_position
			# Fit the SHAFT to its own opaque art. The sideways boot or bent
			# hand must not inflate the whole shin/forearm into a giant sausage.
			var radius := maxf(2.8, minf(root_rect.size.x * 0.24, tip.length() * 0.14))
			# The terminal artwork has joined this distal body, so its solid
			# proxy is a SEPARATE solid shape on the same body, not omitted or
			# used to inflate the shaft. All textures/transforms stay intact.
			var proximal_fraction := 0.60 if name.begins_with("forearm_") else 0.20
			_add_segment_shape(body, tip * proximal_fraction, tip * 0.88, radius)
			if members.size() > 1:
				var terminal_rect := Rect2()
				var terminal_first := true
				for child: Node in endpoint.get_children():
					if not child is Sprite2D or (child as Sprite2D).texture == null: continue
					var sprite := child as Sprite2D
					var origin := sprite.offset - sprite.texture.get_size() * 0.5 if sprite.centered else sprite.offset
					var used := _used_alpha_rect(sprite.texture)
					var bounds: Rect2 = sprite.transform * Rect2(origin + used.position, used.size)
					terminal_rect = bounds if terminal_first else terminal_rect.merge(bounds)
					terminal_first = false
				if not terminal_first:
					_add_capsule_shape(body, terminal_rect, inv * endpoint.global_transform, 0.38, 2.8)
		else:
			_add_capsule_shape(body, rect, Transform2D.IDENTITY, width, 2.8)
		body.set_meta("collider_source", name + "_segment")
	elif name in _detached_parts:
		# Once severed there is no shoulder/hip joint or interlocking socket to
		# exclude. The ENTIRE original fragment must now rest on the ground,
		# not just its wrist/paw while the upper half hangs through the soil.
		_add_capsule_shape(body,rect,Transform2D.IDENTITY)
		body.set_meta("collider_source",name+"_detached_full")
	elif (name.begins_with("arm_") or name.begins_with("leg_")) and members.size()>1:
		# Collide using the actual distal forearm/calf and hand/paw. A whole
		# bent-limb AABB includes its shoulder/hip inside the torso, so enabling
		# contact on that old capsule would make the joint fight the solver.
		var lower: Node2D = members.back()
		var lower_frame: Transform2D = inv*lower.global_transform
		if _rig_kind=="pterosaur" and name.begins_with("arm_"):
			# Wing membrane is decorative, not a giant solid elbow. The narrow
			# wing finger remains physical, using its authored endpoint.
			var finger: Vector2 = rig._j("forearm","grip")-rig._j("forearm","top")
			_add_segment_shape(body,lower_frame*(finger*0.55),lower_frame*finger,
				4.0*lower.global_transform.x.length())
		else:
			var lower_rect := Rect2()
			var lower_first := true
			for child: Node in lower.get_children():
				if not (child is Sprite2D) or (child as Sprite2D).texture==null:
					continue
				var sprite := child as Sprite2D
				var origin: Vector2 = sprite.offset if not sprite.centered else sprite.offset-sprite.texture.get_size()*0.5
				var used: Rect2 = _used_alpha_rect(sprite.texture)
				var bounds: Rect2 = sprite.transform*Rect2(origin+used.position,used.size)
				lower_rect = bounds if lower_first else lower_rect.merge(bounds)
				lower_first = false
			if name.begins_with("arm_") and rig is HoodedConceptRig:
				# The elbow may legitimately lie in FRONT of the chest in the
				# aiming/guard pose. It is not an interior solid point. Use the
				# authored wrist end, not an AABB around the folded whole arm.
				var reach: float = rig.get("_front_arm_l2" if name=="arm_front" else "_back_arm_l2")
				var radius := maxf(4.0,lower_rect.size.x*lower_frame.x.length()*0.28)
				_add_segment_shape(body,lower_frame*Vector2(0,reach*0.65),
					lower_frame*Vector2(0,reach),radius)
			else:
				# Keep the opaque paw/boot sole intact but omit the knee/elbow
				# transition already embedded in its shoulder or hip joint.
				lower_rect.position.y += lower_rect.size.y*0.55
				lower_rect.size.y *= 0.45
				_add_capsule_shape(body,lower_rect,lower_frame)
		body.set_meta("collider_source",("forearm_" if name.begins_with("arm_") else "shin_")+name.get_slice("_",1))
	elif _rig_kind=="drone" and name.begins_with("arm_"):
		# Engine pods are partially recessed in the hull. Their exposed
		# nozzle contacts physically; the recessed mounting plate does not.
		_add_capsule_shape(body,_trim_toward_tip(rect,0.55),Transform2D.IDENTITY)
		body.set_meta("collider_source",name+"_nozzle")
	else:
		if name=="head" and _rig_kind in ["concept","biped","drone"]:
			# Hood/scarf and sensor mounting bases overlap the neck by design.
			# The actual cranium is solid, not that interlocking neck trim.
			rect = _trim_toward_tip(rect,0.25)
		_add_capsule_shape(body,rect,Transform2D.IDENTITY)
		body.set_meta("collider_source",name)

	# Scale and any reflection already live in the transferred sprite matrices;
	# do not mirror the holder a second time or shrink large enemies on death.
	var holder := Node2D.new()
	holder.name = "Art"
	body.add_child(holder)
	for pr: Array in parts:
		var sp: Sprite2D = pr[0]
		sp.get_parent().remove_child(sp)
		holder.add_child(sp)
		sp.transform = pr[1]
	return body

func _trim_toward_tip(rect: Rect2, fraction: float) -> Rect2:
	var cut := rect.size.y*fraction
	if rect.get_center().y>=0:
		rect.position.y += cut
	rect.size.y -= cut
	return rect

func _add_capsule_shape(body: RigidBody2D, rect: Rect2, frame: Transform2D,
		width_override: float = -1.0, minimum_radius: float = 4.0) -> void:
	var vertical := rect.size.y>=rect.size.x
	var axis: Vector2 = frame.y if vertical else frame.x
	var cross_axis: Vector2 = frame.x if vertical else frame.y
	var length: float = (rect.size.y if vertical else rect.size.x)*axis.length()*0.92
	var thick: float = (rect.size.x if vertical else rect.size.y)*cross_axis.length()
	# Central rib-cage volume, not the full width of projecting coat/armour
	# panels. Preserve the existing opaque quadruped trunk fit exactly.
	var width_factor := 0.30 if body.name=="hips" and not _canine else 0.40
	if width_override >= 0.0: width_factor = width_override
	var radius := clampf(thick*width_factor,minimum_radius,maxf(minimum_radius,length*0.45))
	var shape := CapsuleShape2D.new()
	shape.radius = radius
	shape.height = maxf(length,radius*2.0+2.0)
	# Slightly firmer than the engine's 0.8 contact correction: attached
	# wrists/calves must not sink back into the chest while pins settle.
	shape.custom_solver_bias = 0.95
	var col := CollisionShape2D.new()
	col.name = "TerminalShape" if body.get_node_or_null("AnatomicalShape") != null else "AnatomicalShape"
	col.shape = shape
	col.position = frame*rect.get_center()
	col.rotation = fposmod(axis.angle()-PI*0.5,PI)
	body.add_child(col)

func _add_segment_shape(body: RigidBody2D, a: Vector2, b: Vector2, radius: float) -> void:
	var shape := CapsuleShape2D.new()
	shape.radius = radius
	shape.height = a.distance_to(b)+radius*2.0
	shape.custom_solver_bias = 0.95
	var col := CollisionShape2D.new()
	col.name = "AnatomicalShape"
	col.shape = shape
	col.position = (a+b)*0.5
	col.rotation = fposmod((b-a).angle()-PI*0.5,PI)
	body.add_child(col)

static func _acquire_self_layer() -> int:
	for bit: int in range(8,32):
		var value := 1<<bit
		if (_self_layers_in_use&value)==0:
			_self_layers_in_use |= value
			return value
	# More than 24 simultaneous active corpses cannot occur under FX's cap.
	# Never silently fall back to transparent limbs if that invariant breaks.
	assert(false,"Private ragdoll collision layers exhausted")
	return 0

func _release_self_layer() -> void:
	if _self_layer==0:
		return
	for body: RigidBody2D in _bodies:
		if is_instance_valid(body):
			body.collision_layer = 1<<5
			body.collision_mask = 1
	_self_layers_in_use &= ~_self_layer
	_self_layer = 0

func _exit_tree() -> void:
	_release_self_layer()


static func _used_alpha_rect(texture: Texture2D) -> Rect2:
	var key := texture.resource_path
	if key.is_empty():
		key = str(texture.get_instance_id())
	if not _alpha_rect_cache.has(key):
		var bitmap := texture.get_image()
		_alpha_rect_cache[key] = Rect2(bitmap.get_used_rect()) if bitmap != null \
			else Rect2(Vector2.ZERO,texture.get_size())
	return _alpha_rect_cache[key]


func _make_joint(a: RigidBody2D, b: RigidBody2D, at: Vector2, limit: float) -> void:
	var j := PinJoint2D.new()
	add_child(j)
	j.global_position = at
	j.node_a = a.get_path()
	j.node_b = b.get_path()
	j.disable_collision = false
	# Small compliance lets solid contacts win at rest instead of a perfectly
	# rigid pin pulling a wrist/calf back into the chest. This is already the
	# stable canine joint setting; retain it for humanoid corpse piles too.
	j.softness = 0.03
	if limit > 0.0:
		j.angular_limit_enabled = true
		j.angular_limit_lower = -limit
		j.angular_limit_upper = limit


func _make_segmented_joint(a: RigidBody2D, b: RigidBody2D, at: Vector2,
		limit: float, no_limits: bool) -> void:
	var j := PinJoint2D.new()
	j.name = "joint_" + String(b.name)
	add_child(j)
	j.global_position = at
	j.node_a = a.get_path()
	j.node_b = b.get_path()
	# Only the interlocking adjacent socket is excluded. A wrist/forearm can
	# still collide with the chest, skull, pelvis and legs of its own corpse.
	j.disable_collision = true
	j.softness = 0.03
	j.bias = 0.45
	var rest := wrapf(b.global_rotation - a.global_rotation, -PI, PI)
	var lower := rest - limit
	var upper := rest + limit
	var hinge := "socket"
	if String(b.name).begins_with("forearm_"):
		hinge = "elbow"
		lower = -2.48 if _facing > 0.0 else -0.06
		upper = 0.06 if _facing > 0.0 else 2.48
	elif String(b.name).begins_with("shin_"):
		hinge = "knee"
		lower = -0.06 if _facing > 0.0 else -2.40
		upper = 2.40 if _facing > 0.0 else 0.06
	# Preserve the exact live pose at frame zero, even at an unusual authored
	# throw/rope extreme. Stops constrain subsequent motion, not a death snap.
	lower = minf(lower, rest - 0.02)
	upper = maxf(upper, rest + 0.02)
	j.set_meta("rest_angle", rest)
	j.set_meta("min_angle", lower)
	j.set_meta("max_angle", upper)
	j.set_meta("anatomical_hinge", hinge)
	j.set_meta("anchor_a", a.to_local(at))
	j.set_meta("anchor_b", b.to_local(at))
	# Godot's native angular limit measures the vector between body origins,
	# not the actual relative bend. Physical mass/inertia-weighted projection
	# and velocity impulses below supplement the compliant native pin. They
	# never restore an animated pose, and retain actual self/world contacts.
	j.angular_limit_enabled = false
	j.motor_enabled = false
	if not no_limits:
		_hinges.append({"joint": j, "a": a, "b": b, "rest": rest, "lower": lower, "upper": upper})


func _update_hinge_stops(delta: float) -> void:
	_constraint_ticks += 1
	# Mass/inertia-weighted position based constraints supplement Godot's pin
	# solver. This is physical post-step projection, NEVER an animated pose,
	# source-rig reset or corpse-root teleport. World/self contacts stay active.
	var states: Dictionary = {}
	for body: RigidBody2D in _bodies:
		states[body] = {"v": body.linear_velocity, "w": body.angular_velocity,
			"im": 1.0 / body.mass, "ii": 1.0 / maxf(body.inertia, 1.0),
			"com": body.to_global(body.center_of_mass), "rotation": body.global_rotation}
	for iteration in 10:
		# Alternating sweep closes both ends of each chain; a distal pin must
		# not indefinitely undo the shoulder/hip solved earlier in the list.
		for index in _hinges.size():
			var hinge: Dictionary = _hinges[index if iteration % 2 == 0 else _hinges.size() - index - 1]
			_project_pin(hinge)
			_project_hinge(hinge)
		_project_solid_contacts()
	for hinge: Dictionary in _hinges: _project_pin(hinge)
	for body: RigidBody2D in _bodies:
		var before: Dictionary = states[body]
		var translation := body.to_global(body.center_of_mass) - Vector2(before.com)
		var rotation := wrapf(body.global_rotation - float(before.rotation), -PI, PI)
		_max_linear_projection = maxf(_max_linear_projection, translation.length())
		_max_angular_projection = maxf(_max_angular_projection, absf(rotation))
		# A native sleeping flag can survive an externally solved physical
		# correction. Do not freeze that intermediate pose as a settled corpse.
		if body.sleeping and (translation.length() > 0.12 * _rig_scale or absf(rotation) > 0.01): body.sleeping = false
		var incoming_v := Vector2(before.v)
		var corrected_v := incoming_v + translation / maxf(delta, 0.0001) * 0.35
		before.v = corrected_v.limit_length(minf(1000.0, incoming_v.length()))
		var incoming_w := float(before.w)
		var corrected_w := incoming_w + rotation / maxf(delta, 0.0001) * 0.65
		# Projection may dissipate velocity directed into a violated constraint;
		# it must not create an opposite kick or increase the body's energy.
		before.w = clampf(corrected_w, minf(incoming_w, 0.0), maxf(incoming_w, 0.0))
	for iteration in 4:
		for hinge: Dictionary in _hinges:
			_solve_velocity_pin(hinge, states)
			_solve_velocity_stop(hinge, states, delta)
	for body: RigidBody2D in _bodies:
		body.linear_velocity = states[body].v
		body.angular_velocity = float(states[body].w)


func _project_hinge(hinge: Dictionary) -> void:
	var a: RigidBody2D = hinge.a
	var b: RigidBody2D = hinge.b
	var raw := wrapf(b.global_rotation - a.global_rotation, -PI, PI)
	var angle := float(hinge.rest) + wrapf(raw - float(hinge.rest), -PI, PI)
	var target := clampf(angle, float(hinge.lower) + 0.03, float(hinge.upper) - 0.03)
	var error := clampf(angle - target, -0.35, 0.35)
	if absf(error) < 0.00001: return
	var joint: PinJoint2D = hinge.joint
	var pa := a.to_global(joint.get_meta("anchor_a"))
	var pb := b.to_global(joint.get_meta("anchor_b"))
	var ca := a.to_global(a.center_of_mass)
	var cb := b.to_global(b.center_of_mass)
	var center := (ca * a.mass + cb * b.mass) / (a.mass + b.mass)
	# Parallel-axis inertia: turn around the actual socket, not the COM and
	# then reopen that socket. Restore only the pair's total COM with an equal
	# translation; this preserves its anchor gap and actual relative bend.
	var ia := 1.0 / maxf(a.inertia + a.mass * ca.distance_squared_to(pa), 1.0)
	var ib := 1.0 / maxf(b.inertia + b.mass * cb.distance_squared_to(pb), 1.0)
	_rotate_at_anchor(a, pa, error * ia / (ia + ib))
	_rotate_at_anchor(b, pb, -error * ib / (ia + ib))
	var after_center := (a.to_global(a.center_of_mass) * a.mass + b.to_global(b.center_of_mass) * b.mass) / (a.mass + b.mass)
	a.global_position += center - after_center
	b.global_position += center - after_center


func _rotate_at_anchor(body: RigidBody2D, anchor: Vector2, angle: float) -> void:
	var relative_origin := body.global_position - anchor
	body.global_rotation += angle
	body.global_position = anchor + relative_origin.rotated(angle)
	_constraint_projections += 1


func _project_pin(hinge: Dictionary) -> void:
	var a: RigidBody2D = hinge.a
	var b: RigidBody2D = hinge.b
	var joint: PinJoint2D = hinge.joint
	var point_a := a.to_global(joint.get_meta("anchor_a"))
	var point_b := b.to_global(joint.get_meta("anchor_b"))
	var error := (point_b - point_a).limit_length(8.0)
	if error.length() < 0.04: return
	var inv_a := 1.0 / a.mass
	var inv_b := 1.0 / b.mass
	a.global_position += error * inv_a / (inv_a + inv_b)
	b.global_position -= error * inv_b / (inv_a + inv_b)
	_constraint_projections += 1


func _project_solid_contacts() -> void:
	# The SAME native capsule geometry and collision exclusions as the actual
	# simulated bodies. Resolve only real narrowphase penetrations, not a
	# visual guess, world-plane shortcut or disabled-contact substitute.
	for pair: Array in _contact_pairs:
		var a: RigidBody2D = pair[0]
		var b: RigidBody2D = pair[1]
		if (a.collision_mask & b.collision_layer) == 0 or (b.collision_mask & a.collision_layer) == 0: continue
		for ca: CollisionShape2D in _shape_nodes[a]:
			for cb: CollisionShape2D in _shape_nodes[b]:
				if not _capsule_bounds(ca).intersects(_capsule_bounds(cb)): continue
				var contacts := ca.shape.collide_and_get_contacts(ca.global_transform, cb.shape, cb.global_transform)
				_project_contact(a, b, contacts)
	_project_world_contacts()


func _project_contact(a: RigidBody2D, b: RigidBody2D, contacts: PackedVector2Array) -> void:
	var point_a := Vector2.ZERO
	var point_b := Vector2.ZERO
	var depth := 0.0
	for index in range(0, contacts.size() - 1, 2):
		var length := contacts[index].distance_to(contacts[index + 1])
		if length > depth:
			depth = length
			point_a = contacts[index]
			point_b = contacts[index + 1]
	if depth < 0.03: return
	var normal := (point_b - point_a) / depth
	var im_a := 1.0 / a.mass
	var im_b := 1.0 / b.mass if b != null else 0.0
	var magnitude := minf(depth, 1.5) / (im_a + im_b)
	# Resolve positional overlap without turning a bounded hinge back through
	# its stop. Actual contact lever-arm angular response is retained by the
	# native contact solver; pin velocities use their own mass/inertia Jacobian.
	a.global_position += normal * magnitude * im_a
	if b != null:
		b.global_position -= normal * magnitude * im_b
	_contact_projections += 1


func _project_world_contacts() -> void:
	var space := get_world_2d().direct_space_state
	for body: RigidBody2D in _bodies:
		for col: CollisionShape2D in _shape_nodes[body]:
			var query := PhysicsShapeQueryParameters2D.new()
			query.shape = col.shape
			query.transform = col.global_transform
			query.collision_mask = 1
			var contacts := space.collide_shape(query, 4)
			_project_contact(body, null, contacts)


func _capsule_bounds(col: CollisionShape2D) -> Rect2:
	var shape: CapsuleShape2D = col.shape
	var half := maxf(0.0, shape.height * 0.5 - shape.radius)
	var a := col.to_global(Vector2(0.0, -half))
	var b := col.to_global(Vector2(0.0, half))
	var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y)) - Vector2.ONE * shape.radius
	var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y)) + Vector2.ONE * shape.radius
	return Rect2(lo, hi - lo)


func _contact_correction(contacts: PackedVector2Array) -> Vector2:
	var correction := Vector2.ZERO
	for index in range(0, contacts.size() - 1, 2):
		var candidate := contacts[index + 1] - contacts[index]
		if candidate.length_squared() > correction.length_squared(): correction = candidate
	return correction


func _solve_velocity_pin(hinge: Dictionary, states: Dictionary) -> void:
	var a: RigidBody2D = hinge.a
	var b: RigidBody2D = hinge.b
	var joint: PinJoint2D = hinge.joint
	var point_a := a.to_global(joint.get_meta("anchor_a"))
	var point_b := b.to_global(joint.get_meta("anchor_b"))
	var ra := point_a - a.to_global(a.center_of_mass)
	var rb := point_b - b.to_global(b.center_of_mass)
	var sa: Dictionary = states[a]
	var sb: Dictionary = states[b]
	var mass_sum := float(sa.im) + float(sb.im)
	var kxx := mass_sum + float(sa.ii) * ra.y * ra.y + float(sb.ii) * rb.y * rb.y
	var kyy := mass_sum + float(sa.ii) * ra.x * ra.x + float(sb.ii) * rb.x * rb.x
	var kxy := -float(sa.ii) * ra.x * ra.y - float(sb.ii) * rb.x * rb.y
	var det := maxf(0.000001, kxx * kyy - kxy * kxy)
	var va: Vector2 = sa.v + Vector2(-ra.y, ra.x) * float(sa.w)
	var vb: Vector2 = sb.v + Vector2(-rb.y, rb.x) * float(sb.w)
	# Positions were already constrained. Cancel anchor separation velocity,
	# without an extra bias kick that would fight contacts on the next step.
	var change := -(vb - va)
	var impulse := Vector2(kyy * change.x - kxy * change.y, kxx * change.y - kxy * change.x) / det
	sa.v = sa.v - impulse * float(sa.im)
	sb.v = sb.v + impulse * float(sb.im)
	sa.w = float(sa.w) - ra.cross(impulse) * float(sa.ii)
	sb.w = float(sb.w) + rb.cross(impulse) * float(sb.ii)


func _solve_velocity_stop(hinge: Dictionary, states: Dictionary, delta: float) -> void:
	var a: RigidBody2D = hinge.a
	var b: RigidBody2D = hinge.b
	var sa: Dictionary = states[a]
	var sb: Dictionary = states[b]
	var raw := wrapf(b.global_rotation - a.global_rotation, -PI, PI)
	var angle := float(hinge.rest) + wrapf(raw - float(hinge.rest), -PI, PI)
	var velocity := float(sb.w) - float(sa.w)
	var lower := float(hinge.lower) + 0.04
	var upper := float(hinge.upper) - 0.04
	# Speculative soft stop slows a fast joint BEFORE impact rather than
	# waiting for an already-overextended segment to reverse in one tick.
	# Projection already corrects position. A stop must never create an
	# inward escape velocity from rest just because margins differ by0.01rad.
	var target_velocity := clampf(velocity, minf(0.0, (lower - angle) * 7.0), maxf(0.0, (upper - angle) * 7.0))
	if is_equal_approx(velocity, target_velocity): return
	var impulse := (target_velocity - velocity) / (float(sa.ii) + float(sb.ii))
	sa.w = float(sa.w) - impulse * float(sa.ii)
	sb.w = float(sb.w) + impulse * float(sb.ii)


func _enforce_simulation_budget() -> void:
	# Every corpse keeps its real segmented topology. The oldest simulation
	# is frozen/faded at the budget, never swapped to fused or fake limbs.
	var active: Array[Node] = []
	var body_count := 0
	var segmented_count := 0
	for candidate: Node in get_tree().get_nodes_in_group("ragdolls"):
		if not is_instance_valid(candidate) or candidate._retiring: continue
		active.append(candidate)
		body_count += candidate._bodies.size()
		if candidate._segmented: segmented_count += 1
	active.sort_custom(func(a: Node, b: Node) -> bool: return a._serial < b._serial)
	var body_limit := 36 if FX.reduced_effects() else MAX_SIMULATED_BODIES
	var segmented_limit := 3 if FX.reduced_effects() else MAX_SEGMENTED_ACTIVE
	while not active.is_empty() and (body_count > body_limit or segmented_count > segmented_limit):
		var old: Node = active.pop_front()
		body_count -= old._bodies.size()
		if old._segmented: segmented_count -= 1
		old.set_meta("retirement_reason", "simulation_budget")
		old.retire()


func _constraints_at_rest() -> bool:
	var gap := 0.0
	var angle_error := 0.0
	for hinge: Dictionary in _hinges:
		var a: RigidBody2D = hinge.a
		var b: RigidBody2D = hinge.b
		var joint: PinJoint2D = hinge.joint
		gap = maxf(gap, a.to_global(joint.get_meta("anchor_a")).distance_to(b.to_global(joint.get_meta("anchor_b"))))
		var angle := float(hinge.rest) + wrapf(b.global_rotation - a.global_rotation - float(hinge.rest), -PI, PI)
		angle_error = maxf(angle_error, maxf(float(hinge.lower) - angle, angle - float(hinge.upper)))
	var self_depth := 0.0
	for pair: Array in _contact_pairs:
		var a: RigidBody2D = pair[0]
		var b: RigidBody2D = pair[1]
		if (a.collision_mask & b.collision_layer) == 0 or (b.collision_mask & a.collision_layer) == 0: continue
		for ca: CollisionShape2D in _shape_nodes[a]:
			for cb: CollisionShape2D in _shape_nodes[b]:
				if not _capsule_bounds(ca).intersects(_capsule_bounds(cb)): continue
				self_depth = maxf(self_depth, _contact_correction(ca.shape.collide_and_get_contacts(ca.global_transform, cb.shape, cb.global_transform)).length())
	var world_depth := 0.0
	var space := get_world_2d().direct_space_state
	for body: RigidBody2D in _bodies:
		for col: CollisionShape2D in _shape_nodes[body]:
			var query := PhysicsShapeQueryParameters2D.new()
			query.shape = col.shape
			query.transform = col.global_transform
			query.collision_mask = 1
			world_depth = maxf(world_depth, _contact_correction(space.collide_shape(query, 4)).length())
	_rest_constraints = {"gap_px": gap, "angle_error_rad": angle_error, "self_depth_px": self_depth,
		"world_depth_px": world_depth, "age": _age, "controller_ticks": _constraint_ticks}
	return gap <= 2.0 * _rig_scale and angle_error <= 0.025 \
		and self_depth <= 0.75 * _rig_scale and world_depth <= 0.75 * _rig_scale


func _physics_process(delta: float) -> void:
	var qa_keep_alive := SaveMgr._read_only_qa and bool(get_meta("qa_keep_alive", false))
	if not qa_keep_alive: _age += delta
	if _root_body == null or not is_instance_valid(_root_body):
		retire()
		return
	if _segmented: _update_hinge_stops(delta)
	# A settled chest does not imply settled limbs: wait for every piece so
	# self-contact can finish resolving instead of freezing a rotating arm.
	var calm := true
	var all_sleeping := true
	for body: RigidBody2D in _bodies:
		if is_instance_valid(body) and not body.sleeping: all_sleeping = false
		if is_instance_valid(body) and not body.sleeping and \
				(body.linear_velocity.length()>=22.0 or absf(body.angular_velocity)>=0.6):
			calm = false
			break
	if qa_keep_alive: return
	# Sleeping/calming describes velocity, not whether anatomical constraints
	# and actual contacts have converged. Wait for both before early retirement.
	var converged := not _segmented or ((calm or all_sleeping) and _constraints_at_rest())
	calm = calm and converged
	all_sleeping = all_sleeping and converged
	_settle = _settle + delta if calm else 0.0
	if _age > LIFETIME or (_settle > SETTLE_TIME and _age > 1.5) or (all_sleeping and _age > 0.5):
		set_meta("retirement_reason", "lifetime" if _age > LIFETIME else ("sleeping_converged" if all_sleeping else "settled_converged"))
		retire()


func _process(delta: float) -> void:
	if not _retiring:
		return
	modulate.a = move_toward(modulate.a, 0.0, delta / FADE)
	if modulate.a <= 0.01:
		queue_free()


## Congela todas las piezas donde cayeron y empieza a desvanecer.
func retire() -> void:
	if _retiring:
		return
	_retiring = true
	for b in _bodies:
		if is_instance_valid(b):
			b.freeze = true
	_release_self_layer()
	set_physics_process(false)


## Empujon extra, p. ej. una explosion cerca de un cadaver ya tirado.
func shove(impulse: Vector2) -> void:
	if _retiring:
		return
	for b in _bodies:
		if is_instance_valid(b) and not b.freeze:
			b.apply_central_impulse(impulse * (b.mass / 3.0))
	_settle = 0.0
