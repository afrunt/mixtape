# mixtape.sh

Scan a music album and figure out which tracks record onto each side of one
or more audio cassette tapes — without ever splitting a track across a side
— then convert every track to lossless WAV, write per-side `.m3u`
playlists, and produce a `mixtape.txt` report describing the full layout.

## What it does

Given an album directory of `mp3`, `wav`, or `flac` (+ `.cue`) files:

1. Reads each track's Track Number, title, and duration from metadata.
2. Sorts tracks by Track Number (or alphabetically by filename, if no track
   in the album has one — see below) and packs them onto cassette sides
   (A/B) across one or more tapes, in order, never splitting a track across
   a side boundary. If a track doesn't fit on the current side, it (and
   everything after it) rolls forward to the next side.
3. Converts every track to a lossless PCM WAV file, optionally normalizing
   its volume level to a consistent peak (`--normalize`, see below).
4. Writes one Extended `.m3u` playlist per non-empty tape side, with each
   entry's `#EXTINF` line showing `Artist - Title` when artist metadata is
   available (falling back to the title alone otherwise).
5. Writes a `mixtape.txt` report showing each tape's sides, durations, and
   track listing.
6. Copies each album's cover art image (if any is found — see below) into
   `--dest` as `cover-NN.<ext>`.

## Running with Docker (recommended)

**The recommended way to run `mixtape.sh` is via the Docker image**, rather
than running the script natively. The image bundles `mixtape.sh` together
with `ffmpeg`/`ffprobe`, so nothing needs to be installed on the host
besides Docker itself — no need to worry about `bash` version, `ffmpeg`
availability, or any other host dependency described below. It also works
identically on Linux, macOS, and Windows (via Docker Desktop/WSL2), so
there's no platform-specific setup at all.

Because the image is built directly from this repository's `Dockerfile`
and `mixtape.sh`, it always reflects whatever is the newest version of the
script — rebuilding the image (or pulling a freshly published one) picks
up every fix and feature automatically, without you needing to track or
copy the script file yourself.

### Run the image

Mount the album directory (read-only) and an output directory, then pass
the same flags as the native script — `--path`/`--dest` refer to paths
*inside the container*, so point them at the mount targets:

```sh
docker run --rm -it \
  -v "$(pwd)/albums/my-album:/album:ro" \
  -v "$(pwd)/out:/out" \
  afrunt/mixtape --path /album --dest /out --length 90
```

Running the image with no arguments (or `--help`) prints usage:

```sh
docker run --rm -it afrunt/mixtape --help
```

Converted WAV files, `.m3u` playlists, and `mixtape.txt` will appear on the
host under `./out` after the container exits.

More examples, mounting multiple albums and combining several flags at
once:

```sh
# Two albums, custom tape length, each album kept on its own side
docker run --rm -it \
  -v "$(pwd)/albums/album-one:/albums/album-one:ro" \
  -v "$(pwd)/albums/album-two:/albums/album-two:ro" \
  -v "$(pwd)/out:/out" \
  afrunt/mixtape \
  --path /albums/album-one --path /albums/album-two \
  --dest /out --length 90 --fit-to-side

# Quick dry run to check the layout only, no conversion
docker run --rm -it \
  -v "$(pwd)/albums/my-album:/album:ro" \
  -v "$(pwd)/out:/out" \
  afrunt/mixtape --path /album --dest /out --length 90,90 --dry-run

# Normalize volume across albums
docker run --rm -it \
  -v "$(pwd)/albums/album-one:/albums/album-one:ro" \
  -v "$(pwd)/albums/album-two:/albums/album-two:ro" \
  -v "$(pwd)/out:/out" \
  afrunt/mixtape \
  --path /albums/album-one --path /albums/album-two \
  --dest /out --normalize
```

### Build the image (optional)

Most users don't need this — pull or reuse the image as-is. Build it
yourself only if you want to modify `mixtape.sh` (or the `Dockerfile`) or
want to dig into how the image is put together:

```sh
docker build -t afrunt/mixtape .
```

