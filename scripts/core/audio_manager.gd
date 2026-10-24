# © 2026 Cristian Luis Celie. All rights reserved. Portfolio excerpt from Era Breaker: shared for review only, not licensed for use, copying or redistribution.
extends Node
## Pooled SFX playback plus a three-layer adaptive music system.
##
## Music is built from three stems per era that share a tempo and length:
##   ambient  - always audible while the era is loaded
##   combat   - faded in while enemies are engaged
##   boss     - faded in for elite and boss encounters
## Layers are crossfaded, never hard-cut.

const SFX_VOICES := 20
const MUSIC_FADE := 1.4
const SFX_DIR := "res://assets/generated/audio/sfx/"
const MUSIC_DIR := "res://assets/generated/audio/music/"

enum Intensity { AMBIENT, COMBAT, BOSS }

var _sfx: Array[AudioStreamPlayer] = []
var _next_voice := 0
var _cache: Dictionary = {}
var _music: Dictionary = {}          ## layer name -> AudioStreamPlayer
var _current_era := ""
var _intensity: Intensity = Intensity.AMBIENT
var _targets := {"ambient": 0.0, "combat": 0.0, "boss": 0.0}
var _last_played: Dictionary = {}    ## name -> msec, to stop machine-gun stacking
var test_muted := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Test-only silence, applied before any voice/music can start. Never writes
	# the player's saved volume settings or strips audio from the final game.
	test_muted = not OS.has_feature("release") and "--mute" in OS.get_cmdline_user_args()
	if test_muted:
		AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), true)
		AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Master"), -80.0)
	for i in SFX_VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_sfx.append(p)
	for layer: String in ["ambient", "combat", "boss"]:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		p.volume_db = -60.0
		add_child(p)
		_music[layer] = p
	apply_settings()


func apply_settings() -> void:
	var sfx_vol := 0.0 if test_muted else float(SaveMgr.get_setting("sfx", 0.9))
	for p: AudioStreamPlayer in _sfx:
		p.volume_db = linear_to_db(maxf(0.0001, sfx_vol))
	_update_music_volumes(true)


func _process(delta: float) -> void:
	var music_vol := 0.0 if test_muted else float(SaveMgr.get_setting("music", 0.8))
	for layer: String in _music.keys():
		var p: AudioStreamPlayer = _music[layer]
		if p.stream == null:
			continue
		var want: float = _targets[layer] * music_vol
		var cur := db_to_linear(p.volume_db) if p.volume_db > -59.0 else 0.0
		cur = move_toward(cur, want, delta / MUSIC_FADE)
		p.volume_db = linear_to_db(cur) if cur > 0.001 else -60.0


# ------------------------------------------------------------------ sfx
func _stream(name: String) -> AudioStream:
	if _cache.has(name):
		return _cache[name]
	var s: AudioStream = null
	for ext: String in [".ogg", ".wav"]:
		var path := SFX_DIR + name + ext
		if ResourceLoader.exists(path):
			s = ResourceLoader.load(path)
			break
	_cache[name] = s
	return s


## pitch_var adds a random semitone spread so repeated shots never phase-lock.
func play(name: String, volume: float = 1.0, pitch_var: float = 0.08,
		min_gap_ms: int = 25) -> void:
	if test_muted:
		return
	var now := Time.get_ticks_msec()
	if int(_last_played.get(name, -9999)) + min_gap_ms > now:
		return
	_last_played[name] = now
	var s := _stream(name)
	if s == null:
		return
	var p := _sfx[_next_voice]
	_next_voice = (_next_voice + 1) % SFX_VOICES
	p.stream = s
	p.pitch_scale = 1.0 + randf_range(-pitch_var, pitch_var)
	p.volume_db = linear_to_db(maxf(0.0001,
		volume * float(SaveMgr.get_setting("sfx", 0.9))))
	p.play()


## Distance-attenuated variant for things happening away from the player.
func play_at(name: String, world_pos: Vector2, listener: Vector2,
		volume: float = 1.0) -> void:
	var d := world_pos.distance_to(listener)
	var att := clampf(1.0 - d / 1600.0, 0.12, 1.0)
	play(name, volume * att)


# ------------------------------------------------------------------ music
func play_era(era_id: String) -> void:
	if era_id == _current_era:
		return
	_current_era = era_id
	for layer: String in _music.keys():
		var p: AudioStreamPlayer = _music[layer]
		var path := "%s%s_%s.ogg" % [MUSIC_DIR, era_id, layer]
		if not ResourceLoader.exists(path):
			path = "%s%s_%s.wav" % [MUSIC_DIR, era_id, layer]
		if ResourceLoader.exists(path):
			p.stream = ResourceLoader.load(path)
			p.volume_db = -60.0
			p.play()
		else:
			p.stream = null
			p.stop()
	set_intensity(Intensity.AMBIENT)
	# start all layers together so they stay phase-locked for crossfading
	var t := 0.0
	for layer: String in _music.keys():
		var p: AudioStreamPlayer = _music[layer]
		if p.stream != null:
			p.seek(t)


func set_intensity(level: Intensity) -> void:
	_intensity = level
	match level:
		Intensity.AMBIENT:
			_targets = {"ambient": 0.85, "combat": 0.0, "boss": 0.0}
		Intensity.COMBAT:
			_targets = {"ambient": 0.55, "combat": 0.9, "boss": 0.0}
		Intensity.BOSS:
			_targets = {"ambient": 0.35, "combat": 0.6, "boss": 1.0}


func _update_music_volumes(instant: bool) -> void:
	if not instant:
		return
	var music_vol := 0.0 if test_muted else float(SaveMgr.get_setting("music", 0.8))
	for layer: String in _music.keys():
		var p: AudioStreamPlayer = _music[layer]
		var want: float = _targets[layer] * music_vol
		p.volume_db = linear_to_db(want) if want > 0.001 else -60.0


func stop_music() -> void:
	_current_era = ""
	for p: AudioStreamPlayer in _music.values():
		p.stop()


func duck(_seconds: float = 0.6) -> void:
	## Used when an interstitial takes over the screen.
	for p: AudioStreamPlayer in _music.values():
		p.volume_db = -60.0


func haptic(ms: int = 20) -> void:
	if not bool(SaveMgr.get_setting("haptics", true)):
		return
	if OS.get_name() == "Android":
		Input.vibrate_handheld(ms)
