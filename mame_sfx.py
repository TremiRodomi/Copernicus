#!/usr/bin/env python3
"""Record The Fairyland Story's sound commands one by one from MAME's arcade sound emulation (flstory).

    python3 -I mame_sfx.py <out dir> [hex cmd ...] [--ref <credit jingle file>] [--eq shelf|jotego|flat] [--mame-mix] [--scratch DIR] [--keep]
                          [--reuse]

The main CPU is frozen once the attract has started (so the game sends nothing more), the sound board is unmuted ($ef),
then every command is written to the sound latch ($d400) on its own: $00 (stop all), $ef, the command, a listening
window, $00. $21 (the locked looping sample) gets $01 first. MAME's -wavwrite output is split at the logged frames and
each piece trimmed to its first / last audible 10 ms block (by the sample-to-sample difference) (+ 0.25 s tail), DC removed (the idle DAC level moves)
and 2 ms fades, into <out dir>/<cmd hex>.wav. MAME's mix is quiet, so ONE gain goes on every piece (the relative levels
stay the arcade's): with --ref, the gain that matches MAME's $06 (credit jingle, always recorded) to that file - e.g.
the OST's "01 Credit.ogg", so effects sit against the music as on the board; else the loudest piece peaks at -1 dBFS.

TA7630 (default): MAME does not emulate the board's TA7630 tone / balance amplifier, and it reads $ce00 as a second
MSM volume. Per Jotego's schematic-based FPGA core (jtcores/cores/flstory): $cc00 = MSM {volume, balance between the
MSM's two output groups}, $ce00 = MSM {treble, bass}, AY port A = AY {volume, balance}, AY port B = AY {treble, bass}.
So MAME runs 4 times with the same schedule; a write tap forces the volume bytes so each run has one source at full
MAME volume and the rest at 0 (MSM group 1 / group 2 / AY / none). The runs are deterministic, so differences give the
clean stems (+ the DAC, which bypasses the TA7630). The real register writes are logged with their times and the
stems are mixed again through a port of Jotego's jt7630_bal / jt7630_vol and a tone stage: --eq shelf (default:
first-order shelves, 8 = flat, -16 + 2n dB - the game idles at $88 everywhere) or --eq jotego (his jt7630_equ as
built: branch sum, coefficients designed for 192 kHz running at 48 kHz, so setting 8 already lifts the highs ~6.5 dB)
or --eq flat (volume / balance only: what the board would give with the tone controls ignored). Prints which settings each
command uses. --mame-mix keeps MAME's own (single run) mix instead.

MAME runs isolated (scratch cfg / nvram / snapshot dirs, -noautosave): the user's own MAME setup is never touched.
The recordings are game audio: keep them local (bundled with release builds only).
"""
import os
import subprocess
import sys
import wave

import numpy as np

FPS = 60
BOOT = 900  # frames before the freeze: power-on jingle over, attract running (and muted)
GAP = 30    # silent frames between commands
# FM commands (music channel); the round BGMs (07 09 0a 12 30 31 3f) loop forever and come from the OST instead
FM = [0x06, 0x08, 0x0b, 0x0c, 0x0d, 0x0f, 0x10, 0x11, 0x13, 0x14, 0x15, 0x38]
PCM = [0x04, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x20, 0x21, 0x22, 0x24, 0x25, 0x26, 0x27, 0x28,
       0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x39]
WINDOW = {0x11: 24 * FPS, 0x13: 14 * FPS, 0x21: 20 * FPS, 0x38: 20 * FPS}  # frames; default FM 10 s, effects 4 s
LOCKED = 0x21
FREEZE_AT = 0xe7f0  # main RAM: a `jr $` written here; PC is parked on it every frame with interrupts off

