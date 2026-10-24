# © 2026 Cristian Luis Celie. All rights reserved. Portfolio excerpt from Era Breaker: shared for review only, not licensed for use, copying or redistribution.
"""
Synthesises every sound in the game from scratch: weapon fire, impacts, UI, and
a three-layer adaptive music bed for each of the ten eras.

Nothing here is sampled or downloaded, so there is no licence attached to any
of it. Output is OGG Vorbis (via ffmpeg) with a WAV fallback.
"""
import math
import os
import shutil
import subprocess
import sys

import numpy as np

SR = 44100
MSR = 32000          # music is mono and a little lower rate to save space
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SFX_DIR = os.path.join(ROOT, "assets", "generated", "audio", "sfx")
MUS_DIR = os.path.join(ROOT, "assets", "generated", "audio", "music")
os.makedirs(SFX_DIR, exist_ok=True)
os.makedirs(MUS_DIR, exist_ok=True)

sys.path.insert(0, os.path.dirname(__file__))
from eras import ERAS  # noqa

FFMPEG = shutil.which("ffmpeg")
rng = np.random.default_rng(20260909)


# ------------------------------------------------------------------ helpers
def t(n, sr=SR):
    return np.arange(int(n * sr), dtype=np.float64) / sr


def sine(f, dur, sr=SR, phase=0.0):
    return np.sin(2 * np.pi * f * t(dur, sr) + phase)


def saw(f, dur, sr=SR):
    x = t(dur, sr) * f
    return 2.0 * (x - np.floor(x + 0.5))


def square(f, dur, sr=SR, duty=0.5):
    x = (t(dur, sr) * f) % 1.0
    return np.where(x < duty, 1.0, -1.0)


def noise(dur, sr=SR):
    return rng.uniform(-1, 1, int(dur * sr))


def env(sig, a=0.005, d=0.08, s=0.0, r=0.05, sr=SR):
    """Simple ADSR shaped to the length of sig."""
    n = len(sig)
    e = np.zeros(n)
    ai = min(n, int(a * sr))
    di = min(n - ai, int(d * sr))
    ri = min(n - ai - di, int(r * sr))
    si = max(0, n - ai - di - ri)
    idx = 0
    if ai:
        e[idx:idx + ai] = np.linspace(0, 1, ai)
        idx += ai
    if di:
        e[idx:idx + di] = np.linspace(1, s, di)
        idx += di
    if si:
        e[idx:idx + si] = s
        idx += si
    if ri:
        e[idx:idx + ri] = np.linspace(s, 0, ri)
    return sig * e


def decay(sig, k=18.0, sr=SR):
    return sig * np.exp(-k * t(len(sig) / sr, sr)[:len(sig)])


def lowpass(sig, cutoff, sr=SR):
    """One-pole lowpass. cutoff may be a scalar or a per-sample array."""
    c = np.asarray(cutoff, dtype=np.float64)
    if c.ndim == 0:
        c = np.full(len(sig), float(c))
    alpha = 1.0 - np.exp(-2.0 * np.pi * np.clip(c, 20, sr / 2 - 100) / sr)
    out = np.zeros_like(sig)
    y = 0.0
    for i in range(len(sig)):
        y += alpha[i] * (sig[i] - y)
        out[i] = y
    return out


def hp(sig, cutoff, sr=SR):
    return sig - lowpass(sig, cutoff, sr)


def pitch_sweep(f0, f1, dur, sr=SR, curve=3.0):
    tt = t(dur, sr)
    k = (tt / max(1e-6, dur)) ** (1.0 / curve)
    f = f0 + (f1 - f0) * k
    ph = 2 * np.pi * np.cumsum(f) / sr
    return np.sin(ph)


def softclip(x, drive=1.6):
    return np.tanh(x * drive) / np.tanh(drive)


def norm(x, peak=0.92):
    m = np.max(np.abs(x)) + 1e-9
    return x / m * peak


def pad_to(x, dur, sr=SR):
    n = int(dur * sr)
    if len(x) >= n:
        return x[:n]
    return np.concatenate([x, np.zeros(n - len(x))])


def reverb(x, amount=0.22, sr=SR, size=0.09):
    """Cheap Schroeder-ish tail so impacts sit in a space."""
    out = x.copy()
    for d, g in ((size, 0.42), (size * 1.7, 0.30), (size * 2.6, 0.20)):
        n = int(d * sr)
        if n <= 0 or n >= len(x):
            continue
        tail = np.zeros_like(x)
        tail[n:] = x[:-n] * g
        out += tail * amount
    return out


