"""Build the port's music set from soundtrack files (FLAC/WAV): looping songs become "<name> intro.ogg" + "<name> loop.ogg"
(sample-exact loop, intro a whole number of 1/60 s frames), one-shot jingles are trimmed, all Vorbis q6; writes lengths.txt
for the engine (fairyland/app/audio/audio.rb). tracks.txt (command -> track) is written by hand.

usage: python3 ost_loops.py <source dir> <out dir> [--find]
  Loop points come from <source dir>/loops.txt, lines "<name> = <start sample> <period samples>" (44.1 kHz, the name is the
  file name without its extension). --find detects them instead (the song must repeat at least once in the recording) and
  prints lines for loops.txt. Files whose name starts with "02" (the jingle that chains into the round BGM) are cut to
  CHAIN_FRAMES after their first note, the gap measured on the arcade. Needs ffmpeg and numpy.
"""
import os, sys, subprocess
import numpy as np

SR = 44100
FRAME = SR // 60  # 735 samples
# The round-start jingle ("02 ...") chains into the round BGM: measured from MAME's audio of a coin-up + round start, the
# BGM begins 3.815 s after the jingle's first note -> the jingle file is exactly 229 frames long from its first note.
CHAIN_FRAMES = 229
# Mastered near 0 dBFS, the Vorbis files decoded up to +2 dBFS (clipping); -3 dB keeps them below full scale and leaves
# headroom for the effects on top.
GAIN = 10 ** (-3 / 20)


def load(path, ch=2):
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-f', 'f32le', '-ac', str(ch), '-ar', str(SR), '-'],
                         capture_output=True, check=True).stdout
    x = np.frombuffer(raw, dtype=np.float32).astype(np.float64)
    return x.reshape(-1, ch) if ch > 1 else x


def frames(x, hop=1024, n=2048):
    k = (len(x) - n) // hop
    idx = np.arange(n)[None, :] + hop * np.arange(k)[:, None]
    spec = np.abs(np.fft.rfft(x[idx] * np.hanning(n), axis=1))
    edges = np.unique(np.geomspace(4, spec.shape[1] - 1, 49).astype(int))
    bands = np.stack([spec[:, a:b].sum(1) for a, b in zip(edges[:-1], edges[1:])], 1)
    f = np.log1p(bands * 100)
    f -= f.mean(1, keepdims=True)
    f /= np.linalg.norm(f, axis=1, keepdims=True) + 1e-9
    return f


def find_loop(x, min_loop=6.0, min_overlap=4.0, hop=1024):
    """(start, period, score) in samples, or None if nothing repeats convincingly"""
    F = frames(x, hop)
    T = len(F)
    w2 = int(2 * SR / hop)
    best = (0, 0)
    for L in range(int(min_loop * SR / hop), T - int(min_overlap * SR / hop)):
        sim = (F[:T - L] * F[L:]).sum(1)
        m = np.convolve(sim, np.ones(w2) / w2, mode='valid')
        if len(m):
            best = max(best, (np.percentile(m, 90), L))
    score, L = best
    if score < 0.95:
        return None
    sim = (F[:-L] * F[L:]).sum(1)
    w = int(4 * SR / hop)
    ok = np.convolve(sim > 0.95, np.ones(w), mode='valid') >= w * 0.98
    a = int(np.argmax(ok)) * hop + SR
    seg = x[a:a + 3 * SR]
    period = max(range(L * hop - 2 * hop, L * hop + 2 * hop + 1),
                 key=lambda p: np.dot(seg, x[a + p:a + p + len(seg)]) / (np.linalg.norm(x[a + p:a + p + len(seg)]) + 1e-12))
    start = a
    while start - 441 > 0:  # walk back while the music still matches one period later
        t = start - 441
        u, v = x[t:t + SR // 2], x[t + period:t + period + SR // 2]
        if np.dot(u, v) / (np.linalg.norm(u) * np.linalg.norm(v) + 1e-12) < 0.98:
            break
        start = t
    return start, period, score


def write(out, name, data):
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'f32le', '-ac', '2', '-ar', str(SR), '-i', '-',
                    '-c:a', 'libvorbis', '-q:a', '6', os.path.join(out, name + '.ogg')],
                   input=(data * GAIN).astype(np.float32).tobytes(), check=True)
    return len(data)


def bounds(x, db=-50):
    nz = np.where(np.abs(x).max(1) > 10 ** (db / 20))[0]
    return nz[0], nz[-1]


def main():
    src, out = sys.argv[1], sys.argv[2]
    names = sorted(f.rsplit('.', 1)[0] for f in os.listdir(src) if f.lower().endswith(('.flac', '.wav')))
    path = {n: os.path.join(src, f) for f in os.listdir(src) for n in [f.rsplit('.', 1)[0]] if n in names}
    if '--find' in sys.argv:
        for n in names:
            r = find_loop(load(path[n], 1))
            print(f'{n} = {r[0]} {r[1]}' if r else f'# {n}: no repeat found (one-shot)')
        return
    loops = {}
    lp = os.path.join(src, 'loops.txt')
    if os.path.exists(lp):
        for line in open(lp):
            if '=' in line and not line.startswith('#'):
                k, v = line.rsplit('=', 1)
                a, b = v.split()
                loops[k.strip()] = (int(a), int(b))
    os.makedirs(out, exist_ok=True)
    lengths = {}
    for n in names:
        x = load(path[n])
        first, last = bounds(x)
        if n in loops:
            start, period = loops[n]
            head = max(first - 64, 0)
            s2 = head + ((start - head + FRAME - 1) // FRAME) * FRAME  # any point after the loop start is on the loop
            lengths[n + ' intro'] = write(out, n + ' intro', x[head:s2])
            lengths[n + ' loop'] = write(out, n + ' loop', x[s2:s2 + period])
            print(f'{n}: intro {(s2 - head) / SR:.3f}s, loop {period / SR:.4f}s')
        else:
            end = min(len(x), last + int(0.25 * SR))
            if n.startswith('02'):
                end = min(len(x), first + CHAIN_FRAMES * FRAME)
            lengths[n] = write(out, n, x[first:end])
            print(f'{n}: {(end - first) / SR:.3f}s once')
    with open(os.path.join(out, 'lengths.txt'), 'w') as fh:
        fh.writelines(f'{k} = {v}\n' for k, v in sorted(lengths.items()))


if __name__ == '__main__':
    main()