LUA = r"""
local sched = {%s}
local last = %d
local freeze = %d
local force = {%s} -- [$cc00, $ce00, AY reg 14] -> forced byte (-1 = untouched)
local logpath = "%s"
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local snd = manager.machine.devices[":audiocpu"].spaces["program"]
local log = logpath ~= "" and io.open(logpath, "w") or nil
local function note(what, v)
  if log then log:write(string.format("%%.7f %%s %%d\n", manager.machine.time:as_double(), what, v)) end
end
local ayreg = 0
_G.fl_taps = {
  snd:install_write_tap(0xcc00, 0xcc00, "fl_cc", function(o, d, m) note("cc", d); if force[1] >= 0 then return force[1] end end),
  snd:install_write_tap(0xce00, 0xce00, "fl_ce", function(o, d, m) note("ce", d); if force[2] >= 0 then return force[2] end end),
  snd:install_write_tap(0xc800, 0xc801, "fl_ay", function(o, d, m)
    if o == 0xc800 then ayreg = d & 15; return end
    if ayreg == 14 then note("a", d); if force[3] >= 0 then return force[3] end end
    if ayreg == 15 then note("b", d) end
  end),
}
local frame = 0
local frozen = false
local function on_frame()
  frame = frame + 1
  if frame == freeze then
    mem:write_u8(%d, 0x18); mem:write_u8(%d, 0xfe)
    frozen = true
  end
  if frozen then
    cpu.state["IFF1"].value = 0
    cpu.state["IFF2"].value = 0
    cpu.state["PC"].value = %d
  end
  if frozen then mem:read_u8(0xd400) end -- drain the board's reply latch: after $14 it waits for the main CPU's read
  local cmds = sched[frame]
  if cmds then for _, c in ipairs(cmds) do mem:write_u8(0xd400, c) end end
  if frame >= last then if log then log:close() end; manager.machine:exit() end
end
if emu.add_machine_frame_notifier then
  _G.fl_sub = emu.add_machine_frame_notifier(on_frame)
else
  emu.register_frame_done(on_frame)
end
"""


def schedule(cmds):
    ev = {}  # frame -> [bytes]; written in order, one frame apart where the board needs time to take them
    marks = []
    f = BOOT + 10
    for c in cmds:
        ev.setdefault(f, []).append(0x00)
        ev.setdefault(f + 2, []).append(0xef)
        start = f + 4
        ev.setdefault(start, []).append(c)
        w = WINDOW.get(c, 10 * FPS if c in FM else 4 * FPS)
        end = start + w
        if c == LOCKED:
            ev.setdefault(end, []).append(0x01)
        ev.setdefault(end + 1, []).append(0x00)
        marks.append((c, start, end))
        f = end + GAP
    return ev, marks, f + 10


# --- TA7630 after Jotego's jt7630_*.v (48 kHz, the core's filter rate) ---
G0 = 10 ** (-35.625 / 20)  # MAME's ta7630 volume 0 (100% at 15, steps 1.5 dB + 0.125 dB each)
VOL = [1, 3, 9, 18, 36, 65, 102, 162, 229, 324, 417, 525, 645, 776, 901, 1023]  # / 1023
BAL = [(91, 513), (102, 457), (115, 407), (129, 363), (145, 324), (162, 288), (182, 257), (204, 229), (229, 204),
       (257, 182), (288, 162), (324, 145), (363, 129), (407, 115), (457, 102), (513, 91)]  # (group 1, group 2)
EQ = [1, 7, 9, 12, 15, 18, 23, 29, 36, 46, 58, 73, 92, 115, 145, 183]  # / 32: bass / treble gain


def iir1(u, a):
    """y[n] = a * y[n-1] + u[n], block-wise in numpy"""
    y = np.empty_like(u)
    prev = 0.0
    blk = 128
    k = np.arange(1, blk + 1)
    ak = a ** k
    inv = a ** -np.arange(blk)
    for i in range(0, len(u), blk):
        seg = u[i:i + blk]
        n = len(seg)
        y[i:i + n] = ak[:n] * prev / a * a + np.cumsum(seg * inv[:n]) * (a ** np.arange(n))
        prev = y[i + n - 1]
    return y


