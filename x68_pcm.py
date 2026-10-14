#!/usr/bin/env python3
"""Decode the X68000 version's sound effects (PCMDATA.DAT, played by PCMDRV.R) to WAV files.

    python3 -I x68_pcm.py <PCMDATA.DAT> <out dir>

PCMDATA.DAT: 64 big-endian words = sample lengths in bytes, word i = sound command i + 1 (1 = unused placeholder);
zero padding to $200, then the samples back to back in that order (lengths sum exactly to the file size - $200).
PCMDRV.R plays one by array-chained DMA (channel 3) to the MSM6258 with PPI port C = $08: divider /512, both outputs on
-> 8 MHz / 512 = 15625 Hz (the jump, 1920 bytes = 0.246 s, matches the arcade's 0.245 s). OKI 4-bit ADPCM, low nibble
first, 12-bit output; the decoder starts from 0 / step 0 for each sample. Writes <out dir>/<cmd hex>.wav (16-bit mono,
15625 Hz, 12-bit value << 4: the native level, no normalisation).
The output is game audio: keep it local.
"""
import os
import struct
import sys
import wave

RATE = 15625
STEPS = [16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173,
         190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282,
         1411, 1552]
ADJ = [-1, -1, -1, -1, 2, 4, 6, 8]


def decode(data):
    out = []
    sig, idx = 0, 0
    for b in data:
        for n in (b & 15, b >> 4):
            step = STEPS[idx]
            diff = step >> 3
            if n & 1:
                diff += step >> 2
            if n & 2:
                diff += step >> 1
            if n & 4:
                diff += step
            sig = max(-2048, min(2047, sig - diff if n & 8 else sig + diff))
            idx = max(0, min(48, idx + ADJ[n & 7]))
            out.append(sig << 4)
    return out


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    d = open(sys.argv[1], 'rb').read()
    out = sys.argv[2]
    os.makedirs(out, exist_ok=True)
    lengths = struct.unpack('>64H', d[:128])
    if 0x200 + sum(lengths) != len(d):
        print(f'warning: lengths sum to {sum(lengths)}, file has {len(d) - 0x200} bytes of samples')
    pos = 0x200
    for i, n in enumerate(lengths):
        chunk = d[pos:pos + n]
        pos += n
        if n <= 1:
            continue
        pcm = decode(chunk)
        with wave.open(f'{out}/{i + 1:02x}.wav', 'wb') as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(struct.pack(f'<{len(pcm)}h', *pcm))
        peak = max(abs(v) for v in pcm)
        print(f'${i + 1:02x}: {len(pcm) / RATE:.3f} s, peak {20 * __import__("math").log10(max(peak, 1) / 32768):.1f} dBFS')


if __name__ == '__main__':
    main()
