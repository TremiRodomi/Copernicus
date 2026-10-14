#!/usr/bin/env python3
"""Build the X68000 music sets (audio/original/, audio/arrange/) from the VGM rip (vgm.mdscene.net package by Sonic of 8!).

    python3 -I vgm_sets.py <vgz dir> <vgm2wav> <audio dir> [--ref <arcade round BGM loop>] [--scratch DIR]

<vgm2wav> = libvgm's renderer (github.com/ValleyBell/libvgm, BUILD_VGM2WAV; MAME's vgmplay driver refuses to start
without unrelated chip ROMs). Each track is rendered at the VGM timebase (44100 Hz, --loops 2 --fade 0), so the
header's total / loop sample counts cut it exactly: intro = the first (total - loop) samples rounded UP to whole
1/60 s frames (735 samples: Audio switches intro -> loop on a frame count), loop = the next `loop` samples. FM operator
phases make the second pass differ in samples from the first, so the loop's last 10 ms are blended into what precedes
its start (the intro's end) - the wrap then runs on continuously. One-shots keep the VGM's full length (the driver's
song length = what the game's "music busy" waits see), except TRIM (cut after the audible tail). Writes <set>/music/*.ogg, tracks.txt, lengths.txt.
Level: libvgm renders far hotter than the arcade OST the effects were matched to, so with --ref each set gets ONE gain
that gives its Main Theme 1 loop the loudness (RMS of the active 10 ms blocks) of that file - the arcade OST's round
BGM loop; the balance inside a soundtrack is kept.
The output is game audio: keep it local (release bundles only).
"""
import gzip
import os
import struct
import subprocess
import sys
import wave

import numpy as np

FRAME = 735
BLEND = 441  # 10 ms
# One-shots whose length paces the port with an X68000 soundtrack (the round clear and the intermission wait for the
# music on a real X68000; user: they ran a little long): cut at the end of the audible tail (-60 dB below the peak,
# rounded up to a frame) instead of the VGM's full length, which carries up to ~0.9 s of silence.
TRIM = {'0c', '0d'}
TRIM_DB = 60
# $15 (the moon's morning, $72c6) = the Coin jingle on a real X68000 (user; $4ee maps it to MDRV song 17, not in the rip).
# rip track -> commands; "*" = the loop part alone, looped (the BGM restarts after the moon / a potion: $09 / $31)
ORIGINAL = {
    '01 Wake Up': ['14'], '02 Coin': ['06', '15'], '03 Round Intro ~ Main Theme 1': ['07', '09*'],
    '04 Round Intro ~ Main Theme 2': ['30', '31*'], '05 Extend': ['08'], '06 Power-Up': ['0a', '3f'], '07 Miss': ['0b'],
    '08 Round Clear': ['0c'], '09 Round Demo': ['0d'], '10 Hurry Up': ['12'], '11 Ending': ['13'], '12 Game Over': ['10'],
    '13 Name Entry': ['11'],
}
ARRANGE = {  # no Arrange versions of Wake Up / Coin / Extend in either the game or the rip: the Original ones
    '01 Wake Up': ['14'], '02 Coin': ['06', '15'], '14 Round Intro ~ Main Theme 1 (Arrange)': ['07', '09*'],
    '15 Round Intro ~ Main Theme 2 (Arrange)': ['30', '31*'], '05 Extend': ['08'], '16 Power-Up (Arrange)': ['0a', '3f'],
    '17 Miss (Arrange)': ['0b'], '18 Round Clear (Arrange)': ['0c'], '19 Round Demo (Arrange)': ['0d'],
    '20 Hurry Up (Arrange)': ['12'], '21 Ending (Arrange)': ['13'], '22 Game Over (Arrange)': ['10'],
    '23 Name Entry (Arrange)': ['11'],
}


def header(path):
    d = gzip.open(path).read()
    if d[:4] != b'Vgm ':
        raise ValueError(f'{path}: not a VGM file')
    total, _, loop = struct.unpack('<III', d[0x18:0x24])
    return total, loop


def rms(x):
    m = x.mean(axis=1) if x.ndim == 2 else x
    b = 441
    sd = m[:len(m) // b * b].reshape(-1, b).std(axis=1)
    sd = sd[sd > sd.max() * 0.1]
    return float(np.sqrt((sd ** 2).mean()))


def decode(path):
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-f', 's16le', '-ac', '2', '-ar', '44100', '-'],
                         check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.int16).reshape(-1, 2).astype(float)


def ogg(x, path):
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 's16le', '-ar', '44100', '-ac', '2', '-i', '-', '-c:a', 'libvorbis',
                    '-q:a', '6', path], input=np.clip(x, -32768, 32767).astype(np.int16).tobytes(), check=True)


