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
   its volume level to a consistent loudness (`--normalize`, see below).
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

### Cross-platform wrapper script

Typing out the `docker run -v ... -v ... afrunt/mixtape ...` invocation by
hand works, but [mixtape-wrapper.sh](mixtape-wrapper.sh) does it for you:
it imitates `mixtape.sh`'s own command-line interface exactly, while
delegating all the real work to the Docker image underneath. Every `--path`
and `--dest` directory you pass is a normal host path — the wrapper mounts
it into the container and rewrites the option for you — and every other
flag (`--length`, `--include-artist-name`, `--dry-run`, `--normalize`,
`--fit-to-side`, `--help`, ...) is forwarded to the container unchanged.

```sh
./mixtape-wrapper.sh --path albums/album-one --path albums/album-two \
  --dest ./out --length 90 --fit-to-side --normalize
```

is equivalent to running `mixtape.sh` natively with those same arguments,
with none of the volume-mount bookkeeping shown earlier in this section.

The wrapper is a plain bash script, so it runs unmodified on Linux, macOS,
and Windows (via Git Bash/MSYS2 or WSL) — the only requirements are `bash`
and `docker` on `PATH`; it takes care of the host-path translation Docker
Desktop for Windows needs internally (using `cygpath` when running under
Git Bash/MSYS2), so the exact same command line works the same way on all
three platforms. To use a different image (for example one you built
locally under another tag), set `MIXTAPE_DOCKER_IMAGE` in the environment
rather than passing an extra flag, keeping the CLI itself identical to
`mixtape.sh`'s:

```sh
MIXTAPE_DOCKER_IMAGE=afrunt/mixtape:sha-abc1234 ./mixtape-wrapper.sh --path albums/my-album
```

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
mixtape.sh --path <album-dir> [--path <album-dir> ...] [--length <list>] [--dest <dir>] [--include-artist-name] [--normalize] [--fit-to-side]
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
| `--normalize` | off | When present, normalize every converted WAV track's volume by matching its integrated loudness (LUFS) to a fixed target (capped to avoid clipping) — see [Volume normalization](#volume-normalization). |
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

`--normalize` makes every converted WAV track's *perceived* loudness
consistent, so there's no jarring volume jump between tracks — including
between tracks pulled from differently mastered albums — and you never
need to touch the volume knob on your tape deck partway through a side.

1. Remove any DC offset (a constant bias in the waveform).
2. Run `ffmpeg`'s `loudnorm` filter (EBU R128) as a genuine **two-pass**
   process: a first pass *measures* the track's integrated loudness, true
   peak, and loudness range; a second pass feeds those exact measured
   values back into `loudnorm` to *apply* the correction, targeting
   **-16 LUFS** integrated loudness while keeping true peak at or under
   **-1.0 dBTP**.

Matching *loudness* rather than just peak level matters because two
albums can share the exact same peak level while sounding very different
in volume — a heavily compressed/"loudness war" mastered album packs far
more average energy into the same peak than a more dynamic one. Matching
peaks alone (as a simple peak normalizer, e.g. Audacity's basic Normalize
effect, does) leaves that difference fully intact; matching LUFS removes
it, which is what actually keeps different albums sounding equally loud
next to each other.

The two-pass approach (rather than one flat gain computed up front)
matters *within* an album too: some tracks have a true peak that is
already "hot" (an inter-sample peak above 0 dBFS, common on heavily
mastered tracks) even before any gain is applied. A single flat gain
capped to protect that peak would drag the *entire* track quieter than
the -16 LUFS target, while less-peaky tracks in the same album would
reach the target exactly — making tracks in the same album sound uneven
again. Feeding ffmpeg's own measured values back into a second `loudnorm`
pass lets it apply gentle, track-specific limiting only where a track's
own dynamics require it, so every track — regardless of how hot its
peaks are — converges on the same -16 LUFS target while its true peak
still respects the -1.0 dBTP ceiling. A loudness range (LRA) of `11` LU
is used for both passes, giving `loudnorm` enough headroom to hit the
target precisely on dynamic tracks without over-compressing them.