If you'd rather run the script natively instead of via Docker, see
[Requirements](#requirements) and [Usage](#usage) below.

## Supported album layouts

| Layout | Detection rule | Metadata source |
|--------|------------------------------------------|------------------|
| mp3     | One or more `.mp3` files in the directory | `ffprobe` tags (`title`, `track`) per file |
| wav     | One or more `.wav` files (checked if no mp3/flac match) | `ffprobe` tags (`title`, `track`) per file |
| flac+cue | Exactly one `.flac` file plus a companion `.cue` sheet | Parsed from the `.cue` sheet (`TRACK`, `TITLE`, `INDEX 01`) |

Format detection priority is flac+cue > wav > mp3. If `.flac` files exist
but don't match the exact "one file + one cue sheet" layout, the script
reports a specific error instead of silently falling through to another
format.

For mp3/wav albums, if none of the tracks carry a Track Number tag, the
script falls back to ordering them alphabetically by filename instead of
failing. If only *some* tracks in the album have a Track Number, that is
still an error — add the tag to every track, or remove it from every track.
(flac+cue albums always have a Track Number for every track, since it comes
from the cue sheet's structure, not a per-file tag, so this fallback never
applies to them.) Duplicate Track Numbers are rejected.

## Requirements

* `ffmpeg` and `ffprobe` available on `PATH` (checked at startup).
* `bash` (the script is written to also run under bash 3.2, e.g. the
  default `/bin/bash` on macOS).

No other external tools are required.

## Usage

```sh
mixtape.sh --path <album-dir> [--path <album-dir> ...] [--length <list>] [--dest <dir>] [--normalize] [--fit-to-side]
mixtape.sh --help
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--path <dir>` | *(required)* | Path to an existing directory containing an mp3, wav, or flac album. May be given more than once to record several albums onto the same set of tapes, one after another in the order given. |
| `--length <list>` | `90` | Comma-separated cassette tape lengths in minutes, one entry per tape, in order. For example `90` (one 90-minute tape) or `90,60,60` (a 90-minute tape followed by two 60-minute tapes). Each value must be one of `46, 60, 90, 100, 110, 120, 130`. |
| `--dest <dir>` | `./mixtape` | Output directory for `mixtape.txt`, the converted WAV files, and the `.m3u` playlists. Created automatically if it doesn't exist. **If it already exists, its contents are removed first**, so the directory always reflects only the current run's output. |
| `--include-artist-name` | off | When present, prefix each track line in `mixtape.txt` with the track's artist, formatted as `Artist - Title`. If a track has no artist metadata, the title is shown alone even when this flag is set. |
| `--dry-run` | off | When present, only compute and write `mixtape.txt`; WAV conversion, `.m3u` playlist writing, and cover art copying are all skipped. Useful for quickly checking the tape/side layout without spending time on audio conversion. |
| `--normalize` | off | When present, normalize every converted WAV track's volume using the same algorithm as Audacity's Normalize effect with its default settings — see [Volume normalization](#volume-normalization). |
| `--fit-to-side` | off | When present with more than one `--path` album, each album always starts on its own fresh tape side — see [Fitting each album onto its own side](#fitting-each-album-onto-its-own-side). |
| `--help`, `-h` | | Print help and exit. |

### Destination directory handling

`--dest` is always cleared and freshly (re)created before anything is
written: if it already exists, its existing contents are removed first,
so leftover files from a previous run never mix with the current run's
output. For safety, the script refuses to use `--dest` values of `` (empty),
`/`, `.`, or `..`, since clearing those would be catastrophic. If `--dest`
is a bind-mounted directory (e.g. a Docker volume), only its *contents* are
removed — the mount point itself is left in place, since it usually cannot
be removed and recreated.

### Multiple albums

Pass `--path` more than once to record several albums back to back onto the
same tapes, in the order the flags are given. Each album's own Track Number
sequence is validated independently (duplicate Track Numbers are only an
error within a single album), and the combined track list is packed across
the requested `--length` tapes exactly like a single album's tracks. Track
lines in `mixtape.txt` are numbered by their position in this combined
sequence (strictly increasing, e.g. `01`...`30` across two 15-track albums)
rather than each album's own Track Number, so the report always stays in
correct numeric order. If the combined duration of all given albums does
not fit the requested tape capacity, the script fails with a clear error
before writing any output.

```sh
./mixtape.sh --path albums/album-one --path albums/album-two --length 90,90
```

If `--length` names more tapes than are needed to hold all the tracks, the
extra, fully-unused trailing tapes are simply left out of `mixtape.txt` —
only tapes that actually have at least one track on either side are listed.
A tape that is only partially filled (one side used, the other empty) is
still shown in full, as before.

### Fitting each album onto its own side

By default, when packing multiple albums, a tape side may end up holding
the tail of one album followed by the head of the next, if both fit.
`--fit-to-side` changes this: with more than one `--path` album, each album
always starts on a fresh tape side, even if the previous side still has
unused room left. An album that is itself longer than one side still
spans multiple sides as usual — only *different* albums are kept off the
same side.

```sh
./mixtape.sh --path albums/album-one --path albums/album-two --length 90 --fit-to-side
```

If the given `--length` list doesn't leave enough sides to keep every
album separate this way, the script prints a warning explaining that and
falls back to the normal packing mode (sides may be shared between
albums) instead of failing outright:

```
[mixtape] Warning: --fit-to-side could not place every album onto its own
tape side with the current --length (2 albums across 1 tape(s)); falling
back to normal packing, where a tape side may contain tracks from more
than one album. Recommendation: add another tape, choose a longer --length
value, or reorder --path so consecutive albums' durations pair up more
evenly per side.
```

With a single `--path` album, `--fit-to-side` has no effect (there is only
one album, so there is nothing to keep off another album's side).

### Cover art

If an album directory contains a cover image, it is copied into `--dest` as
`cover-NN.<ext>`, where `NN` is that album's 1-based position among the
`--path` arguments given (padded to at least 2 digits) and `<ext>` is the
original image's extension. An album's cover image is chosen like this,
in order:

1. A file named `cover.<ext>` (case-insensitive), or
2. failing that, a file named `front.<ext>` (case-insensitive), or
3. failing that, the album directory's single image file, if — and only
   if — exactly one exists (any of `jpg`, `jpeg`, `png`, `gif`, `bmp`,
   `webp`, `tif`, `tiff`).

An album with no `cover.*`/`front.*` file and either zero or more than one
other image file simply has no cover copied for it — this is not an error.
With multiple `--path` albums, each is checked independently, so `cover-02`
can exist even if `cover-01` doesn't (and vice versa).

### Volume normalization

`--normalize` makes every converted WAV track's loudness consistent, so
there's no jarring volume jump between tracks pulled from different albums.
It reproduces Audacity's **Normalize** effect run with its default
settings, applied independently to each track:

1. Remove any DC offset (a constant bias in the waveform).
2. Apply a uniform gain to the (now DC-free) track so its peak amplitude
   reaches **-1.0 dB** — Audacity's own default target level. Both
   channels are scaled together by the same gain (matching Audacity's
   default of *not* normalizing stereo channels independently), not
   boosted or attenuated separately.

Both measurements are taken with `ffmpeg`'s `astats` filter and the gain is
applied with its `volume` filter — no extra tools are required beyond the
`ffmpeg`/`ffprobe` already needed by the rest of the script. A track that is
completely silent has no measurable peak level; its DC offset is still
removed, but the gain step is skipped and logged rather than producing an
error. `--normalize` is off by default, since it adds one to two extra
`ffmpeg` passes per track.

### Execution stage logging

The script logs each execution stage (dependency checks, input validation,
per-album scanning, capacity validation, packing, WAV conversion, playlist
and report writing) to stderr, prefixed with `[mixtape]`, so progress is
visible on longer multi-album runs. The final success line is printed to
stdout as before.

Each stage also reports how long it took (in whole seconds), and the script
prints a total execution time when it finishes. During WAV conversion, every
individual track logs a start and completion line with its own elapsed time,
so a slow track is easy to spot in a long run:

```
[mixtape] Scanning album 1/1: albums/album-one
[mixtape] Stage 'album scanning' completed in 2s
[mixtape] Converting track 1/15: 'Mysterious' -> '01.wav'...
[mixtape] Converted track 1/15: 'Mysterious' in 1s
...
[mixtape] Stage 'WAV conversion' completed in 5s
[mixtape] Done.
[mixtape] Total execution time: 7s
```

Both `--flag value` and `--flag=value` forms are accepted.

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success. |
| `1` | An error occurred (see the printed message); output is not written on failure. |

## Examples

Convert an mp3 album onto a single 90-minute tape, writing output to
`./mixtape`:

```sh
./mixtape.sh --path albums/mp3-album
```

Split a flac+cue album across a 90-minute tape followed by a 60-minute
tape, writing to a custom destination:

```sh
./mixtape.sh --path albums/flac-cue-album --length 90,60 --dest ./out
```

Example `mixtape.txt` excerpt:

```text
Tape 1
Length: 90
Duration: 01:06:58
Sides: 00:43:49/00:23:09

Side A
01. 5:28. Mysterious
02. 3:57. To Be No. 1
...

Side B
10. 3:58. Freshly Squeezed
...
```

Add `--include-artist-name` to prefix each track line with `Artist - Title`
(tracks without artist metadata still show the title alone):

```sh
./mixtape.sh --path albums/mp3-album --include-artist-name
```

```text
Side A
01. 5:28. Scorpions - Mysterious
02. 3:57. Scorpions - To Be No. 1
...
```

Add `--dry-run` to quickly check the tape/side layout — only `mixtape.txt`
is written, with no WAV conversion, `.m3u` playlists, or cover art copying:

```sh
./mixtape.sh --path albums/mp3-album --length 90,90 --dry-run
```

Add `--normalize` to level out loudness differences across tracks/albums,
using the same algorithm as Audacity's Normalize effect (DC offset removal
+ peak gain to -1.0 dB):

```sh
./mixtape.sh --path albums/album-one --path albums/album-two --normalize
```

Add `--fit-to-side` so each album always starts on a fresh tape side
instead of possibly sharing a side with the next album:

```sh
./mixtape.sh --path albums/album-one --path albums/album-two --length 90 --fit-to-side
```

## Notes and limitations

* Cassette tape lengths are restricted to real-world standard lengths:
  `46, 60, 90, 100, 110, 120, 130` minutes. Side capacity is always half
  the tape length.
* If a single track is longer than the largest requested tape side, or the
  album's total duration exceeds the combined capacity of all requested
  tapes, the script fails with a clear error before writing any output.
* Track-line numbering in `mixtape.txt` uses the track's global Track
  Number (not a per-side sequence).
