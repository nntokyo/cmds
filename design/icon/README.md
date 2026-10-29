# cmds app icon

One identity for the macOS app (`cmds`) and the iOS/iPadOS companion (`CmdsCompanion`): a dark terminal pane
with a slim vertical tab strip, a `>_` prompt, a subtle split line and the warm-orange notification ring.

- Generated 2026-10-29 with ChatGPT image generation (the "Create image" tool, Plus plan), in one conversation.
- **Chosen: `candidates/candidate-2-ring-hero-pane.png`**, saved as `master-1024.png` (1024×1024, RGB, no alpha).
  It stays legible at 16–32 px: an orange frame with a white chevron. In the other candidates the
  prompt shrinks to a smudge next to a thin orange bar at those sizes.

## Files

| File | What |
|---|---|
| `candidates/candidate-1a-split-ring-edge.png` | First result. The elements touch the canvas edges, so the OS corner mask clips the ring and the top tab. Rejected. |
| `candidates/candidate-1b-split-ring-inset.png` | 1a moved inside the safe area: ring on the right pane, smaller `>_`. |
| `candidates/candidate-2-ring-hero-pane.png` | **Chosen.** One large pane, ring around the `>_`, horizontal split. |
| `candidates/candidate-3-ring-hero-glass.png` | Candidate 2 as raised smoked glass with a warmer, brighter ring. |
| `master-1024.png` | Chosen full-bleed artwork. Also the iOS icon as-is (iOS applies the rounded mask). |
| `macos-1024.png` | Generated: the master on Apple's macOS grid (824 px continuous-corner body, 100 px transparent margin, drop shadow). |
| `tools/compose_macos.py` | master → `macos-1024.png`. |
| `tools/build_icons.sh` | Regenerates `macos-1024.png`, every mac size (sips) in `App/Resources/Assets.xcassets/AppIcon.appiconset` and the iOS icon in `iOS/Resources/Assets.xcassets/AppIcon.appiconset`. |
| `tools/contact_sheet.py` | Legibility sheet: 256 px preview plus 64/32/16 px on dark and light backgrounds. |

Candidates are ChatGPT's raw 1254×1254 downloads.

## Swapping the icon

```sh
sips -z 1024 1024 design/icon/candidates/<candidate>.png --out design/icon/master-1024.png
sh design/icon/tools/build_icons.sh
python3 -I design/icon/tools/contact_sheet.py /tmp/cmds-icon-sheet.png \
  App/Resources/Assets.xcassets/AppIcon.appiconset design/icon/master-1024.png
```

New artwork must be a full-bleed square: no transparency, no rounded corners. Keep everything important at least
10% inside the edges, because the macOS and iOS masks cut off the corners. Requires python3 with Pillow.

## Prompts

Candidate 1a:

> Square app icon artwork, 1:1, 1024x1024 px, for a native macOS terminal-workspace app for AI coding agents.
> FULL-BLEED: a deep graphite / near-black panel surface (#15171B to #23262C, subtle vertical gradient) fills the
> entire square edge to edge, reaching all four edges and all four sharp corners. No rounded corners, no outer frame
> or bezel, no drop shadow, no device, no white or transparent margin: the operating system applies its own rounded
> mask later, so keep every important element inside the central 80% of the canvas. The square reads as a dark
> terminal workspace seen straight-on. Left side: a thin vertical tab strip in slightly lighter charcoal with three
> small rounded pill-shaped tabs stacked vertically, the top one softly highlighted. The remaining area is split into
> two panes by one thin, subtle vertical divider line. The larger left pane holds a big, bold, soft-white terminal
> prompt glyph '>_' (a chevron plus an underscore cursor) with thick strokes in a clean heavy monospace style. The
> right pane's rounded border glows with a warm orange (#FF8A3D) luminous ring: a soft neon glow outlining that pane,
> the app's signature 'notification ring'. Style: calm, premium, native Apple macOS icon aesthetic; mostly flat with
> very subtle depth, soft gradients and gentle inner lighting; crisp vector-clean edges; few, bold shapes with high
> contrast so it still reads at 16x16 px. No text, letters, numbers, logos or watermark anywhere except the '>_' glyph.

Candidate 1b (follow-up): "…a revised version of this exact design … pull every element inward so the operating
system's rounded-corner mask will not clip anything: … at least 10% of the canvas width away from every edge … Make
the ring a bit thicker and brighter so it survives at 16x16 px …". The first attempt drew `>*`, so a second follow-up
asked for "a bold right-pointing chevron followed by a short, thick horizontal bar sitting on the baseline".
In follow-ups, describe the glyph in words: ChatGPT renders `_` as Markdown, which garbled the glyph.

Candidate 2 (follow-up): "…a second, clearly different candidate … ONE large rounded-rectangle terminal pane
(slightly lighter than the background) filling most of the safe area, outlined by a thick, bright, glowing
warm-orange (#FF8A3D) notification ring. Inside that pane sits a very large, bold, soft-white terminal prompt glyph:
a right-pointing chevron followed by a short thick horizontal bar on the baseline, together about 55% of the pane
width. Along the left inside edge of the pane runs a slim vertical tab strip with three small rounded pills (the top
one orange). A single thin, subtle horizontal split line crosses the lower quarter of the pane … every element stays
at least 10% of the width away from all edges."

Candidate 3 (follow-up): "…keep this exact composition … but render it in a more dimensional, premium Apple macOS
Big Sur style: … a slightly raised slab of dark smoked glass with a soft top highlight and a gentle inner shadow …
the ring keeps its thickness but becomes a warmer, more luminous light (#FF8A3D blending to #FFB36B) …".

The `candidates/` PNGs (~6 MB) are kept out of git (`.gitignore`); they live only in the local checkout.
