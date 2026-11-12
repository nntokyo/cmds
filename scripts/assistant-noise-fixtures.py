#!/usr/bin/env python3
"""Noisy test audio for the voice assistant (#270), made on this Mac: no recordings of people, no downloads.

Speech is synthesised with `say` (Kyoko for Japanese, Samantha for English) and mixed with generated noise at a given
signal-to-noise ratio:

  pink     steady hiss (a fan, traffic far away), 1/f
  babble   several `say` voices talking at once about other things (a café, a station)
  clatter  dishes and steps: short bursts and clinks over a low rumble

Each file is `<lang>-<phrase>-<noise>-<snr>.wav` (16 kHz mono): 1.5 s of noise, the speech, then `--after` seconds of
the same noise (the noise does not stop when the user does). `quiet` is the speech over faint hiss (-60 dB). A
`manifest.json` lists each file with the expected transcript and where the speech ends (seconds), for feeding them
through `debug.assistant` `hear_audio` (docs/internals/testing.md).

Usage: scripts/assistant-noise-fixtures.py OUT_DIR [--lang ja|en] [--snr 20,10,5,0] [--noise pink,babble,clatter]
Needs only Python 3 and macOS (`say`, `afconvert`).
"""
import argparse
import array
import json
import math
import os
import random
import subprocess
import tempfile
import wave

RATE = 16000
LEAD = 1.5  # seconds of noise before the speech
SPEECH_RMS = 0.05  # a voice at arm's length from a laptop microphone
QUIET_LEVEL = 0.001  # `quiet`: the hiss 60 dB below the speech
ACTIVE_FLOOR = 0.03  # `active_rms`: frames within 30 dB of the loudest

PHRASES = {
    "ja": ["ジャービス、状況は？", "ジャービス、APIのエージェントにテストを書くように指示して"],
    "en": ["Jarvis, what's the status?", "Jarvis, tell the API agent to fix the failing test."],
}
VOICE = {"ja": "Kyoko", "en": "Samantha"}
# Other talk for babble: never the assistant's name.
BABBLE = [
    ("Kyoko", 170, "今日は本当にいい天気ですね。駅前に新しいカフェができたので、週末に友達と行ってみようと思っています。"),
    ("Kyoko", 230, "次の電車は何分に来ますか。乗り換えの改札はあちらの階段を上がって右側です。"),
    ("Samantha", 190, "I think the meeting moved to Thursday, so we should probably book the room again."),
    ("Daniel", 210, "Could I get a flat white and a croissant please, and a glass of water as well."),
    ("Karen", 180, "The train to the airport leaves from platform four, but it's running a few minutes late."),
    ("Fred", 160, "We were talking about the new restaurant downtown, the one with the long queue every evening."),
]


def say(text, voice, rate=None):
    """`say` into 16 kHz mono samples (floats, -1…1)."""
    with tempfile.TemporaryDirectory() as tmp:
        aiff, wav = os.path.join(tmp, "s.aiff"), os.path.join(tmp, "s.wav")
        cmd = ["say", "-v", voice, "-o", aiff] + (["-r", str(rate)] if rate else []) + [text]
        subprocess.run(cmd, check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1", aiff, wav], check=True,
                       stdout=subprocess.DEVNULL)
        with wave.open(wav) as f:
            data = array.array("h", f.readframes(f.getnframes()))
    return [x / 32768 for x in data]


def rms(samples):
    return math.sqrt(sum(x * x for x in samples) / max(1, len(samples)))