Both passes are run with `ffmpeg` (`astats` for DC offset, `loudnorm` for
the measure and apply passes) — no extra tools are required beyond the
`ffmpeg`/`ffprobe` already needed by the rest of the script. A track that
is completely silent has no measurable loudness; its DC offset is still
removed, but the loudness pass is skipped and logged rather than
producing an error. `--normalize` is off by default, since it adds two
extra `ffmpeg` passes per track.

### Execution stage logging

The script logs each execution stage (dependency checks, input validation,
per-album scanning, capacity validation, packing, WAV conversion, playlist
and report writing) to stderr, prefixed with `[mixtape]`, so progress is
visible on longer multi-album runs. The final success line is printed to
stdout as before.

Each stage also reports how long it took (in whole seconds), and the script
prints a total execution time when it finishes. During WAV conversion, every
individual track logs a start and completion line with its own elapsed time,
so a slow track is easy to spot in a long run. When `--normalize` is on,
each track's normalization log line also reports its own elapsed time:

```
[mixtape] Scanning album 1/1: albums/album-one
[mixtape] Stage 'album scanning' completed in 2s
[mixtape] Converting track 1/15: 'Mysterious' -> '01.wav'...
[mixtape] Converted track 1/15: 'Mysterious' in 1s
[mixtape] Normalized 'Mysterious': removed DC offset -0.000254, applied
loudness normalization (was -8.31 LUFS / 1.88dBTP true peak; target -16.0
LUFS / -1.0dBTP ceiling) in 13s
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

Add `--normalize` to level out loudness differences across tracks/albums
by matching integrated loudness (LUFS), not just peak level, so
differently mastered albums end up sounding equally loud:

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

---

# mixtape.sh (українською)

Сканує музичний альбом і визначає, які треки записуються на кожну сторону
однієї чи кількох аудіокасет — ніколи не розрізаючи трек на межі сторони —
після чого конвертує без втрат кожен трек у WAV, записує `.m3u`
плейлисти для кожної сторони та формує звіт `mixtape.txt` з описом
повного розкладу.

## Що робить скрипт

Маючи директорію альбому з файлами `mp3`, `wav` або `flac` (+ `.cue`):

1. Читає з метаданих номер треку, назву та тривалість кожного треку.
2. Сортує треки за номером треку (або за алфавітом імені файлу, якщо
   жоден трек в альбомі не має номера — див. нижче) і розподіляє їх по
   сторонах касети (A/B) на одній чи кількох касетах, по порядку, ніколи
   не розрізаючи трек на межі сторони. Якщо трек не влазить на поточну
   сторону, він (і все, що йде після нього) переноситься на наступну
   сторону.
3. Конвертує кожен трек без втрат у PCM WAV файл, за бажанням
   нормалізуючи рівень гучності до однакової сприйманої гучності
   (`--normalize`, див. нижче).
4. Записує один розширений `.m3u` плейлист для кожної непорожньої сторони
   касети, де кожен рядок `#EXTINF` показує `Artist - Title`, якщо є дані
   про виконавця (інакше — лише назву).
5. Записує звіт `mixtape.txt`, що показує сторони кожної касети, їх
   тривалість та список треків.
6. Копіює зображення обкладинки кожного альбому (якщо знайдено — див.
   нижче) у `--dest` як `cover-NN.<ext>`.

## Запуск через Docker (рекомендовано)

**Рекомендований спосіб запуску `mixtape.sh` — через Docker-образ**, а не
запуск скрипта напряму. Образ уже містить `mixtape.sh` разом з
`ffmpeg`/`ffprobe`, тож на хості не потрібно нічого встановлювати, крім
самого Docker — не треба перейматися версією `bash`, наявністю `ffmpeg`
чи будь-якою іншою залежністю хоста, описаною нижче. Він також працює
однаково на Linux, macOS та Windows (через Docker Desktop/WSL2), тобто
жодного платформо-специфічного налаштування не потрібно.

Оскільки образ збирається безпосередньо з `Dockerfile` та `mixtape.sh` у
цьому репозиторії, він завжди відображає найновішу версію скрипта —
перезбирання образу (або отримання щойно опублікованого) автоматично
підхоплює всі виправлення та нові можливості, без потреби самостійно
відстежувати чи копіювати файл скрипта.

