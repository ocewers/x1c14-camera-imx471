#!/usr/bin/env python3
"""Measure the imx471's RAW channel ratios from a Bayer file captured with
`cam --stream role=raw`. Used to identify which camera module is fitted, by comparing the
sensor's raw white point against the per-module white points in Intel's factory AIQB
calibration blobs (they differ by ~8% between modules). Independent of libcamera's AWB,
CCM and gamma. Comments below are in Swedish; see README "Factory calibration".

Mäter imx471:ans RÅA kanalförhållanden ur en Bayer-fil från `cam --stream role=raw`.

Syfte: fastställa vilken kameramodul som sitter i maskinen. Intels fabriksblobbar
(AIQB) innehåller per-modul vitpunkter (r_per_g, b_per_g) per ljuskälla, och de skiljer
~8 % mellan moduler. Sensorns råa R/G och B/G på ett neutralt mål är samma storhet, och
är oberoende av libcameras AWB, CCM och gamma.

Format: SRGGB10 i 16-bitars ord (little endian), dvs mönstret
    rad 0:  R G R G ...
    rad 1:  G B G B ...

Användning:
    raw-whitepoint.py <fil.bin> [--width 1928] [--height 1088] [--stride 3904]
                      [--crop-frac 0.34] [--black R,Gr,Gb,B]

  --black tas från en mörkbildsmätning (stängd integritetslucka); utan den rapporteras
  råa medelvärden OCH en varning, eftersom en pedestal på ~64 LSB drar kvoterna mot 1.
"""
import argparse
import sys
from array import array

CLIP = 1000               # 10-bitars sensor: allt häröver behandlas som mättat