def save(name, x, sr=SR, directory=None, quality="3"):
    d = directory or SFX_DIR
    x = norm(np.nan_to_num(x))
    pcm = (np.clip(x, -1, 1) * 32767).astype(np.int16)
    wav = os.path.join(d, name + ".wav")
    import wave
    with wave.open(wav, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())
    if FFMPEG:
        ogg = os.path.join(d, name + ".ogg")
        r = subprocess.run([FFMPEG, "-y", "-loglevel", "error", "-i", wav,
                            "-c:a", "libvorbis", "-q:a", quality, ogg],
                           capture_output=True)
        if r.returncode == 0:
            os.remove(wav)
            return
    # keep the WAV if ffmpeg is unavailable - the engine loads either


# ==================================================================== SFX
def gun(body_f, dur, crack=1.0, boom=1.0, bright=6000, tail=0.25):
    """Generic firearm: transient crack + body thump + noise tail."""
    n_noise = noise(dur)
    crack_s = decay(hp(n_noise, 1800), 55) * crack
    body = decay(pitch_sweep(body_f, body_f * 0.35, dur, curve=2.0), 26) * boom
    air = decay(lowpass(n_noise, bright), 9) * 0.5
    x = crack_s * 1.0 + body * 0.9 + air
    return reverb(softclip(x, 1.9), tail)