def diff1(x):
    return x - np.concatenate(([0.0], x[:-1]))


def dcrm(x):  # jtframe_dcrm: y = x - I/1024, I += y
    return iir1(diff1(x), 1 - 1 / 1024)


def pole(x, a):  # jtframe_pole: full = a*full + (1-a)*(x + x[-1]), out = full / 2
    return iir1((1 - a) * (x + np.concatenate(([0.0], x[:-1]))), a) / 2


def hipass(x, b, a):  # jtframe_hipass: y = b*(x - x[-1]) + a*y
    return iir1(b * diff1(x), a)


def equ(x, bass, treble):
    """jt7630_equ: (bass * lowpass0 + treble * hipass1 + hipass0 + lowpass1) / 2; bass / treble = per-sample settings"""
    d = dcrm(x)
    lo0 = pole(d, int(0.99836 * 16383) / 16384)
    lo1 = pole(d, int(0.98363 * 16383) / 16384)
    hi0 = hipass(d, 16357 / 16384, 16330 / 16384)
    hi1 = hipass(d, 14062 / 16384, 11741 / 16384)
    eq = np.array(EQ, float) / 32
    return (lo0 * eq[bass] + hi1 * eq[treble] + hi0 + lo1) / 2


def shelf(x, bass, treble, rate=48000, fb=100.0, ft=2500.0):
    """TA7630 tone as first-order shelves, 8 = flat, gain -16 + 2 * setting dB (Jotego's '0=-16dB, 15=14dB, 2dB step');
    corners: bass 100 Hz (his comment), treble 2.5 kHz (where his filters actually turn at 48 kHz)"""
    d = dcrm(x)
    wt = np.tan(np.pi * ft / rate)
    hp = hipass(d, 1 / (1 + wt), (1 - wt) / (1 + wt))
    lp = pole(d, 1 / (1 + 2 * np.pi * fb / rate))
    g = 10 ** ((-16 + 2 * np.arange(16)) / 20)
    return d + (g[treble] - 1) * hp + (g[bass] - 1) * lp


def steps(log, key, n, rate, default):
    """per-sample register value from the logged writes"""
    v = np.full(n, default, dtype=np.int64)
    for t, k, d in log:
        if k == key:
            i = int(round(t * rate))
            if i < n:
                v[i:] = d
    return v


def ta7630_mix(g1, g2, ay, z, log, rate, eq='shelf'):
    n = min(len(g1), len(g2), len(ay), len(z))
    g1, g2, ay, z = g1[:n], g2[:n], ay[:n], z[:n]
    s1 = (g1 - z) / (1 - G0)
    s2 = (g2 - z) / (1 - G0)
    sa = (ay - z) / (1 - G0)
    dac = z - G0 * (s1 + s2 + sa)
    # the chips' idle DC goes before the volume stage: the sound program changes volumes after a sound has ended, and a
    # volume step on DC is a click (Jotego's core removes DC only after the volume, so it would click too)
    s1, s2, sa = dcrm(s1), dcrm(s2), dcrm(sa)
    cc = steps(log, 'cc', n, rate, 0xf8)
    ce = steps(log, 'ce', n, rate, 0x88)
    pa = steps(log, 'a', n, rate, 0xf8)
    pb = steps(log, 'b', n, rate, 0x88)
    bal = np.array(BAL, float) / ((229 + 204) / 2)  # unity at the centre
    vol = np.array(VOL, float) / 1023
    msm = (s1 * bal[cc & 15, 0] + s2 * bal[cc & 15, 1]) * vol[cc >> 4]
    tone = {'jotego': equ, 'flat': lambda x, b, t: dcrm(x)}.get(eq, shelf)
    msm = tone(msm, ce & 15, ce >> 4)
    psg = tone(sa * vol[pa >> 4], pb & 15, pb >> 4)
    return msm + psg + dcrm(dac), (cc, ce, pa, pb)


