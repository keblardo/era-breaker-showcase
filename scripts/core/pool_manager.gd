# © 2026 Cristian Luis Celie. All rights reserved. Portfolio excerpt from Era Breaker: shared for review only, not licensed for use, copying or redistribution.
extends Node
## Generic scene pool. Mid-range Android devices hate allocation spikes, and
## this game throws a lot of short-lived nodes (bullets, casings, numbers).

const HARD_CAP := 400
## Idle visual nodes need not retain hundreds of unique particle materials.
## Active projectiles are never capped here: this only bounds the idle cache.
const IDLE_CAPS := {"projectile.tscn": 128, "impact.tscn": 32,
	"damage_number.tscn": 20, "casing.tscn": 40}

var _pools: Dictionary = {}        ## scene path -> Array[Node]
var _scenes: Dictionary = {}       ## scene path -> PackedScene
var _live: Dictionary = {}         ## scene path -> int


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _exit_tree() -> void:
	# Idle pooled nodes are intentionally outside the SceneTree. The tree
	# cannot free them at shutdown; release those owned nodes synchronously.
	for key: String in _pools:
		for node: Node in _pools[key]:
			if is_instance_valid(node) and node.get_parent() == null:
				node.free()
	_pools.clear()
	_scenes.clear()


func prewarm(scene: PackedScene, count: int) -> void:
	var key := scene.resource_path
	_scenes[key] = scene
	var arr: Array = _pools.get(key, [])
	for i in maxi(0, mini(count, _idle_cap(key)) - arr.size()):
		var n: Node = scene.instantiate()
		n.set_meta("in_scene_pool", true)
		if n.has_method("pool_reset"):
			n.call("pool_reset")
		arr.append(n)
	_pools[key] = arr


## Returns a node that is NOT yet in the tree - the caller adds it.
func acquire(scene: PackedScene) -> Node:
	var key := scene.resource_path
	_scenes[key] = scene
	var arr: Array = _pools.get(key, [])
	var n: Node = null
	while not arr.is_empty() and n == null:
		n = arr.pop_back()
		if not is_instance_valid(n):
			n = null
	if n == null:
		n = scene.instantiate()
	if n.has_meta("in_scene_pool"): n.remove_meta("in_scene_pool")
	_live[key] = int(_live.get(key, 0)) + 1
	_pools[key] = arr
	return n


func release(node: Node) -> void:
	if not is_instance_valid(node):
		return
	# Multiple expiry/budget callbacks may resolve in the same frame. Never
	# cache one node twice or hand the same projectile to two owners later.
	if bool(node.get_meta("in_scene_pool", false)):
		return
	node.set_meta("in_scene_pool", true)
	var key: String = node.scene_file_path
	if key.is_empty():
		node.queue_free()
		return
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	if node.has_method("pool_reset"):
		node.call("pool_reset")
	_live[key] = maxi(0, int(_live.get(key, 0)) - 1)
	var arr: Array = _pools.get(key, [])
	if arr.size() >= _idle_cap(key):
		node.queue_free()
		return
	arr.append(node)
	_pools[key] = arr


func live_count(scene: PackedScene) -> int:
	return int(_live.get(scene.resource_path, 0))


func _idle_cap(key: String) -> int:
	return mini(HARD_CAP, int(IDLE_CAPS.get(key.get_file(), 60)))


func idle_count(scene: PackedScene) -> int:
	return (_pools.get(scene.resource_path, []) as Array).size()


## Called between stages: keeps the pools but drops anything oversized.
func trim(keep: int = 60) -> void:
	for key: String in _pools.keys():
		var arr: Array = _pools[key]
		while arr.size() > mini(keep, _idle_cap(key)):
			var n: Node = arr.pop_back()
			if is_instance_valid(n):
				n.queue_free()
		_pools[key] = arr


func clear_all() -> void:
	for key: String in _pools.keys():
		for n: Node in _pools[key]:
			if is_instance_valid(n):
				n.queue_free()
	_pools.clear()
	_live.clear()


func debug_stats() -> String:
	var s := ""
	for key: String in _pools.keys():
		s += "%s: %d free / %d live\n" % [key.get_file(), (_pools[key] as Array).size(),
			int(_live.get(key, 0))]
	return s