def build_sfx():
    # ---- primitive / bow weapons
    twang = decay(sine(220, 0.28) + 0.5 * sine(440, 0.28), 26)
    whoosh = decay(lowpass(noise(0.28), 2600), 11) * 0.55
    save("shot_bow", norm(twang * 0.8 + whoosh))

    save("shot_crossbow", norm(decay(hp(noise(0.22), 900), 42) * 0.8
                               + decay(sine(160, 0.22), 30) * 0.6))

    save("shot_lob", norm(decay(lowpass(noise(0.35), 1400), 8) * 0.7
                          + decay(sine(90, 0.35), 12) * 0.5))

    # ---- powder weapons
    save("shot_black_powder", gun(150, 0.62, crack=0.7, boom=1.3, bright=3200, tail=0.4))
    save("shot_gun_small", gun(240, 0.22, crack=1.0, boom=0.7, bright=8000, tail=0.14))
    save("shot_gun_med", gun(190, 0.34, crack=1.0, boom=1.0, bright=7000, tail=0.22))
    save("shot_gun_big", gun(120, 0.55, crack=0.9, boom=1.4, bright=5200, tail=0.34))
    save("shot_shotgun", gun(105, 0.5, crack=1.2, boom=1.5, bright=4200, tail=0.3))

    # ---- energy weapons
    zap = pitch_sweep(1800, 320, 0.3, curve=1.6)
    save("shot_energy", norm(decay(zap, 16) * 0.9
                             + decay(hp(noise(0.3), 3000), 30) * 0.35
                             + decay(sine(90, 0.3), 20) * 0.4))

    rail = pitch_sweep(120, 4200, 0.14, curve=0.6)
    rail = np.concatenate([rail, decay(pitch_sweep(4200, 200, 0.5, curve=2.5), 9)])
    save("shot_rail", norm(reverb(softclip(rail * 0.8
                                           + decay(noise(len(rail) / SR), 12) * 0.3), 0.45)))

    pl = decay(sine(70, 0.45) + 0.6 * sine(105, 0.45), 10)
    plw = decay(lowpass(noise(0.45), 900), 7)
    save("shot_plasma", norm(softclip(pl * 0.9 + plw * 0.6, 2.2)))

    # ---- handling
    save("reload_start", norm(decay(hp(noise(0.16), 2400), 40) * 0.7
                              + decay(sine(300, 0.16), 34) * 0.3))
    click = decay(hp(noise(0.09), 3200), 70)
    save("reload_done", norm(np.concatenate([click, np.zeros(int(0.05 * SR)),
                                             click * 0.8])))
    save("shell_drop", norm(decay(hp(noise(0.13), 4200), 48) * 0.6
                            + decay(sine(2200, 0.13), 40) * 0.35))

    # ---- impacts
    save("impact_flesh", norm(decay(lowpass(noise(0.14), 1500), 40) * 0.9
                              + decay(sine(110, 0.14), 40) * 0.5))
    save("impact_head", norm(decay(lowpass(noise(0.2), 2600), 30) * 1.0
                             + decay(sine(150, 0.2), 26) * 0.6))
    hs = decay(sine(1180, 0.3), 12) + decay(sine(1760, 0.3), 14) * 0.6
    save("headshot", norm(reverb(hs * 0.7 + decay(hp(noise(0.3), 4000), 30) * 0.3, 0.4)))
    save("melee_hit", norm(decay(lowpass(noise(0.18), 1100), 28) * 0.9
                           + decay(sine(85, 0.18), 24) * 0.7))
    save("shield_block", norm(decay(hp(noise(0.26), 2600), 22) * 0.7
                              + decay(sine(620, 0.26), 16) * 0.5
                              + decay(sine(930, 0.26), 20) * 0.3))

    # ---- deaths and damage
    save("enemy_die", norm(decay(lowpass(noise(0.4), 900), 12) * 0.7
                           + decay(pitch_sweep(260, 90, 0.4), 9) * 0.5))
    groan = env(pitch_sweep(150, 62, 0.82, curve=1.8), 0.05, 0.18, 0.62, 0.22)
    groan += env(lowpass(noise(0.82), 520), 0.04, 0.20, 0.42, 0.25) * 0.48
    save("zombie_groan", norm(reverb(softclip(groan, 1.5), 0.20)))
    zdie = decay(pitch_sweep(190, 42, 0.78, curve=2.1), 4.2) * 0.78
    zdie += decay(lowpass(noise(0.78), 760), 5.4) * 0.58
    save("zombie_die", norm(reverb(softclip(zdie, 1.7), 0.28)))
    save("player_hurt", norm(decay(pitch_sweep(420, 160, 0.26), 14) * 0.7
                             + decay(lowpass(noise(0.26), 1600), 18) * 0.5))
    save("player_die", norm(reverb(decay(pitch_sweep(300, 60, 0.9), 5) * 0.9
                                   + decay(lowpass(noise(0.9), 700), 6) * 0.6, 0.5)))

    # ---- explosion
    boom = decay(pitch_sweep(190, 32, 1.1, curve=2.4), 5) * 1.2
    rumble = decay(lowpass(noise(1.1), 420), 4.5) * 0.9
    grit = decay(hp(noise(1.1), 1800), 14) * 0.4
    save("explosion", norm(reverb(softclip(boom + rumble + grit, 2.0), 0.55)))

    # ---- telegraphs and stingers
    save("sniper_charge", norm(env(pitch_sweep(400, 1500, 1.0, curve=1.0),
                                   0.05, 0.1, 0.8, 0.15) * 0.5))
    save("boss_intro", norm(reverb(
        decay(sine(55, 1.6) + 0.5 * sine(82.5, 1.6) + 0.3 * sine(110, 1.6), 2.2) * 1.0
        + decay(lowpass(noise(1.6), 600), 3) * 0.4, 0.6)))
    save("boss_phase", norm(reverb(decay(pitch_sweep(120, 300, 0.7), 5) * 0.8
                                   + decay(hp(noise(0.7), 2000), 8) * 0.4, 0.45)))
    save("wave_clear", norm(_arp([784, 988, 1175], 0.09, 0.34) * 0.55))
    save("level_win", norm(reverb(_arp([523, 659, 784, 1047], 0.13, 0.8) * 0.7, 0.4)))
    save("level_fail", norm(reverb(_arp([392, 349, 294, 233], 0.18, 1.1,
                                        wave="tri") * 0.6, 0.45)))
    save("era_unlock", norm(reverb(_arp([523, 784, 1047, 1319, 1568], 0.11, 1.2) * 0.7,
                                   0.5)))

    # ---- economy and UI
    save("coin", norm(decay(sine(1568, 0.16), 24) * 0.6
                      + decay(sine(2093, 0.16), 20) * 0.4))
    save("ui_click", norm(decay(sine(880, 0.06), 60) * 0.5
                          + decay(hp(noise(0.06), 4000), 90) * 0.25))
    save("ui_purchase", norm(_arp([659, 880, 1319], 0.07, 0.28) * 0.55))
    save("ui_unlock", norm(reverb(_arp([523, 659, 880, 1319], 0.08, 0.5) * 0.6, 0.35)))
    save("ui_error", norm(decay(square(160, 0.16, duty=0.35), 18) * 0.35
                          + decay(square(120, 0.16, duty=0.35), 18) * 0.25))