def trim(x, rate):
    """(start, end) of the audible part: 10 ms blocks whose spread rises above the noise floor; None if silent"""
    b = rate // 100
    n = len(x) // b
    if n == 0:
        return None
    # above ~80 Hz (two high-pass poles: the board's volume steps leave subsonic thumps under the bass boost), then on
    # the sample-to-sample difference: a DC step is one spike there, a tone is not
    hb, ha = 1 / (1 + np.tan(np.pi * 80 / rate)), (1 - np.tan(np.pi * 80 / rate)) / (1 + np.tan(np.pi * 80 / rate))
    h = hipass(hipass(x[:n * b].astype(float), hb, ha), hb, ha)
    d = np.abs(np.diff(h, prepend=h[0])).reshape(n, b)
    sd = np.sort(d, axis=1)[:, b // 2:].mean(axis=1)  # the louder half of each block's steps (ignores lone spikes)
    loud = np.nonzero(sd > max(sd.max() * 0.02, 2))[0]
    if sd.max() < 4 or len(loud) == 0:
        return None
    # the end: stop at the first silence over 0.5 s unless what follows is a sound (>= 50 ms) rather than a lone pop
    # (the board resets a channel's registers well after its sound ended)
    groups = np.split(loud, np.nonzero(np.diff(loud) > 1)[0] + 1)
    end = groups[0][-1]
    for g in groups[1:]:
        if g[0] - end > 50 and len(g) < 5:
            break
        end = g[-1]
    return loud[0] * b, min(len(x), (end + 1) * b + rate // 4)


def clean(x, rate):
    y = x - np.median(x)
    f = min(len(y) // 2, rate // 500)
    if f:
        ramp = np.linspace(0, 1, f)
        y[:f] *= ramp
        y[-f:] *= ramp[::-1]
    return y


def rms(y, rate):
    b = rate // 100
    sd = y[:len(y) // b * b].reshape(-1, b).std(axis=1)
    sd = sd[sd > sd.max() * 0.1]
    return float(np.sqrt((sd ** 2).mean()))


def decode(path, rate):
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-f', 's16le', '-ac', '1', '-ar', str(rate), '-'],
                         check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.int16).astype(float)


def main():
    args = [a for a in sys.argv[1:]]
    scratch = os.path.abspath('mame_sfx_scratch')
    if '--scratch' in args:
        i = args.index('--scratch')
        scratch = os.path.abspath(args[i + 1])
        del args[i:i + 2]
    ref = None
    if '--ref' in args:
        i = args.index('--ref')
        ref = os.path.abspath(args[i + 1])
        del args[i:i + 2]
    keep = '--keep' in args
    mame_mix = '--mame-mix' in args
    eq = 'shelf'
    if '--eq' in args:
        i = args.index('--eq')
        eq = args[i + 1]
        del args[i:i + 2]
    reuse = '--reuse' in args  # re-mix the kept recordings (same command list) without running MAME
    keep = keep or reuse
    args = [a for a in args if a not in ('--keep', '--mame-mix', '--reuse')]
    if not args:
        sys.exit(__doc__)
    out = os.path.abspath(args[0])
    cmds = [int(a, 16) for a in args[1:]] or FM + PCM
    if 0x06 not in cmds:
        cmds = [0x06] + cmds  # the level reference
    for d in (out, scratch, f'{scratch}/cfg', f'{scratch}/nvram', f'{scratch}/snap'):
        os.makedirs(d, exist_ok=True)
    ev, marks, last = schedule(cmds)
    lua_sched = ', '.join(f'[{f}] = {{{", ".join(str(b) for b in bs)}}}' for f, bs in sorted(ev.items()))
    print(f'{len(cmds)} commands, {last / FPS:.0f} s of emulated time')

    def record(name, force, logpath=''):
        lua = f'{scratch}/sfx_{name}.lua'
        with open(lua, 'w') as fh:
            fh.write(LUA % (lua_sched, last, BOOT, ', '.join(str(v) for v in force), logpath, FREEZE_AT,
                            FREEZE_AT + 1, FREEZE_AT))
        wav = f'{scratch}/{name}.wav'
        if reuse and os.path.exists(wav) and (not logpath or os.path.exists(logpath)):
            with wave.open(wav) as w:
                r, ch = w.getframerate(), w.getnchannels()
                return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).reshape(-1, ch).mean(axis=1), r
        subprocess.run(['mame', 'flstory', '-noautosave', '-cfg_directory', f'{scratch}/cfg', '-nvram_directory',
                        f'{scratch}/nvram', '-snapshot_directory', f'{scratch}/snap', '-video', 'none', '-sound',
                        'none', '-nothrottle', '-skip_gameinfo', '-samplerate', '48000', '-wavwrite', wav,
                        '-script', lua], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with wave.open(wav) as w:
            r, ch = w.getframerate(), w.getnchannels()
            data = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).reshape(-1, ch).mean(axis=1)
        if not keep:
            os.remove(wav)
        return data, r

    regs = None
    if mame_mix:
        x, rate = record('all', (-1, -1, -1))
    else:
        logpath = f'{scratch}/regs.txt'
        g1, rate = record('g1', (0xf0, 0x00, 0x00), logpath)
        g2, _ = record('g2', (0x00, 0xf0, 0x00))
        ay, _ = record('ay', (0x00, 0x00, 0xf0))
        z, _ = record('z', (0x00, 0x00, 0x00))
        log = []
        for line in open(logpath):
            t, k, d = line.split()
            log.append((float(t), k, int(d)))
        x, regs = ta7630_mix(g1, g2, ay, z, log, rate, eq)
    spf = rate / FPS
    pieces = {}
    settings = {}
    for c, start, end in marks:
        # frame N's commands land at the end of frame N: the sound starts within the next frame
        seg = x[int(start * spf): int((end + 1) * spf)]
        span = trim(seg, rate)
        if span is None:
            print(f'${c:02x}: silent')
            continue
        pieces[c] = (clean(seg[span[0]:span[1]].copy(), rate), span[1] >= len(seg) - rate // 4)
        if regs:
            a, b = int(start * spf) + span[0], int(start * spf) + span[1]
            used = []
            for name, r in zip(('MSM vol/bal', 'MSM treble/bass', 'AY vol/bal', 'AY treble/bass'), regs):
                vals = sorted(set(int(v) for v in r[a:b]))
                used.append(f'{name} ' + ','.join(f'{v:02x}' for v in vals[:8]) + ('..' if len(vals) > 8 else ''))
            settings[c] = '; '.join(used)
    if ref and 0x06 in pieces:
        gain = rms(decode(ref, rate), rate) / rms(pieces[0x06][0], rate)
        how = f'matches $06 to {os.path.basename(ref)}'
    else:
        gain = 29205 / max(np.abs(p).max() for p, _ in pieces.values())
        how = 'loudest piece at -1 dBFS'
    print(f'gain x{gain:.2f} ({how})')
    for c, (piece, cut) in pieces.items():
        y = piece * gain
        over = np.abs(y).max() > 32767
        if over:  # this piece alone comes down to -0.1 dBFS (its level against the others is then lower than the board's)
            cut_db = 20 * np.log10(32400 / np.abs(y).max())
            y = y * 32400 / np.abs(y).max()
        with wave.open(f'{out}/{c:02x}.wav', 'wb') as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(rate)
            w.writeframes(np.clip(y, -32768, 32767).astype(np.int16).tobytes())
        notes = (' (still sounding at the window end)' if cut else '') + (f' (scaled {cut_db:.1f} dB: would clip)' if over else '')
        print(f'${c:02x}: {len(y) / rate:.2f} s{notes}' + (f'   [{settings[c]}]' if c in settings else ''))


if __name__ == '__main__':
    main()
