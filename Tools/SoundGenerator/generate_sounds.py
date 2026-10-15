#!/usr/bin/env python3
"""Generates the short feedback sounds played when a word is corrected.

Writes 16-bit mono WAV files to RightLayout/Sources/Resources/Sounds/.
Only the standard library is used, and the noise generator is seeded, so the
output is the same on every run.

    python3 Tools/SoundGenerator/generate_sounds.py
"""

import math
import random
import struct
import wave
from pathlib import Path

RATE = 48_000
PEAK = 0.30  # well below full scale: these are meant to be quiet
OUT_DIR = Path(__file__).resolve().parents[2] / "RightLayout" / "Sources" / "Resources" / "Sounds"


def envelope(t, attack, decay):
    """Short linear attack (avoids a click at the start), then exponential decay."""
    if t < attack:
        return t / attack
    return math.exp(-(t - attack) / decay)


def render(duration, sample):
    return [sample(i / RATE) for i in range(int(duration * RATE))]


def tick():
    """A crisp, very short click: a high partial plus a touch of filtered noise."""
    rng = random.Random(1)
    state = 0.0

    def sample(t):
        nonlocal state
        # One-pole high-pass on white noise keeps only the "tsk".
        noise = rng.uniform(-1.0, 1.0)
        filtered = noise - state
        state = noise * 0.6 + state * 0.4
        tone = math.sin(2 * math.pi * 3200 * t)
        return envelope(t, 0.0008, 0.006) * (0.7 * tone + 0.3 * filtered)

    return render(0.035, sample)


def pop():
    """A soft round pop: a sine whose pitch drops quickly."""
    phase = 0.0

    def sample(t):
        nonlocal phase
        freq = 520 + 480 * math.exp(-t / 0.012)
        phase += 2 * math.pi * freq / RATE
        return envelope(t, 0.002, 0.018) * math.sin(phase)

    return render(0.07, sample)


def tap():
    """A wooden tap: two inharmonic partials with a fast decay."""

    def sample(t):
        body = math.sin(2 * math.pi * 1850 * t)
        knock = 0.45 * math.sin(2 * math.pi * 2960 * t) * math.exp(-t / 0.006)
        return envelope(t, 0.0006, 0.014) * (body + knock) / 1.45

    return render(0.06, sample)


def glass():
    """A tiny glassy ding: a high note with an octave, ringing a little longer."""

    def sample(t):
        tone = math.sin(2 * math.pi * 2640 * t) + 0.35 * math.sin(2 * math.pi * 5280 * t)
        return envelope(t, 0.002, 0.045) * tone / 1.35

    return render(0.16, sample)


def blip():
    """Two quick rising notes: "switched"."""
    first, second = 1320, 1760
    note = 0.032

    def sample(t):
        if t < note:
            return envelope(t, 0.001, 0.010) * math.sin(2 * math.pi * first * t)
        t2 = t - note
        return envelope(t2, 0.001, 0.014) * math.sin(2 * math.pi * second * t2)

    return render(note * 2 + 0.03, sample)


SOUNDS = {
    "tick": tick,
    "pop": pop,
    "tap": tap,
    "glass": glass,
    "blip": blip,
}


def write(name, samples):
    peak = max(abs(s) for s in samples) or 1.0
    # Fade the last 2 ms to zero so nothing clicks at the end.
    fade = int(0.002 * RATE)
    for i in range(fade):
        samples[-1 - i] *= i / fade
    frames = b"".join(struct.pack("<h", int(round(s / peak * PEAK * 32767))) for s in samples)
    path = OUT_DIR / f"correction_{name}.wav"
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(frames)
    print(f"{path.relative_to(OUT_DIR.parents[3])}: {len(samples) / RATE * 1000:.0f} ms")


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for name, make in SOUNDS.items():
        write(name, make())


if __name__ == "__main__":
    main()