def _arp(freqs, step, total, wave="sine"):
    out = np.zeros(int(total * SR))
    for i, f in enumerate(freqs):
        start = int(i * step * SR)
        dur = total - i * step
        if dur <= 0.02:
            break
        if wave == "tri":
            s = 2.0 * np.abs(2.0 * ((t(dur) * f) % 1.0) - 1.0) - 1.0
        else:
            s = sine(f, dur) + 0.35 * sine(f * 2, dur)
        s = decay(s, 7.0)
        out[start:start + len(s)] += s
    return out


# ==================================================================== MUSIC
# Each era gets a mode, a root and a tempo. The three stems share all of them
# so they stay phase-locked when the engine crossfades between intensities.
MODES = {
    "aeolian":  [0, 2, 3, 5, 7, 8, 10],
    "phrygian": [0, 1, 3, 5, 7, 8, 10],
    "dorian":   [0, 2, 3, 5, 7, 9, 10],
    "minpent":  [0, 3, 5, 7, 10],
    "locrian":  [0, 1, 3, 5, 6, 8, 10],
}

ERA_MUSIC = {
    "primal":     dict(root=98.0,  mode="minpent",  bpm=84,  tone="tribal"),
    "ancient":    dict(root=110.0, mode="phrygian", bpm=92,  tone="ancient"),
    "medieval":   dict(root=98.0,  mode="dorian",   bpm=96,  tone="choir"),
    "industrial": dict(root=87.3,  mode="aeolian",  bpm=104, tone="metal"),
    "frontier":   dict(root=110.0, mode="minpent",  bpm=100, tone="twang"),
    "modern":     dict(root=82.4,  mode="aeolian",  bpm=112, tone="mil"),
    "nearfuture": dict(root=98.0,  mode="dorian",   bpm=120, tone="synth"),
    "cyber":      dict(root=87.3,  mode="phrygian", bpm=128, tone="synth"),
    "mars":       dict(root=73.4,  mode="aeolian",  bpm=108, tone="wide"),
    "void":       dict(root=65.4,  mode="locrian",  bpm=96,  tone="void"),
}

BARS = 8