def channel_means(path, width, height, stride, crop_frac):
    with open(path, 'rb') as f:
        data = f.read()
    need = stride * height
    if len(data) < need:
        sys.exit(f"{path}: {len(data)} byte, väntade minst {need}")

    # centrerad kvadratisk utsnitt: crop_frac av bredden/höjden
    cw = int(width * crop_frac) & ~1
    ch = int(height * crop_frac) & ~1
    x0 = ((width - cw) // 2) & ~1
    y0 = ((height - ch) // 2) & ~1

    sums = [0, 0, 0, 0]      # R, Gr (rad med R), Gb (rad med B), B
    counts = [0, 0, 0, 0]
    tsums = [0, 0, 0, 0]     # samma, men utan mättade sampel
    tcounts = [0, 0, 0, 0]
    clip_counts = [0, 0, 0, 0]
    peak = 0

    for y in range(y0, y0 + ch):
        row = array('H')
        row.frombytes(data[y * stride + x0 * 2: y * stride + (x0 + cw) * 2])
        even = row[0::2]
        odd = row[1::2]
        if (y - y0) % 2 == 0:            # R G R G
            a, b = 0, 1                  # even -> R, odd -> Gr
        else:                            # G B G B
            a, b = 2, 3                  # even -> Gb, odd -> B
        for idx, samples in ((a, even), (b, odd)):
            sums[idx] += sum(samples)
            counts[idx] += len(samples)
            # trimmat: uteslut mättade sampel, och räkna hur många de är
            clipped = sum(1 for v in samples if v >= CLIP)
            clip_counts[idx] += clipped
            if clipped:
                tsums[idx] += sum(v for v in samples if v < CLIP)
                tcounts[idx] += len(samples) - clipped
            else:
                tsums[idx] += sums[idx] - (sums[idx] - sum(samples))
                tcounts[idx] += len(samples)
        m = max(max(even), max(odd))
        if m > peak:
            peak = m

    means = [s / c for s, c in zip(sums, counts)]
    tmeans = [(t / c if c else 0.0) for t, c in zip(tsums, tcounts)]
    clip_frac = [(cc / c if c else 0.0) for cc, c in zip(clip_counts, counts)]
    return means, peak, (cw, ch), tmeans, clip_frac


def grid_scan(path, width, height, stride, black):
    """Provar 16 delytor och returnerar de oklippta, sorterade på signalstyrka.

    Motiv: lampan ger en hotspot på målet, så det centrerade utsnittet kan klippa i grönt
    även när bildens medelvärde ligger på halva skalan. En delyta utan mättade sampel ger
    en ren kvot utan att man behöver ändra ljuset.
    """
    win_w, win_h = 380, 260
    out = []
    for gy in range(4):
        for gx in range(4):
            x0 = (int((width - win_w) * gx / 3)) & ~1
            y0 = (int((height - win_h) * gy / 3)) & ~1
            means, peak, clip_frac = window_means(path, x0, y0, win_w, win_h, stride)
            r, gr, gb, b = (m - k for m, k in zip(means, black))
            g = (gr + gb) / 2
            if g <= 0:
                continue
            out.append({'pos': (x0, y0), 'peak': peak, 'g': g,
                        'rg': r / g, 'bg': b / g, 'clip': max(clip_frac)})
    clean = [o for o in out if o['clip'] == 0 and 150 < o['g'] < 850]
    clean.sort(key=lambda o: -o['g'])
    return clean, out


def window_means(path, x0, y0, w, h, stride):
    with open(path, 'rb') as f:
        data = f.read()
    sums = [0, 0, 0, 0]; counts = [0, 0, 0, 0]; clips = [0, 0, 0, 0]; peak = 0
    for y in range(y0, y0 + h):
        row = array('H')
        row.frombytes(data[y * stride + x0 * 2: y * stride + (x0 + w) * 2])
        even, odd = row[0::2], row[1::2]
        a, b = (0, 1) if (y - y0) % 2 == 0 else (2, 3)
        for idx, samples in ((a, even), (b, odd)):
            sums[idx] += sum(samples); counts[idx] += len(samples)
            clips[idx] += sum(1 for v in samples if v >= CLIP)
        m = max(max(even), max(odd))
        peak = m if m > peak else peak
    means = [s / c for s, c in zip(sums, counts)]
    return means, peak, [c / n for c, n in zip(clips, counts)]


def main():
    p = argparse.ArgumentParser()
    p.add_argument('files', nargs='+')
    p.add_argument('--width', type=int, default=1928)
    p.add_argument('--height', type=int, default=1088)
    p.add_argument('--stride', type=int, default=3904)
    p.add_argument('--crop-frac', type=float, default=0.34)
    p.add_argument('--black', default=None, help='R,Gr,Gb,B i LSB (10-bitarsdomän)')
    p.add_argument('--window', default=None,
                   help='exakt mätfönster x0,y0,w,h - använd SAMMA för alla mätpunkter, '
                        'eftersom färgberoende lens shading gör kvoten platsberoende '
                        '(uppmätt ~5%% spridning mellan delytor i samma bild)')
    p.add_argument('--grid', action='store_true',
                   help='sök av ett 4x4-raster av delytor och rapportera den bästa '
                        'oklippta (hotspots gör mittutsnittet oanvändbart)')
    args = p.parse_args()

    black = [0.0] * 4
    if args.black:
        black = [float(v) for v in args.black.split(',')]
        if len(black) != 4:
            sys.exit("--black vill ha fyra värden: R,Gr,Gb,B")

    if args.grid:
        for path in args.files:
            clean, allw = grid_scan(path, args.width, args.height, args.stride, black)
            print(f"{path}  ({len(clean)}/{len(allw)} delytor oklippta)")
            for o in clean[:4]:
                print(f"  delyta @{o['pos'][0]:4d},{o['pos'][1]:4d}  G={o['g']:6.1f}"
                      f"  topp={o['peak']:4d}  R/G={o['rg']:.4f}  B/G={o['bg']:.4f}")
            if not clean:
                print("  ingen oklippt delyta - sänk ljuset")
            print()
        return

    if args.window:
        x0, y0, w, h = (int(v) for v in args.window.split(','))
        for path in args.files:
            means, peak, clip = window_means(path, x0, y0, w, h, args.stride)
            r, gr, gb, b = (m - k for m, k in zip(means, black))
            g = (gr + gb) / 2
            print(f"{path}")
            print(f"  fönster {w}x{h} @{x0},{y0}   G={g:.1f}  topp={peak}"
                  f"  klippt max={max(clip) * 100:.3f}%")
            if max(clip) > 0:
                print("  ⚠ KLIPPNING i fönstret - sänk ljuset, kvoten är inte giltig")
            print(f"  R/G={r / g:.4f}  B/G={b / g:.4f}  (Gr/Gb={gr / gb:.4f})")
            print()
        return

    for path in args.files:
        means, peak, crop, tmeans, clip_frac = channel_means(
            path, args.width, args.height, args.stride, args.crop_frac)
        r, gr, gb, b = (m - k for m, k in zip(means, black))
        g = (gr + gb) / 2
        print(f"{path}")
        print(f"  utsnitt {crop[0]}x{crop[1]} px   topp {peak} LSB"
              + ("  ⚠ NÄRA MÄTTNAD (>1000), kvoterna dras mot 1" if peak > 1000 else ""))
        print(f"  rå medel  R={means[0]:7.2f} Gr={means[1]:7.2f} "
              f"Gb={means[2]:7.2f} B={means[3]:7.2f}")
        if args.black:
            print(f"  minus svartnivå  R={r:7.2f} G={g:7.2f} B={b:7.2f}")
        else:
            print("  ⚠ ingen svartnivå angiven - mät med stängd integritetslucka och ange --black")
        if g > 0:
            print(f"  R/G={r / g:.4f}  B/G={b / g:.4f}   (Gr/Gb={gr / gb:.4f}, ska vara ~1)")
        print("  klippt andel  " + "  ".join(
            f"{n}={f * 100:.3f}%" for n, f in zip(('R', 'Gr', 'Gb', 'B'), clip_frac)))
        tr, tgr, tgb, tb = (m - k for m, k in zip(tmeans, black))
        tg = (tgr + tgb) / 2
        if tg > 0 and any(clip_frac):
            print(f"  trimmat (mättade uteslutna)  R/G={tr / tg:.4f}  B/G={tb / tg:.4f}")
        print()


if __name__ == '__main__':
    main()
