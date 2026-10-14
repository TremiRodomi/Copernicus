#!/usr/bin/env python3
"""X68000 FM songs the VGM rip lacks, cut from a MAME recording made by mame_check/fm_x68.lua (NOTES pass 47).

  mame_fm.py <fm.wav> <fm.log> <audio dir> <set> <song hex> <cmd hex> <name> <gain> [--loop <start s> <length s>]

fm.wav: MAME -wavwrite (48 kHz, x68000: 6 channels, the sound is on 0/1); fm.log: "song <hex> <emulated time> ..."
lines. The song is cut from its trigger to the end of its audible tail, the DC offset of MAME's output removed (the
mean of the window's last second: silence for a one-shot), scaled by <gain> (MAME -> the set's level: ORIGINAL 1.334, ARRANGE 0.973 = the median
over the jingles both have), resampled to 44.1 kHz stereo and written as <audio dir>/<set>/music/<name>.ogg. The
set's tracks.txt gets "<cmd> = <name>" and lengths.txt "<name> = <samples>" (replaced if there; vgm_sets.py rewrites
both files: run this again after it).
--loop: a looping song -> "<name> intro.ogg" + "<name> loop.ogg", like vgm_sets.py: the loop is <length> s from <start> s
after the trigger (exact values from the YM2151 writes: fm_x68.lua FM_OPM, NOTES pass 48), the intro whole 1/60 s frames
ending there (from just before the first note), the loop's last 10 ms blended into what precedes its start.
"""
import subprocess
import sys
import wave

import numpy as np

wav, log, audio, set_name, song, cmd, name, gain = sys.argv[1:9]
gain = float(gain)
loop = [float(v) for v in sys.argv[10:12]] if sys.argv[9:10] == ['--loop'] else None
FRAME, BLEND = 735, 441  # 44.1 kHz: 1/60 s, 10 ms
times = {l.split()[1]: float(l.split()[2]) for l in open(log) if l.startswith('song')}
w = wave.open(wav)
sr, ch = w.getframerate(), w.getnchannels()
t0 = times[song.lower()]
w.setpos(int(t0 * sr))


def to44k(y):
    res = subprocess.run(['ffmpeg', '-v', 'error', '-f', 's16le', '-ar', str(sr), '-ac', '2', '-i', '-', '-ar', '44100',
                          '-f', 's16le', '-'], input=np.clip(y, -32768, 32767).astype(np.int16).tobytes(),
                         capture_output=True, check=True)
    return np.frombuffer(res.stdout, dtype=np.int16).reshape(-1, 2).astype(np.float64)


def ogg(y, out):
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 's16le', '-ar', '44100', '-ac', '2', '-i', '-', '-c:a', 'libvorbis',
                    '-q:a', '6', out], input=np.clip(y, -32768, 32767).astype(np.int16).tobytes(), check=True)


def upsert(path, key, line):
    rows = [r for r in open(path).read().splitlines() if r.split(' = ')[0] != key]
    rows.append(line)
    open(path, 'w').write('\n'.join(rows) + '\n')


music = f'{audio}/{set_name}/music'
if loop:
    start, length = loop
    x = np.frombuffer(w.readframes(int((start + length + 1) * sr)), dtype=np.int16).reshape(-1, ch)[:, :2]
    x = x.astype(np.float64)
    x -= x.mean(axis=0)  # MAME's DC offset (the music itself averages out over the window)
    y = to44k(x * gain)
    ls, ln = round(start * 44100), round(length * 44100)
    env = np.sqrt((y[:ls // BLEND * BLEND] ** 2).sum(axis=1).reshape(-1, BLEND).mean(axis=1))
    first = max(np.nonzero(env > np.sqrt((y ** 2).sum(axis=1)).mean() * 0.05)[0][0] - 1, 0) * BLEND
    n_in = -(-(ls - first) // FRAME) * FRAME
    lp = y[ls:ls + ln].copy()
    r = np.linspace(0, 1, BLEND)[:, None]
    lp[-BLEND:] = lp[-BLEND:] * (1 - r) + y[ls - BLEND:ls] * r
    intro = y[max(ls - n_in, 0):ls]
    if len(intro) < n_in:
        intro = np.vstack([np.zeros((n_in - len(intro), 2)), intro])
    ogg(intro, f'{music}/{name} intro.ogg')
    ogg(lp, f'{music}/{name} loop.ogg')
    upsert(f'{music}/tracks.txt', cmd.lower(), f'{cmd.lower()} = {name}')
    upsert(f'{music}/lengths.txt', f'{name} intro', f'{name} intro = {n_in}')
    print(f'{set_name} song {song}: intro {n_in} samples ({n_in / 44100:.3f} s, first note {first / 44100:.3f} s), '
          f'loop {ln} samples ({ln / 44100:.3f} s), peak {np.abs(y).max():.0f} -> {music}/{name} intro/loop.ogg')
    sys.exit(0)
x = np.frombuffer(w.readframes(int(9.0 * sr)), dtype=np.int16).reshape(-1, ch)[:, :2].astype(np.float64)
x -= x[-sr:].mean(axis=0)  # MAME's DC offset: the last second of the window is silence for a one-shot

H = sr // 100  # 10 ms windows
env = np.sqrt((x[: len(x) // H * H] ** 2).sum(axis=1).reshape(-1, H).mean(axis=1))
peak = env.max()
loud = np.nonzero(env > peak * 0.05)[0]
start = max(loud[0] - 1, 0) * H                     # one window before the first note
floor = np.median(env[-100:])                       # MAME's noise floor (the window's last second)
end = (np.nonzero(env > max(peak * 0.001, floor * 4))[0][-1] + 5) * H  # -60 dB or 12 dB over the floor, + 50 ms
y = x[start:end] * gain
fade = min(len(y), sr // 50)
y[-fade:] *= np.linspace(1, 0, fade)[:, None]
print(f'{set_name} song {song}: {start / sr:.3f} s after the trigger, {len(y) / sr:.3f} s, peak {np.abs(y).max():.0f}, '
      f'floor {20 * np.log10(floor / peak):.0f} dB')

out = f'{music}/{name}.ogg'
z = to44k(y)
n = len(z)
ogg(z, out)
upsert(f'{music}/tracks.txt', cmd.lower(), f'{cmd.lower()} = {name}')
upsert(f'{music}/lengths.txt', name, f'{name} = {n}')
print(f'-> {out} ({n} samples)')