### Запуск образу

Змонтуйте директорію альбому (тільки для читання) та вихідну директорію,
після чого передайте ті самі прапорці, що й для нативного скрипта —
`--path`/`--dest` посилаються на шляхи *всередині контейнера*, тож
вказуйте їх на точки монтування:

```sh
docker run --rm -it \
  -v "$(pwd)/albums/my-album:/album:ro" \
  -v "$(pwd)/out:/out" \
  afrunt/mixtape --path /album --dest /out --length 90
```

Запуск образу без аргументів (або з `--help`) виводить довідку:

```sh
docker run --rm -it afrunt/mixtape --help
```

Конвертовані WAV файли, `.m3u` плейлисти та `mixtape.txt` з'являться на
хості в `./out` після завершення роботи контейнера.

Більше прикладів, з монтуванням кількох альбомів і поєднанням кількох
прапорців одночасно:

```sh
# Два альбоми, власна довжина касети, кожен альбом на своїй стороні
docker run --rm -it \
  -v "$(pwd)/albums/album-one:/albums/album-one:ro" \
  -v "$(pwd)/albums/album-two:/albums/album-two:ro" \
  -v "$(pwd)/out:/out" \
  afrunt/mixtape \
  --path /albums/album-one --path /albums/album-two \
  --dest /out --length 90 --fit-to-side

# Швидкий пробний запуск лише для перевірки розкладу, без конвертації
docker run --rm -it \
  -v "$(pwd)/albums/my-album:/album:ro" \
  -v "$(pwd)/out:/out" \
  afrunt/mixtape --path /album --dest /out --length 90,90 --dry-run

# Нормалізація гучності між альбомами
docker run --rm -it \
  -v "$(pwd)/albums/album-one:/albums/album-one:ro" \
  -v "$(pwd)/albums/album-two:/albums/album-two:ro" \
  -v "$(pwd)/out:/out" \
  afrunt/mixtape \
  --path /albums/album-one --path /albums/album-two \
  --dest /out --normalize
```

### Збірка образу (опційно)

Більшості користувачів це не потрібно — просто отримайте чи повторно
використайте готовий образ. Збирайте його самостійно лише якщо хочете
змінити `mixtape.sh` (чи `Dockerfile`) або краще розібратися, як образ
влаштований:

```sh
docker build -t afrunt/mixtape .
```