def active_rms(samples, frame=RATE // 50):
    """RMS of the 20 ms frames with speech in them (within 30 dB of the loudest), so pauses do not lower it."""
    frames = [samples[i:i + frame] for i in range(0, len(samples) - frame, frame)]
    levels = [rms(f) for f in frames]
    top = max(levels)
    loud = [f for f, level in zip(frames, levels) if level > top * ACTIVE_FLOOR]
    return rms([x for f in loud for x in f])


def scaled(samples, target):
    gain = target / max(1e-9, rms(samples))
    return [x * gain for x in samples]


def pink(n, rng):
    """Voss-McCartney pink noise."""
    rows = [rng.uniform(-1, 1) for _ in range(12)]
    out = []
    for i in range(n):
        k = (i & -i).bit_length() - 1 if i else 0
        if k < len(rows):
            rows[k] = rng.uniform(-1, 1)
        out.append(sum(rows) + rng.uniform(-1, 1))
    return out


def brown(n, rng):
    out, value = [], 0.0
    for _ in range(n):
        value = 0.995 * value + rng.uniform(-1, 1) * 0.1
        out.append(value)
    return out


_babble_voices = []


def babble(n, rng):
    """Several voices at once, each looped from a random offset (the voices are synthesised once)."""
    if not _babble_voices:
        _babble_voices.extend(scaled(say(text, voice, rate), 1) for voice, rate, text in BABBLE)
    out = [0.0] * n
    for voice in _babble_voices:
        offset = rng.randrange(len(voice))
        for i in range(n):
            out[i] += voice[(offset + i) % len(voice)]
    return out


def clatter(n, rng):
    """A low rumble with bursts (steps, a chair) and clinks (cups) every 0.2–1.2 s."""
    out = [x * 0.3 for x in scaled(brown(n, rng), 1)]
    at = rng.uniform(0, 0.5)
    while True:
        start = int(at * RATE)
        if start >= n:
            break
        amplitude = rng.uniform(0.5, 3)
        if rng.random() < 0.5:  # a clink
            freq, decay = rng.uniform(1800, 4500), rng.uniform(0.04, 0.12)
            for i in range(min(n - start, int(decay * 5 * RATE))):
                t = i / RATE
                out[start + i] += amplitude * math.sin(2 * math.pi * freq * t) * math.exp(-t / decay)
        else:  # a knock
            decay = rng.uniform(0.01, 0.04)
            for i in range(min(n - start, int(decay * 5 * RATE))):
                t = i / RATE
                out[start + i] += amplitude * rng.uniform(-1, 1) * math.exp(-t / decay)
        at += rng.uniform(0.2, 1.2)
    return out


NOISES = {"pink": pink, "babble": babble, "clatter": clatter}


def write(path, samples):
    peak = max(1.0, max(abs(x) for x in samples))
    data = array.array("h", (int(max(-1, min(1, x / peak)) * 32767) for x in samples))
    with wave.open(path, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(data.tobytes())


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("out")
    parser.add_argument("--lang", default="ja", choices=sorted(PHRASES))
    parser.add_argument("--snr", default="20,10,5,0")
    parser.add_argument("--noise", default="pink,babble,clatter")
    parser.add_argument("--after", type=float, default=10)
    parser.add_argument("--seed", type=int, default=270)
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    rng = random.Random(args.seed)
    manifest = []
    for index, phrase in enumerate(PHRASES[args.lang]):
        speech = say(phrase, VOICE[args.lang])
        gain = SPEECH_RMS / active_rms(speech)
        speech = [x * gain for x in speech]
        lead, after = int(LEAD * RATE), int(args.after * RATE)
        total = lead + len(speech) + after
        cases = [("quiet", None)] + [(noise, int(snr)) for noise in args.noise.split(",") for snr in args.snr.split(",")]
        for noise, snr in cases:
            kind = "pink" if noise == "quiet" else noise
            level = SPEECH_RMS * (QUIET_LEVEL if snr is None else 10 ** (-snr / 20))
            background = scaled(NOISES[kind](total, rng), level)
            mixed = background[:]
            for i, x in enumerate(speech):
                mixed[lead + i] += x
            name = f"{args.lang}-{index + 1}-{noise}" + ("" if snr is None else f"-{snr}") + ".wav"
            write(os.path.join(args.out, name), mixed)
            manifest.append({"file": name, "text": phrase, "noise": noise, "snr": snr,
                             "speechStart": LEAD, "speechEnd": LEAD + len(speech) / RATE})
            print(name)
    write_manifest(os.path.join(args.out, "manifest.json"), manifest)


def write_manifest(path, manifest):
    """`manifest` into `path`, replacing the entries of the same files and keeping the others (another language)."""
    old = []
    if os.path.exists(path):
        with open(path) as f:
            old = json.load(f)
    names = {entry["file"] for entry in manifest}
    with open(path, "w") as f:
        json.dump([e for e in old if e["file"] not in names] + manifest, f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