def render(name, src, renderer, scratch):
    wav = f'{scratch}/{name}.wav'
    if not os.path.exists(wav):
        subprocess.run([renderer, '--loops', '2', '--fade', '0', f'{src}/{name}.vgz', wav], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with wave.open(wav) as w:
        assert w.getframerate() == 44100 and w.getnchannels() == 2
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).reshape(-1, 2).astype(float)


def audible_end(x, total):
    """samples up to the last 10 ms block within TRIM_DB of the peak, rounded up to whole frames"""
    m = x[:total].mean(axis=1)
    n = len(m) // BLEND
    sd = m[:n * BLEND].reshape(n, BLEND).std(axis=1)
    last = np.nonzero(sd > sd.max() * 10 ** (-TRIM_DB / 20))[0][-1] + 1
    return min(total, -(-last * BLEND // FRAME) * FRAME)


def build(name, src, renderer, scratch, music, gain=1.0, trim=False):
    """-> (base name, intro samples or None, length samples)"""
    total, loop = header(f'{src}/{name}.vgz')
    x = render(name, src, renderer, scratch) * gain
    base = name.split(' ', 1)[1].replace('Round Intro ~ ', '')  # "Main Theme 1 (Arrange)" ...
    if not loop:
        if trim:
            total = audible_end(x, total)
            fade = np.linspace(1, 0, BLEND)[:, None]  # (the tail is already below -60 dB: no click)
            x = x.copy()
            x[total - BLEND:total] *= fade
        ogg(x[:total], f'{music}/{base}.ogg')
        return base, None, total
    intro = -(-(total - loop) // FRAME) * FRAME
    if intro + loop > len(x):
        raise ValueError(f'{name}: render too short')
    lp = x[intro:intro + loop].copy()
    r = np.linspace(0, 1, BLEND)[:, None]
    lp[-BLEND:] = lp[-BLEND:] * (1 - r) + x[intro - BLEND:intro] * r
    ogg(x[:intro], f'{music}/{base} intro.ogg')
    ogg(lp, f'{music}/{base} loop.ogg')
    return base, intro, loop


def main():
    args = sys.argv[1:]
    scratch = os.path.abspath('vgm_scratch')
    ref = None
    if '--ref' in args:
        i = args.index('--ref')
        ref = decode(args[i + 1])
        del args[i:i + 2]
    if '--scratch' in args:
        i = args.index('--scratch')
        scratch = os.path.abspath(args[i + 1])
        del args[i:i + 2]
    if len(args) != 3:
        sys.exit(__doc__)
    src, renderer, audio = args
    os.makedirs(scratch, exist_ok=True)
    for set_name, table in (('original', ORIGINAL), ('arrange', ARRANGE)):
        music = f'{audio}/{set_name}/music'
        os.makedirs(music, exist_ok=True)
        tracks, lengths = [], []
        gain = 1.0
        if ref is not None:
            theme = next(k for k in table if 'Main Theme 1' in k)
            total, loop = header(f'{src}/{theme}.vgz')
            gain = rms(ref) / rms(render(theme, src, renderer, scratch)[total - loop:total])
            print(f'{set_name}: gain x{gain:.3f} ({20 * np.log10(gain):+.1f} dB, Main Theme 1 loop matched to the reference)')
        for name, cmds in table.items():
            base, intro, n = build(name, src, renderer, scratch, music, gain, bool(TRIM & set(cmds)))
            if intro is None:
                lengths.append(f'{base} = {n}')
            else:
                lengths.append(f'{base} intro = {intro}')
            for c in cmds:
                tracks.append(f'{c[:2]} = {base}' + ('*' if c.endswith('*') else ''))
            print(f'{set_name}: {base}: ' + (f'{n / 44100:.2f} s' if intro is None else
                                            f'intro {intro / 44100:.2f} s + loop {n / 44100:.2f} s') + f' -> {", ".join(cmds)}')
        with open(f'{music}/tracks.txt', 'w') as fh:
            fh.write(f'# X68000 {set_name.upper()} music (VGM rip, vgm_sets.py) -> sound commands. "X*" = the loop part '
                     'of X alone, looped.\n# $0f and $38 (Holy Gem, looped) are recorded from MAME (mame_fm.py: run it again after this script); $15 = Coin.\n')
            fh.write('\n'.join(sorted(tracks)) + '\n')
        with open(f'{music}/lengths.txt', 'w') as fh:
            fh.write('\n'.join(lengths) + '\n')


if __name__ == '__main__':
    main()