Якщо ви волієте запускати скрипт нативно замість Docker, дивіться
[Вимоги](#вимоги) та [Використання](#використання) нижче.

### Кросплатформенний скрипт-обгортка

Вручну набирати виклик `docker run -v ... -v ... afrunt/mixtape ...` цілком
можливо, але [mixtape-wrapper.sh](mixtape-wrapper.sh) робить це за вас: він
точно імітує власний інтерфейс командного рядка `mixtape.sh`, делегуючи
всю справжню роботу Docker-образу під капотом. Кожна директорія, передана
через `--path` та `--dest`, — це звичайний шлях на хості: обгортка сама
монтує його в контейнер і переписує параметр, а всі інші прапорці
(`--length`, `--include-artist-name`, `--dry-run`, `--normalize`,
`--fit-to-side`, `--help` тощо) передаються в контейнер без змін.

```sh
./mixtape-wrapper.sh --path albums/album-one --path albums/album-two \
  --dest ./out --length 90 --fit-to-side --normalize
```

еквівалентно запуску `mixtape.sh` нативно з тими самими аргументами, без
жодної ручної роботи з монтуванням томів, показаної раніше в цьому
розділі.

Обгортка — це звичайний bash-скрипт, тож вона працює без змін на Linux,
macOS та Windows (через Git Bash/MSYS2 чи WSL) — єдині вимоги: `bash` та
`docker` у `PATH`; вона самостійно виконує перетворення шляхів хоста, яке
потрібне Docker Desktop для Windows (використовуючи `cygpath` під час
роботи в Git Bash/MSYS2), тож той самий рядок команди працює однаково на
всіх трьох платформах. Щоб використати інший образ (наприклад, зібраний
локально під іншим тегом), встановіть змінну середовища
`MIXTAPE_DOCKER_IMAGE` замість додавання окремого прапорця — це зберігає
інтерфейс командного рядка ідентичним до `mixtape.sh`:

```sh
MIXTAPE_DOCKER_IMAGE=afrunt/mixtape:sha-abc1234 ./mixtape-wrapper.sh --path albums/my-album
```

## Підтримувані структури альбомів

| Структура | Правило визначення | Джерело метаданих |
|--------|------------------------------------------|------------------|
| mp3     | Один чи більше `.mp3` файлів у директорії | Теги `ffprobe` (`title`, `track`) для кожного файлу |
| wav     | Один чи більше `.wav` файлів (перевіряється, якщо немає mp3/flac) | Теги `ffprobe` (`title`, `track`) для кожного файлу |
| flac+cue | Рівно один `.flac` файл разом із супровідним `.cue` файлом | Розбирається з `.cue` файлу (`TRACK`, `TITLE`, `INDEX 01`) |

Пріоритет визначення формату: flac+cue > wav > mp3. Якщо `.flac` файли
існують, але не відповідають точній структурі "один файл + один cue
файл", скрипт видає конкретну помилку, а не мовчки переходить до іншого
формату.

Для mp3/wav альбомів, якщо жоден трек не має тегу номера треку, скрипт
переходить до впорядкування за алфавітом імені файлу замість помилки. Якщо
номер треку має лише *частина* треків в альбомі, це все одно помилка —
додайте тег до кожного треку або приберіть його з кожного треку.
(flac+cue альбоми завжди мають номер треку для кожного треку, оскільки
він походить зі структури cue файлу, а не з тегу окремого файлу, тож цей
запасний варіант ніколи до них не застосовується.) Дублікати номерів
треків відхиляються.

## Вимоги

* `ffmpeg` та `ffprobe` доступні у `PATH` (перевіряється при запуску).
* `bash` (скрипт написано так, щоб він також працював під bash 3.2,
  наприклад стандартний `/bin/bash` на macOS).

Жодні інші зовнішні інструменти не потрібні.

## Використання

```sh
mixtape.sh --path <album-dir> [--path <album-dir> ...] [--length <list>] [--dest <dir>] [--include-artist-name] [--normalize] [--fit-to-side]
mixtape.sh --help
```

### Параметри

| Параметр | Значення за замовчуванням | Опис |
|--------|---------|-------------|
| `--path <dir>` | *(обов'язковий)* | Шлях до наявної директорії з mp3, wav або flac альбомом. Може бути вказаний кілька разів, щоб записати кілька альбомів на той самий набір касет, один за одним у вказаному порядку. |
| `--length <list>` | `90` | Список довжин касет у хвилинах через кому, по одному значенню на касету, у порядку. Наприклад `90` (одна 90-хвилинна касета) або `90,60,60` (90-хвилинна касета, а потім дві 60-хвилинні). Кожне значення має бути одним із `46, 60, 90, 100, 110, 120, 130`. |
| `--dest <dir>` | `./mixtape` | Вихідна директорія для `mixtape.txt`, конвертованих WAV файлів та `.m3u` плейлистів. Створюється автоматично, якщо не існує. **Якщо вона вже існує, її вміст спочатку видаляється**, тож директорія завжди відображає лише результат поточного запуску. |
| `--include-artist-name` | вимкнено | Якщо вказано, кожен рядок треку в `mixtape.txt` матиме префікс з іменем виконавця у форматі `Artist - Title`. Якщо трек не має метаданих виконавця, показується лише назва, навіть якщо прапорець встановлено. |
| `--dry-run` | вимкнено | Якщо вказано, обчислюється й записується лише `mixtape.txt`; конвертація WAV, запис `.m3u` плейлистів та копіювання обкладинок пропускаються. Корисно для швидкої перевірки розкладу касет/сторін без витрат часу на конвертацію аудіо. |
| `--normalize` | вимкнено | Якщо вказано, гучність кожного конвертованого WAV треку нормалізується шляхом вирівнювання інтегральної гучності (LUFS) до фіксованого цільового рівня (з обмеженням проти кліпінгу) — див. [Нормалізація гучності](#нормалізація-гучності). |
| `--fit-to-side` | вимкнено | Якщо вказано разом з більш ніж одним `--path` альбомом, кожен альбом завжди починається з нової сторони касети — див. [Розміщення кожного альбому на окремій стороні](#розміщення-кожного-альбому-на-окремій-стороні). |
| `--help`, `-h` | | Вивести довідку і завершити роботу. |

### Обробка вихідної директорії

`--dest` завжди очищується та (пере)створюється перед записом чогось: якщо
вона вже існує, її наявний вміст спочатку видаляється, тож залишкові
файли з попереднього запуску ніколи не змішуються з результатом поточного
запуску. Задля безпеки скрипт відмовляється використовувати значення
`--dest`, що дорівнюють `` (порожньому), `/`, `.` або `..`, оскільки
очищення цих шляхів було б катастрофічним. Якщо `--dest` — це
bind-змонтована директорія (наприклад, том Docker), видаляється лише її
*вміст* — сама точка монтування залишається на місці, оскільки її
зазвичай неможливо видалити й повторно створити.

### Кілька альбомів

Передайте `--path` кілька разів, щоб записати кілька альбомів послідовно
на ті самі касети, у порядку вказання прапорців. Послідовність номерів
треків кожного альбому перевіряється незалежно (дублікати номерів треків
є помилкою лише в межах одного альбому), а об'єднаний список треків
розподіляється по запитаних касетах `--length` точно так само, як треки
одного альбому. Рядки треків у `mixtape.txt` нумеруються за їх позицією у
цій об'єднаній послідовності (строго зростаючи, наприклад `01`...`30` для
двох 15-трекових альбомів), а не власним номером треку кожного альбому,
тож звіт завжди залишається у правильному числовому порядку. Якщо
загальна тривалість усіх заданих альбомів не влазить у запитану ємність
касет, скрипт завершується з чіткою помилкою до запису будь-якого
результату.

```sh
./mixtape.sh --path albums/album-one --path albums/album-two --length 90,90
```

Якщо `--length` вказує більше касет, ніж потрібно для розміщення всіх
треків, зайві повністю невикористані завершальні касети просто не
включаються у `mixtape.txt` — перелічуються лише касети, що мають хоча б
один трек на будь-якій стороні. Касета, заповнена лише частково (одна
сторона використана, інша порожня), як і раніше показується повністю.

### Розміщення кожного альбому на окремій стороні

За замовчуванням, при розподілі кількох альбомів, сторона касети може
містити хвіст одного альбому разом з початком наступного, якщо обидва
влазять. `--fit-to-side` змінює це: з більш ніж одним `--path` альбомом
кожен альбом завжди починається з нової сторони касети, навіть якщо на
попередній стороні ще є вільне місце. Альбом, який сам по собі довший за
одну сторону, як і раніше може займати кілька сторін — лише *різні*
альбоми не змішуються на одній стороні.

```sh
./mixtape.sh --path albums/album-one --path albums/album-two --length 90 --fit-to-side
```

Якщо заданий список `--length` не залишає достатньо сторін, щоб розділити
всі альбоми таким чином, скрипт виводить попередження з поясненням і
повертається до звичайного режиму розподілу (сторони можуть містити
треки з кількох альбомів) замість того, щоб завершитися з помилкою:

```
[mixtape] Warning: --fit-to-side could not place every album onto its own
tape side with the current --length (2 albums across 1 tape(s)); falling
back to normal packing, where a tape side may contain tracks from more
than one album. Recommendation: add another tape, choose a longer --length
value, or reorder --path so consecutive albums' durations pair up more
evenly per side.
```

З одним `--path` альбомом `--fit-to-side` не має ефекту (є лише один
альбом, тож немає з чим його розділяти на окрему сторону).

### Обкладинки

Якщо директорія альбому містить зображення обкладинки, воно копіюється у
`--dest` як `cover-NN.<ext>`, де `NN` — це 1-based позиція цього альбому
серед заданих аргументів `--path` (доповнена до щонайменше 2 цифр), а
`<ext>` — розширення оригінального зображення. Зображення обкладинки
альбому вибирається так, по порядку:

1. Файл з назвою `cover.<ext>` (без урахування регістру), або
2. якщо такого немає, файл з назвою `front.<ext>` (без урахування
   регістру), або
3. якщо й такого немає, єдиний файл зображення в директорії альбому,
   якщо — і тільки якщо — існує рівно один такий файл (будь-якого з
   форматів `jpg`, `jpeg`, `png`, `gif`, `bmp`, `webp`, `tif`, `tiff`).

Альбом без файлу `cover.*`/`front.*` і з нулем або більш ніж одним іншим
файлом зображення просто не матиме скопійованої обкладинки — це не є
помилкою. При кількох `--path` альбомах кожен перевіряється незалежно,
тож `cover-02` може існувати, навіть якщо `cover-01` не існує (і навпаки).

### Нормалізація гучності

`--normalize` вирівнює *сприйману* гучність кожного конвертованого WAV
треку, щоб не було різкого стрибка гучності між треками — зокрема між
треками з по-різному зведених/змастерингованих альбомів — і щоб не
доводилося чіпати регулятор гучності на магнітофоні посеред сторони.

1. Видалення будь-якого DC зміщення (постійного зсуву у формі хвилі).
2. Запуск фільтра `loudnorm` (EBU R128) з `ffmpeg` у справжньому
   **двопрохідному** режимі: перший прохід *вимірює* інтегральну
   гучність, піковий рівень і діапазон гучності треку; другий прохід
   передає ці точні виміряні значення назад у `loudnorm`, щоб
   *застосувати* корекцію з ціллю **-16 LUFS** інтегральної гучності,
   утримуючи піковий рівень на позначці або нижче **-1.0 dBTP**.

Вирівнювання саме за *гучністю*, а не лише за піковим рівнем, важливе,
тому що два альбоми можуть мати однаковий піковий рівень, але звучати
зовсім по-різному за гучністю — сильно стиснутий ("loudness war")
альбом вміщує значно більше середньої енергії у той самий піковий
рівень, ніж динамічніший альбом. Вирівнювання лише за піком (як це
робить простий пік-нормалізатор, наприклад базовий ефект Normalize в
Audacity) залишає цю різницю недоторканою; вирівнювання за LUFS її
усуває — саме це й дозволяє різним альбомам звучати однаково гучно один
поруч з іншим.

Двопрохідний підхід (замість одного плоского підсилення, обчисленого
наперед) важливий і *в межах* одного альбому: деякі треки мають уже
"гарячий" піковий рівень (міжвідліковий пік вище 0 dBFS, поширений на
сильно змастерингованих треках) ще до застосування будь-якого
підсилення. Єдине плоске підсилення, обмежене задля захисту цього піку,
притлумило б *весь* трек тихіше за цільові -16 LUFS, тоді як менш
"пікові" треки того ж альбому досягали б цілі точно — знову створюючи
нерівномірність гучності в межах альбому. Передача власних виміряних
значень `ffmpeg` назад у другий прохід `loudnorm` дозволяє йому
застосувати м'яке, специфічне для треку обмеження лише там, де це
дійсно потрібно через динаміку конкретного треку, тож кожен трек —
незалежно від того, наскільки "гарячі" його піки — сходиться до тієї ж
цілі -16 LUFS, і водночас його піковий рівень усе одно залишається в
межах -1.0 dBTP. Для обох проходів використовується діапазон гучності
(LRA) `11` LU, що дає `loudnorm` достатньо запасу, щоб точно досягти
цілі на динамічних треках без надмірної компресії.

Обидва проходи виконуються засобами `ffmpeg` (`astats` для DC зміщення,
`loudnorm` для проходів вимірювання та застосування) — жодних
додаткових інструментів, крім уже потрібних `ffmpeg`/`ffprobe`, не
потрібно. Трек, який повністю беззвучний, не має вимірюваної гучності;
його DC зміщення все одно видаляється, але прохід гучності
пропускається і фіксується в логах замість помилки. `--normalize`
вимкнено за замовчуванням, оскільки він додає два додаткові проходи
`ffmpeg` на трек.

### Логування етапів виконання

Скрипт логує кожен етап виконання (перевірка залежностей, валідація
вхідних даних, сканування кожного альбому, перевірка тривалості, розподіл,
конвертація WAV, запис плейлистів та звіту) у stderr, з префіксом
`[mixtape]`, тож прогрес видно під час довших запусків з кількома
альбомами. Фінальний рядок успіху, як і раніше, виводиться у stdout.

Кожен етап також повідомляє, скільки часу він зайняв (у цілих секундах), і
скрипт виводить загальний час виконання після завершення. Під час
конвертації WAV кожен окремий трек логує рядок початку та завершення з
власним витраченим часом, тож повільний трек легко помітити у довгому
запуску. Коли ввімкнено `--normalize`, рядок логу нормалізації кожного
треку також повідомляє власний витрачений час:

```
[mixtape] Scanning album 1/1: albums/album-one
[mixtape] Stage 'album scanning' completed in 2s
[mixtape] Converting track 1/15: 'Mysterious' -> '01.wav'...
[mixtape] Converted track 1/15: 'Mysterious' in 1s
[mixtape] Normalized 'Mysterious': removed DC offset -0.000254, applied
loudness normalization (was -8.31 LUFS / 1.88dBTP true peak; target -16.0
LUFS / -1.0dBTP ceiling) in 13s
...
[mixtape] Stage 'WAV conversion' completed in 5s
[mixtape] Done.
[mixtape] Total execution time: 7s
```

Приймаються обидві форми: `--flag value` та `--flag=value`.

### Коди завершення

| Код | Значення |
|------|---------|
| `0` | Успіх. |
| `1` | Сталася помилка (див. виведене повідомлення); результат не записується у разі невдачі. |

## Приклади

Конвертувати mp3 альбом на одну 90-хвилинну касету, записавши результат у
`./mixtape`:

```sh
./mixtape.sh --path albums/mp3-album
```

Розділити flac+cue альбом на 90-хвилинну касету, а потім 60-хвилинну,
записавши у власну директорію призначення:

```sh
./mixtape.sh --path albums/flac-cue-album --length 90,60 --dest ./out
```

Приклад фрагменту `mixtape.txt`:

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

Додайте `--include-artist-name`, щоб додати назву артиста до кожного рядка
`Artist - Title` (треки без метаданих виконавця все одно показують лише
назву):

```sh
./mixtape.sh --path albums/mp3-album --include-artist-name
```

```text
Side A
01. 5:28. Scorpions - Mysterious
02. 3:57. Scorpions - To Be No. 1
...
```

Додайте `--dry-run`, щоб швидко перевірити розклад касет/сторін — лише
`mixtape.txt` буде записано, без конвертації WAV, `.m3u` плейлистів чи
копіювання обкладинок:

```sh
./mixtape.sh --path albums/mp3-album --length 90,90 --dry-run
```

Додайте `--normalize`, щоб вирівняти різницю в гучності між
треками/альбомами, зіставляючи інтегральну гучність (LUFS), а не лише
піковий рівень, щоб по-різному змастеринговані альбоми звучали однаково
гучно:

```sh
./mixtape.sh --path albums/album-one --path albums/album-two --normalize
```

Додайте `--fit-to-side`, щоб кожен альбом завжди починався з нової
сторони касети замість можливого поділу сторони з наступним альбомом:

```sh
./mixtape.sh --path albums/album-one --path albums/album-two --length 90 --fit-to-side
```

## Примітки та обмеження

* Довжини аудіокасет обмежені реальними стандартними значеннями:
  `46, 60, 90, 100, 110, 120, 130` хвилин. Тривалість сторони завжди
  дорівнює половині довжини касети.
* Якщо один трек довший за найбільшу запитану сторону касети, або
  загальна тривалість альбому перевищує сумарну тривалість усіх запитаних
  касет, скрипт завершується з чіткою помилкою до запису будь-якого
  результату.
* Нумерація рядків треків у `mixtape.txt` використовує глобальний номер
  треку (а не послідовність в межах сторони).