def _note(root, mode, degree, octave=0):
    sc = MODES[mode]
    n = sc[degree % len(sc)] + 12 * (degree // len(sc)) + 12 * octave
    return root * (2.0 ** (n / 12.0))


def _pad(freqs, dur, tone):
    n = int(dur * MSR)
    out = np.zeros(n)
    for f in freqs:
        for det in (-0.06, 0.0, 0.07):
            ff = f * (1 + det / 100.0 * 12)
            if tone in ("synth", "void", "wide"):
                s = saw(ff, dur, MSR) * 0.5 + sine(ff, dur, MSR) * 0.5
            else:
                s = sine(ff, dur, MSR) + 0.3 * sine(ff * 2, dur, MSR) \
                    + 0.15 * sine(ff * 3, dur, MSR)
            out[:len(s)] += s[:n] / (len(freqs) * 3.0)
    # slow filter sweep gives the pad movement without any samples
    sweep = 500 + 900 * (0.5 + 0.5 * np.sin(2 * np.pi * 0.06 * t(dur, MSR)))
    out = lowpass(out, sweep, MSR)
    fade = np.minimum(1.0, np.linspace(0, 12, n))
    return out * fade * np.minimum(1.0, np.linspace(12, 0, n) + 0.001) ** 0.0


def _kick(dur=0.28):
    s = pitch_sweep(150, 42, dur, MSR, curve=2.0)
    return decay(s, 22, MSR) * 1.0


def _snare(dur=0.22):
    return (decay(hp(noise(dur, MSR), 1400), 26, MSR) * 0.8
            + decay(sine(190, dur, MSR), 30, MSR) * 0.4)


def _hat(dur=0.07):
    return decay(hp(noise(dur, MSR), 6000), 90, MSR) * 0.4


def _tom(f, dur=0.3):
    return decay(pitch_sweep(f, f * 0.5, dur, MSR, curve=2.0), 16, MSR) * 0.8


def _place(buf, sig, at_s):
    i = int(at_s * MSR)
    n = min(len(sig), len(buf) - i)
    if n > 0 and i >= 0:
        buf[i:i + n] += sig[:n]


def build_music():
    for era in ERAS:
        key = era["key"]
        cfg = ERA_MUSIC[key]
        bpm = cfg["bpm"]
        beat = 60.0 / bpm
        bar = beat * 4
        total = bar * BARS
        n = int(total * MSR)
        root = cfg["root"]
        mode = cfg["mode"]
        tone = cfg["tone"]

        # ---------------- ambient: pad + sparse bell
        amb = np.zeros(n)
        prog = [0, 5, 3, 4]
        for b in range(BARS):
            deg = prog[b % len(prog)]
            chord = [_note(root, mode, deg, 0),
                     _note(root, mode, deg + 2, 0),
                     _note(root, mode, deg + 4, 0)]
            _place(amb, _pad(chord, bar * 1.02, tone) * 0.42, b * bar)
        for b in range(0, BARS, 2):
            f = _note(root, mode, (b // 2) % 5, 2)
            bell = decay(sine(f, 1.6, MSR) + 0.4 * sine(f * 2.01, 1.6, MSR), 3.0, MSR)
            _place(amb, bell * 0.16, b * bar + beat * 2)
        if tone in ("void", "wide", "synth"):
            amb += lowpass(noise(total, MSR), 420, MSR) * 0.03
        save("%s_ambient" % key, amb, MSR, MUS_DIR, quality="2")

        # ---------------- combat: drums + bass ostinato
        com = np.zeros(n)
        pattern = [0, 3, 5, 3, 7, 5, 3, 0]
        for b in range(BARS):
            for step in range(8):
                tpos = b * bar + step * (beat / 2.0)
                if step in (0, 4) or (step == 6 and b % 2 == 1):
                    _place(com, _kick() * 0.85, tpos)
                if step in (2, 6):
                    _place(com, _snare() * 0.55, tpos)
                _place(com, _hat() * (0.5 if step % 2 == 0 else 0.28), tpos)
                # bass note on every eighth
                bf = _note(root, mode, pattern[(b * 8 + step) % len(pattern)], -1)
                bs = saw(bf, beat / 2.0 * 0.9, MSR) * 0.5 + sine(bf, beat / 2.0 * 0.9, MSR)
                bs = lowpass(decay(bs, 9, MSR), 520, MSR)
                _place(com, bs * 0.30, tpos)
            if tone == "tribal":
                _place(com, _tom(120) * 0.5, b * bar + beat * 3)
                _place(com, _tom(90) * 0.4, b * bar + beat * 3.5)
        save("%s_combat" % key, softclip(com, 1.3), MSR, MUS_DIR, quality="2")

        # ---------------- boss: heavier drums + stabs
        boss = np.zeros(n)
        for b in range(BARS):
            for step in range(16):
                tpos = b * bar + step * (beat / 4.0)
                if step % 4 == 0:
                    _place(boss, _kick(0.3) * 1.0, tpos)
                if step % 8 == 4:
                    _place(boss, _snare(0.26) * 0.8, tpos)
                if step % 2 == 0:
                    _place(boss, _hat(0.05) * 0.3, tpos)
            deg = [0, 0, 3, 5][b % 4]
            stab_f = [_note(root, mode, deg, 0), _note(root, mode, deg + 2, 0),
                      _note(root, mode, deg + 4, 0), _note(root, mode, deg, 1)]
            for f in stab_f:
                s = decay(saw(f, beat * 1.5, MSR) * 0.6 + square(f, beat * 1.5, MSR) * 0.3,
                          5, MSR)
                s = lowpass(s, 1700, MSR)
                _place(boss, s * 0.16, b * bar)
            # tremolo tension line
            trem_f = _note(root, mode, 1, 1)
            trem = sine(trem_f, bar, MSR) * (0.5 + 0.5 * np.sign(
                np.sin(2 * np.pi * (bpm / 60.0 * 4) * t(bar, MSR))))
            _place(boss, lowpass(trem, 2200, MSR) * 0.07, b * bar)
        save("%s_boss" % key, softclip(boss, 1.4), MSR, MUS_DIR, quality="2")
        print("music", key)


if __name__ == "__main__":
    print("ffmpeg:", "yes" if FFMPEG else "NO (writing wav)")
    build_sfx()
    print("sfx done")
    build_music()
    print("audio done")
