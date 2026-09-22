#!/usr/bin/env bash
#
# mixtape.sh - Scan a music album and plan which tracks record onto each side
# of one or more audio cassette tapes.
#
# For an album directory containing mp3, wav, or flac tracks, this script:
#   * Reads Track Number, title, and duration metadata for every track.
#   * Packs tracks onto cassette tape sides (A/B) in Track Number order,
#     across one or more tapes, without ever splitting a track across sides.
#   * Converts every track to a lossless WAV file.
#   * Writes one .m3u playlist per tape side.
#   * Writes a mixtape.txt report describing the tape/side assignment.
#
# Usage:
#   mixtape.sh --path <album-dir> [--path <album-dir> ...] [--length <list>]
#              [--dest <dir>] [--include-artist-name] [--dry-run]
#              [--normalize] [--fit-to-side]
#   mixtape.sh --help
#
# Options:
#   --path <dir>      Path to an existing directory containing an mp3, wav,
#                      or flac album. Required; may be given more than once
#                      to record several albums onto the same set of tapes,
#                      one after another in the order given.
#   --length <list>   Comma-separated list of cassette tape lengths in
#                      minutes, for example "90" or "90,60,60" for three
#                      sequential tapes. Each value must be one of:
#                      46, 60, 90, 100, 110, 120, 130. Default: 90.
#   --dest <dir>      Output directory for mixtape.txt, converted WAV
#                      tracks, and .m3u playlists. Default: ./mixtape
#   --include-artist-name
#                      Prefix each track line in mixtape.txt with the
#                      track's artist, formatted as "Artist - Title".
#                      Default: off (title only).
#   --dry-run          Only compute and write mixtape.txt; skip WAV
#                      conversion, .m3u playlist writing, and cover art
#                      copying entirely. Useful for quickly checking how
#                      tracks would be split without spending time on
#                      audio conversion. Default: off.
#   --normalize        Normalize the volume level of every converted WAV
#                      track: remove any DC offset, then apply two-pass EBU
#                      R128 loudness normalization (ffmpeg loudnorm) so each
#                      track's integrated loudness reaches -16 LUFS while its
#                      true peak stays at or under -1.0 dBTP. Matching
#                      loudness (not just peak level) with a two-pass
#                      measure/apply approach keeps every track - across and
#                      within albums, including tracks with hot true peaks -
#                      sounding equally loud next to each other. Default: off.
#   --fit-to-side      With more than one --path album, never let a tape
#                      side contain tracks from more than one album: each
#                      album always starts on a fresh side, even if the
#                      previous side still has unused room. If this can't
#                      be done with the given --length list, a warning is
#                      printed and packing falls back to the normal mode
#                      (sides may be shared between albums). Default: off.
#   --help, -h        Show this help message and exit.
#
# Requirements:
#   ffmpeg and ffprobe must be installed and available on PATH.
#
# Exit codes:
#   0   Success.
#   1   An error occurred; see the printed message.
#
# All output and error messages are US technical English.

set -u

readonly MIXTAPE_VALID_LENGTHS="46 60 90 100 110 120 130"
# Target integrated loudness for --normalize, in LUFS (EBU R128 scale).
# -16 LUFS matches common streaming-loudness practice and, unlike matching
# peak level alone, keeps differently-mastered albums (louder/more
# compressed vs. quieter/more dynamic) sounding equally loud next to each
# other, so no volume knob adjustment is needed between albums on tape.
readonly MIXTAPE_NORMALIZE_TARGET_LUFS="-16.0"
# True peak ceiling for --normalize, in dBTP: ffmpeg's loudnorm filter
# keeps every processed track's true peak at or under this level while
# still reaching MIXTAPE_NORMALIZE_TARGET_LUFS, applying gain reduction
# only where a track's own peaks actually need it (rather than one flat
# gain for the whole track), so a single hot moment in an otherwise quiet,
# dynamic track no longer drags its entire average loudness down below
# every other track's.
readonly MIXTAPE_NORMALIZE_PEAK_CEILING_DB="-1.0"
# Loudness range (LRA) target in LU: how much of a track's original
# loudness variation loudnorm is allowed to preserve while still reaching
# the integrated-loudness target above. ffmpeg's own default (7 LU) is
# tighter than typical album masters need; 11 LU gives loudnorm enough
# headroom to hit the target on wide-dynamic-range tracks without
# resorting to heavier compression than necessary.
readonly MIXTAPE_NORMALIZE_LRA="11"

mixtape_err() {
  printf 'mixtape.sh: error: %s\n' "$*" >&2
}

mixtape_die() {
  mixtape_err "$*"
  exit 1
}

mixtape_log() {
  printf '[mixtape] %s\n' "$*" >&2
}

# Runs one stage as a named function call and logs how long it took, using
# the bash builtin $SECONDS (whole seconds elapsed since shell start) so no
# external `date` call is required. Stage functions take no arguments.
mixtape_run_stage() {
  local label="$1"
  local fn="$2"
  local stage_start="$SECONDS"

  "$fn"

  mixtape_log "Stage '$label' completed in $((SECONDS - stage_start))s"
}

mixtape_print_help() {
  cat <<'EOF'
mixtape.sh - Scan a music album and plan which tracks record onto each side
of one or more audio cassette tapes.

For an album directory containing mp3, wav, or flac tracks, this script:
  * Reads Track Number, title, and duration metadata for every track.
  * Packs tracks onto cassette tape sides (A/B) in Track Number order,
    across one or more tapes, without ever splitting a track across sides.
  * Converts every track to a lossless WAV file.
  * Writes one .m3u playlist per tape side.
  * Writes a mixtape.txt report describing the tape/side assignment.

Usage:
  mixtape.sh --path <album-dir> [--path <album-dir> ...] [--length <list>]
             [--dest <dir>] [--include-artist-name] [--dry-run]
             [--normalize] [--fit-to-side]
  mixtape.sh --help

Options:
  --path <dir>      Path to an existing directory containing an mp3, wav,
                     or flac album. Required; may be given more than once
                     to record several albums onto the same set of tapes,
                     one after another in the order given.
  --length <list>   Comma-separated list of cassette tape lengths in
                     minutes, for example "90" or "90,60,60" for three
                     sequential tapes. Each value must be one of:
                     46, 60, 90, 100, 110, 120, 130. Default: 90.
  --dest <dir>      Output directory for mixtape.txt, converted WAV
                     tracks, and .m3u playlists. Default: ./mixtape
  --include-artist-name
                     Prefix each track line in mixtape.txt with the
                     track's artist, formatted as "Artist - Title".
                     Default: off (title only).
  --dry-run          Only compute and write mixtape.txt; skip WAV
                     conversion, .m3u playlist writing, and cover art
                     copying entirely. Useful for quickly checking how
                     tracks would be split without spending time on
                     audio conversion. Default: off.
  --normalize        Normalize the volume level of every converted WAV
                     track: remove any DC offset, then apply two-pass EBU
                     R128 loudness normalization (ffmpeg loudnorm) so each
                     track's integrated loudness reaches -16 LUFS while its
                     true peak stays at or under -1.0 dBTP. Matching
                     loudness (not just peak level) with a two-pass
                     measure/apply approach keeps every track - across and
                     within albums, including tracks with hot true peaks -
                     sounding equally loud next to each other. Default: off.
  --fit-to-side      With more than one --path album, never let a tape
                     side contain tracks from more than one album: each
                     album always starts on a fresh side, even if the
                     previous side still has unused room. If this can't
                     be done with the given --length list, a warning is
                     printed and packing falls back to the normal mode
                     (sides may be shared between albums). Default: off.
  --help, -h        Show this help message and exit.

Requirements:
  ffmpeg and ffprobe must be installed and available on PATH.

Exit codes:
  0   Success.
  1   An error occurred; see the printed message.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing (P01-T01)
# ---------------------------------------------------------------------------

mixtape_opt_paths=()
mixtape_opt_length="90"
mixtape_opt_dest="./mixtape"
mixtape_opt_include_artist_name=0
mixtape_opt_dry_run=0
mixtape_opt_normalize=0
mixtape_opt_fit_to_side=0

mixtape_parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --path)
        [ "$#" -ge 2 ] || mixtape_die "--path requires a value"
        mixtape_opt_paths+=("$2")
        shift 2
        ;;
      --path=*)
        mixtape_opt_paths+=("${1#--path=}")
        shift
        ;;
      --length)
        [ "$#" -ge 2 ] || mixtape_die "--length requires a value"
        mixtape_opt_length="$2"
        shift 2
        ;;
      --length=*)
        mixtape_opt_length="${1#--length=}"
        shift
        ;;
      --dest)
        [ "$#" -ge 2 ] || mixtape_die "--dest requires a value"
        mixtape_opt_dest="$2"
        shift 2
        ;;
      --dest=*)
        mixtape_opt_dest="${1#--dest=}"
        shift
        ;;
      --include-artist-name)
        mixtape_opt_include_artist_name=1
        shift
        ;;
      --dry-run)
        mixtape_opt_dry_run=1
        shift
        ;;
      --normalize)
        mixtape_opt_normalize=1
        shift
        ;;
      --fit-to-side)
        mixtape_opt_fit_to_side=1
        shift
        ;;
      --help|-h)
        mixtape_print_help
        exit 0
        ;;
      *)
        mixtape_die "unknown option: $1 (see --help)"
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Environment and input validation, format detection (P01-T02)
# ---------------------------------------------------------------------------

mixtape_check_dependencies() {
  mixtape_log "Checking required dependencies (ffmpeg, ffprobe)..."
  command -v ffmpeg >/dev/null 2>&1 || \
    mixtape_die "required tool 'ffmpeg' was not found on PATH"
  command -v ffprobe >/dev/null 2>&1 || \
    mixtape_die "required tool 'ffprobe' was not found on PATH"
}

mixtape_validate_paths() {
  local p

  mixtape_log "Validating --path argument(s)..."

  [ "${#mixtape_opt_paths[@]}" -ge 1 ] || \
    mixtape_die "--path is required (see --help); it may be given more than once"

  for p in "${mixtape_opt_paths[@]}"; do
    [ -d "$p" ] || \
      mixtape_die "--path '$p' does not exist or is not a directory"
  done
}

mixtape_validate_length_list() {
  local entry
  local valid
  local ok
  local IFS_saved="$IFS"

  mixtape_log "Validating --length value(s): $mixtape_opt_length"

  IFS=','
  set -- $mixtape_opt_length
  IFS="$IFS_saved"
  [ "$#" -ge 1 ] || mixtape_die "--length must not be empty"
  for entry in "$@"; do
    ok=0
    for valid in $MIXTAPE_VALID_LENGTHS; do
      if [ "$entry" = "$valid" ]; then
        ok=1
        break
      fi
    done
    [ "$ok" -eq 1 ] || mixtape_die \
      "invalid --length value '$entry'; valid values are: ${MIXTAPE_VALID_LENGTHS// /, }"
  done
  mixtape_tape_lengths=("$@")
  mixtape_tape_count="$#"
}

# Populated by mixtape_validate_length_list.
mixtape_tape_lengths=()
mixtape_tape_count=0

# Populated by mixtape_detect_format: one of "mp3", "wav", "flac-cue".
mixtape_format=""
# For flac-cue mode only: the single album flac file and its companion cue file.
mixtape_flac_file=""
mixtape_cue_file=""

# Set by mixtape_process_albums to the album directory currently being
# scanned; mixtape_detect_format/mixtape_extract_tracks operate on it. Not
# a user option (--path may be given more than once; see mixtape_opt_paths).
mixtape_opt_path=""

mixtape_detect_format() {
  local flac_files
  local wav_files
  local mp3_files
  local cue_files
  local flac_count
  local cue_count

  flac_files=$(find "$mixtape_opt_path" -maxdepth 1 -type f -iname '*.flac' 2>/dev/null)
  flac_count=0
  if [ -n "$flac_files" ]; then
    flac_count=$(printf '%s\n' "$flac_files" | grep -c .)
  fi

  if [ "$flac_count" -ge 1 ]; then
    cue_files=$(find "$mixtape_opt_path" -maxdepth 1 -type f -iname '*.cue' 2>/dev/null)
    cue_count=0
    if [ -n "$cue_files" ]; then
      cue_count=$(printf '%s\n' "$cue_files" | grep -c .)
    fi
    if [ "$flac_count" -eq 1 ] && [ "$cue_count" -ge 1 ]; then
      mixtape_format="flac-cue"
      mixtape_flac_file=$(printf '%s\n' "$flac_files" | head -n 1)
      mixtape_cue_file=$(printf '%s\n' "$cue_files" | head -n 1)
      return 0
    fi
    mixtape_die \
      "found $flac_count flac file(s) in '$mixtape_opt_path' but no matching single-file-plus-cue-sheet layout (exactly one .flac file with a companion .cue file is required)"
  fi

  wav_files=$(find "$mixtape_opt_path" -maxdepth 1 -type f -iname '*.wav' 2>/dev/null)
  if [ -n "$wav_files" ] && [ "$(printf '%s\n' "$wav_files" | grep -c .)" -ge 1 ]; then
    mixtape_format="wav"
    return 0
  fi

  mp3_files=$(find "$mixtape_opt_path" -maxdepth 1 -type f -iname '*.mp3' 2>/dev/null)
  if [ -n "$mp3_files" ] && [ "$(printf '%s\n' "$mp3_files" | grep -c .)" -ge 1 ]; then
    mixtape_format="mp3"
    return 0
  fi

  mixtape_die "no songs found in '$mixtape_opt_path' (expected mp3, wav, or flac files)"
}

# ---------------------------------------------------------------------------
# Track metadata extraction (P02-T01, P02-T02)
# ---------------------------------------------------------------------------

# Parallel arrays over the tracks in *discovery* order (not yet sorted).
mixtape_track_num=()
mixtape_track_title=()
mixtape_track_artist=()
mixtape_track_duration=()
mixtape_track_src=()
mixtape_track_start=()
mixtape_track_count=0

mixtape_truncate_seconds() {
  # $1: a possibly-fractional duration in seconds; prints the truncated
  # integer number of seconds.
  awk -v d="$1" 'BEGIN { printf "%d", d }'
}

mixtape_extract_tagged_files() {
  # mp3/wav mode: one track per file, tags read via ffprobe (P02-T01).
  local ext="$1"
  local list_file
  local file
  local title
  local artist
  local track_raw
  local track
  local duration
  local line
  local key
  local value

  list_file=$(mktemp)
  find "$mixtape_opt_path" -maxdepth 1 -type f -iname "*.$ext" 2>/dev/null | sort > "$list_file"

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    title=""
    artist=""
    track_raw=""
    duration=""
    while IFS= read -r line; do
      key="${line%%=*}"
      value="${line#*=}"
      case "$key" in
        "TAG:title") title="$value" ;;
        "TAG:artist") artist="$value" ;;
        "TAG:track") track_raw="$value" ;;
        "duration") duration="$value" ;;
      esac
    done < <(ffprobe -v quiet -show_entries format_tags=title,artist,track \
      -show_entries format=duration -of default=noprint_wrappers=1 "$file" 2>/dev/null)

    if [ -n "$track_raw" ]; then
      track="${track_raw%%/*}"
    else
      # No Track Number tag: leave empty so mixtape_order_tracks can decide
      # whether to fall back to alphabetical-by-filename ordering for the
      # whole album (only when every track in it lacks one).
      track=""
    fi
    [ -n "$duration" ] || mixtape_die \
      "could not read duration for '$file'"

    if [ -z "$title" ]; then
      title=$(basename "$file")
      title="${title%.*}"
    fi

    mixtape_track_num[$mixtape_track_count]="$track"
    mixtape_track_title[$mixtape_track_count]="$title"
    mixtape_track_artist[$mixtape_track_count]="$artist"
    mixtape_track_duration[$mixtape_track_count]=$(mixtape_truncate_seconds "$duration")
    mixtape_track_src[$mixtape_track_count]="$file"
    mixtape_track_start[$mixtape_track_count]=""
    mixtape_track_count=$((mixtape_track_count + 1))
  done < "$list_file"
  rm -f "$list_file"
}

mixtape_cue_ts_to_seconds() {
  # $1: a cue sheet INDEX timestamp in mm:ss:ff (frames, 75/sec).
  awk -F: -v ts="$1" 'BEGIN {
    split(ts, a, ":")
    printf "%d", (a[1] * 60) + a[2] + (a[3] / 75)
  }'
}

mixtape_extract_flac_cue() {
  # flac+cue mode: single album file, track order/title/start come from the
  # cue sheet; per-track duration is derived from consecutive INDEX 01
  # offsets, with the last track using the whole file's duration (P02-T02).
  # Artist comes from each TRACK's PERFORMER line, falling back to the
  # album-level PERFORMER line (before any TRACK) when a track has none.
  local cue_rows
  local total_duration
  local row
  local num
  local start_ts
  local title
  local artist
  local prev_num=""
  local prev_start=""
  local prev_title=""
  local prev_artist=""
  local start_sec
  local prev_start_sec
  local n

  cue_rows=$(mktemp)
  awk '
    {
      sub(/\r$/, "")
      sub(/^[ \t]+/, "")
    }
    /^PERFORMER[ \t]+"/ {
      if (cur == "" && album_performer == "") {
        t = $0
        sub(/^PERFORMER[ \t]+"/, "", t)
        sub(/"[ \t]*$/, "", t)
        album_performer = t
      } else if (cur != "" && performer == "") {
        t = $0
        sub(/^PERFORMER[ \t]+"/, "", t)
        sub(/"[ \t]*$/, "", t)
        performer = t
      }
      next
    }
    /^TRACK[ \t]+[0-9]+[ \t]+AUDIO/ {
      if (cur != "") {
        out_performer = (performer != "" ? performer : album_performer)
        print cur "\t" idx01 "\t" title "\t" out_performer
      }
      split($0, a, /[ \t]+/)
      cur = a[2] + 0
      title = ""
      idx01 = ""
      performer = ""
      next
    }
    /^TITLE[ \t]+"/ {
      if (cur != "" && title == "") {
        t = $0
        sub(/^TITLE[ \t]+"/, "", t)
        sub(/"[ \t]*$/, "", t)
        title = t
      }
      next
    }
    /^INDEX[ \t]+01[ \t]+/ {
      if (cur != "" && idx01 == "") {
        t = $0
        sub(/^INDEX[ \t]+01[ \t]+/, "", t)
        gsub(/^[ \t]+|[ \t]+$/, "", t)
        idx01 = t
      }
      next
    }
    END {
      if (cur != "") {
        out_performer = (performer != "" ? performer : album_performer)
        print cur "\t" idx01 "\t" title "\t" out_performer
      }
    }
  ' "$mixtape_cue_file" > "$cue_rows"

  [ -s "$cue_rows" ] || mixtape_die \
    "'$mixtape_cue_file' does not contain any TRACK entries"

  total_duration=$(ffprobe -v quiet -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$mixtape_flac_file" 2>/dev/null)
  [ -n "$total_duration" ] || mixtape_die \
    "could not read duration for '$mixtape_flac_file'"
  total_duration=$(mixtape_truncate_seconds "$total_duration")

  n=0
  while IFS=$'\t' read -r num start_ts title artist; do
    [ -n "$num" ] || continue
    [ -n "$start_ts" ] || mixtape_die \
      "'$mixtape_cue_file' TRACK $num has no INDEX 01 timestamp"

    if [ -n "$prev_num" ]; then
      prev_start_sec=$(mixtape_cue_ts_to_seconds "$prev_start")
      start_sec=$(mixtape_cue_ts_to_seconds "$start_ts")
      mixtape_track_num[$mixtape_track_count]="$prev_num"
      mixtape_track_title[$mixtape_track_count]="$prev_title"
      mixtape_track_artist[$mixtape_track_count]="$prev_artist"
      mixtape_track_duration[$mixtape_track_count]=$((start_sec - prev_start_sec))
      mixtape_track_src[$mixtape_track_count]="$mixtape_flac_file"
      mixtape_track_start[$mixtape_track_count]="$prev_start_sec"
      mixtape_track_count=$((mixtape_track_count + 1))
    fi

    prev_num="$num"
    prev_start="$start_ts"
    prev_title="$title"
    prev_artist="$artist"
    n=$((n + 1))
  done < "$cue_rows"

  if [ -n "$prev_num" ]; then
    prev_start_sec=$(mixtape_cue_ts_to_seconds "$prev_start")
    mixtape_track_num[$mixtape_track_count]="$prev_num"
    mixtape_track_title[$mixtape_track_count]="$prev_title"
    mixtape_track_artist[$mixtape_track_count]="$prev_artist"
    mixtape_track_duration[$mixtape_track_count]=$((total_duration - prev_start_sec))
    mixtape_track_src[$mixtape_track_count]="$mixtape_flac_file"
    mixtape_track_start[$mixtape_track_count]="$prev_start_sec"
    mixtape_track_count=$((mixtape_track_count + 1))
  fi

  rm -f "$cue_rows"
}

mixtape_extract_tracks() {
  case "$mixtape_format" in
    mp3) mixtape_extract_tagged_files "mp3" ;;
    wav) mixtape_extract_tagged_files "wav" ;;
    flac-cue) mixtape_extract_flac_cue ;;
    *) mixtape_die "internal error: unknown format '$mixtape_format'" ;;
  esac

  [ "$mixtape_track_count" -ge 1 ] || \
    mixtape_die "no songs found in '$mixtape_opt_path'"
}

# Final, Track-Number-ordered arrays used by packing, conversion, and the
# report. Populated by mixtape_order_tracks.
mixtape_seq_num=()
mixtape_seq_title=()
mixtape_seq_artist=()
mixtape_seq_duration=()
mixtape_seq_src=()
mixtape_seq_start=()
mixtape_seq_album_idx=()
mixtape_seq_count=0
mixtape_num_pad_width=2

mixtape_order_tracks() {
  local order_file
  local i
  local idx
  local num
  local prev=""
  local pad_width
  local n="$mixtape_track_count"
  local none_count=0

  i=0
  while [ "$i" -lt "$n" ]; do
    [ -n "${mixtape_track_num[$i]}" ] || none_count=$((none_count + 1))
    i=$((i + 1))
  done

  if [ "$n" -gt 0 ] && [ "$none_count" -eq "$n" ]; then
    # No track in this album has Track Number metadata: fall back to
    # alphabetical-by-filename order. Tracks were discovered via a sorted
    # `find` listing, so discovery order (index order here) already is
    # alphabetical-by-filename order; just copy it through unchanged.
    mixtape_log "No Track Number metadata found in '$mixtape_opt_path'; ordering tracks alphabetically by filename instead"
    i=0
    while [ "$i" -lt "$n" ]; do
      mixtape_seq_num[$mixtape_seq_count]="${mixtape_track_num[$i]}"
      mixtape_seq_title[$mixtape_seq_count]="${mixtape_track_title[$i]}"
      mixtape_seq_artist[$mixtape_seq_count]="${mixtape_track_artist[$i]}"
      mixtape_seq_duration[$mixtape_seq_count]="${mixtape_track_duration[$i]}"
      mixtape_seq_src[$mixtape_seq_count]="${mixtape_track_src[$i]}"
      mixtape_seq_start[$mixtape_seq_count]="${mixtape_track_start[$i]}"
      mixtape_seq_count=$((mixtape_seq_count + 1))
      i=$((i + 1))
    done
  elif [ "$none_count" -gt 0 ]; then
    mixtape_die \
      "'$mixtape_opt_path' has Track Number metadata on some tracks but not others; add Track Number tags to every track or remove them from every track"
  else
    order_file=$(mktemp)
    i=0
    while [ "$i" -lt "$n" ]; do
      printf '%s %s\n' "${mixtape_track_num[$i]}" "$i" >> "$order_file"
      i=$((i + 1))
    done

    sort -n -k1,1 "$order_file" > "${order_file}.sorted"

    while IFS=' ' read -r num idx; do
      [ -n "$num" ] || continue
      if [ "$num" = "$prev" ]; then
        mixtape_die "duplicate Track Number '$num' found while scanning '$mixtape_opt_path'"
      fi
      prev="$num"
      mixtape_seq_num[$mixtape_seq_count]="${mixtape_track_num[$idx]}"
      mixtape_seq_title[$mixtape_seq_count]="${mixtape_track_title[$idx]}"
      mixtape_seq_artist[$mixtape_seq_count]="${mixtape_track_artist[$idx]}"
      mixtape_seq_duration[$mixtape_seq_count]="${mixtape_track_duration[$idx]}"
      mixtape_seq_src[$mixtape_seq_count]="${mixtape_track_src[$idx]}"
      mixtape_seq_start[$mixtape_seq_count]="${mixtape_track_start[$idx]}"
      mixtape_seq_count=$((mixtape_seq_count + 1))
    done < "${order_file}.sorted"

    rm -f "$order_file" "${order_file}.sorted"
  fi

  pad_width=${#mixtape_seq_count}
  [ "$pad_width" -ge 2 ] || pad_width=2
  mixtape_num_pad_width="$pad_width"
}

mixtape_reset_track_arrays() {
  mixtape_track_num=()
  mixtape_track_title=()
  mixtape_track_artist=()
  mixtape_track_duration=()
  mixtape_track_src=()
  mixtape_track_start=()
  mixtape_track_count=0
}

# Supported cover-art image extensions, checked in this order for cover.*
# and front.* (case-insensitive), and used to collect the candidate list
# for the "exactly one image file" fallback.
MIXTAPE_COVER_IMAGE_EXTS="jpg jpeg png gif bmp webp tif tiff"

mixtape_album_cover_src=()

mixtape_find_cover_image() {
  # Prints the path to the chosen cover image for $mixtape_opt_path (the
  # album currently being scanned), or nothing if none qualifies. Priority:
  # a file named cover.<ext>, then front.<ext> (either case-insensitive),
  # then - only if neither exists - the single remaining image file, when
  # exactly one is present in the album directory.
  local ext
  local match
  local list_file
  local count

  for ext in $MIXTAPE_COVER_IMAGE_EXTS; do
    match=$(find "$mixtape_opt_path" -maxdepth 1 -type f -iname "cover.$ext" 2>/dev/null | head -n 1)
    if [ -n "$match" ]; then
      printf '%s' "$match"
      return 0
    fi
  done

  for ext in $MIXTAPE_COVER_IMAGE_EXTS; do
    match=$(find "$mixtape_opt_path" -maxdepth 1 -type f -iname "front.$ext" 2>/dev/null | head -n 1)
    if [ -n "$match" ]; then
      printf '%s' "$match"
      return 0
    fi
  done

  list_file=$(mktemp)
  : > "$list_file"
  for ext in $MIXTAPE_COVER_IMAGE_EXTS; do
    find "$mixtape_opt_path" -maxdepth 1 -type f -iname "*.$ext" 2>/dev/null >> "$list_file"
  done
  count=$(wc -l < "$list_file" | tr -d ' ')
  if [ "$count" -eq 1 ]; then
    match=$(cat "$list_file")
  else
    match=""
  fi
  rm -f "$list_file"

  [ -n "$match" ] && printf '%s' "$match"
  return 0
}

mixtape_process_albums() {
  # Scans every --path album in the order given, extracting and ordering
  # each album's own tracks (Track Number duplicates are only checked
  # within a single album) and appending the result to the combined,
  # cross-album mixtape_seq_* sequence used by everything downstream.
  local total="${#mixtape_opt_paths[@]}"
  local i=0
  local n
  local album_start
  local cover
  local seq_start_idx
  local k

  for mixtape_opt_path in "${mixtape_opt_paths[@]}"; do
    i=$((i + 1))
    album_start="$SECONDS"
    mixtape_log "Scanning album $i/$total: $mixtape_opt_path"
    mixtape_reset_track_arrays
    mixtape_detect_format
    mixtape_log "Detected format for '$mixtape_opt_path': $mixtape_format"
    mixtape_extract_tracks
    n="$mixtape_track_count"
    seq_start_idx="$mixtape_seq_count"
    mixtape_order_tracks
    # Tag every seq entry just added for this album with the album's
    # 0-based --path position, so --fit-to-side can detect album
    # boundaries in the combined cross-album sequence.
    k="$seq_start_idx"
    while [ "$k" -lt "$mixtape_seq_count" ]; do
      mixtape_seq_album_idx[$k]=$((i - 1))
      k=$((k + 1))
    done
    mixtape_log "Extracted and ordered $n track(s) from '$mixtape_opt_path' in $((SECONDS - album_start))s"

    cover=$(mixtape_find_cover_image)
    mixtape_album_cover_src[$((i - 1))]="$cover"
    if [ -n "$cover" ]; then
      mixtape_log "Found cover art for album $i/$total: '$cover'"
    fi
  done
}

# ---------------------------------------------------------------------------
# Capacity validation and side/tape packing (P03-T01, P03-T02)
# ---------------------------------------------------------------------------

mixtape_slot_tracks=()
mixtape_slot_duration=()
mixtape_slot_capacity=()
mixtape_slot_count=0

mixtape_validate_capacity() {
  local i

  mixtape_log "Validating total capacity against the requested --length list..."
  local length
  local side_cap
  local total_capacity=0
  local total_duration=0
  local max_side_cap=0

  i=0
  while [ "$i" -lt "$mixtape_tape_count" ]; do
    length="${mixtape_tape_lengths[$i]}"
    side_cap=$(((length / 2) * 60))
    total_capacity=$((total_capacity + length * 60))
    if [ "$side_cap" -gt "$max_side_cap" ]; then
      max_side_cap="$side_cap"
    fi
    i=$((i + 1))
  done

  i=0
  while [ "$i" -lt "$mixtape_seq_count" ]; do
    if [ "${mixtape_seq_duration[$i]}" -gt "$max_side_cap" ]; then
      mixtape_die \
        "track '${mixtape_seq_title[$i]}' is longer than the longest available tape side ($((max_side_cap / 60)) minutes); choose a longer --length value or remove this track"
    fi
    total_duration=$((total_duration + mixtape_seq_duration[i]))
    i=$((i + 1))
  done

  if [ "$total_duration" -gt "$total_capacity" ]; then
    if [ "${#mixtape_opt_paths[@]}" -gt 1 ]; then
      mixtape_die \
        "the combined duration of the ${#mixtape_opt_paths[@]} albums ($(mixtape_format_hhmmss "$total_duration")) exceeds the requested tape capacity ($(mixtape_format_hhmmss "$total_capacity")); add another tape, choose a longer --length value, use fewer albums, or use fewer tracks"
    fi
    mixtape_die \
      "the album's total duration ($(mixtape_format_hhmmss "$total_duration")) exceeds the requested tape capacity ($(mixtape_format_hhmmss "$total_capacity")); add another tape, choose a longer --length value, or use fewer tracks"
  fi
}

mixtape_pack_tracks() {
  local i
  local length
  local side_cap

  mixtape_log "Packing $mixtape_seq_count track(s) onto $((mixtape_tape_count * 2)) tape side(s)..."

  mixtape_slot_count=$((mixtape_tape_count * 2))
  i=0
  while [ "$i" -lt "$mixtape_tape_count" ]; do
    length="${mixtape_tape_lengths[$i]}"
    side_cap=$(((length / 2) * 60))
    mixtape_slot_capacity[$((i * 2))]="$side_cap"
    mixtape_slot_capacity[$((i * 2 + 1))]="$side_cap"
    i=$((i + 1))
  done

  if [ "$mixtape_opt_fit_to_side" -eq 1 ] && [ "${#mixtape_opt_paths[@]}" -gt 1 ]; then
    if mixtape_pack_fit_to_side; then
      mixtape_log "Packed with --fit-to-side: each album starts on its own tape side"
      return 0
    fi
    mixtape_log "Warning: --fit-to-side could not place every album onto its own tape side with the current --length (${#mixtape_opt_paths[@]} albums across $mixtape_tape_count tape(s)); falling back to normal packing, where a tape side may contain tracks from more than one album. Recommendation: add another tape, choose a longer --length value, or reorder --path so consecutive albums' durations pair up more evenly per side."
  fi

  mixtape_pack_normal
}

# Default packing: fills tape sides in order, moving to the next side only
# when a track no longer fits, with no regard for album boundaries (a side
# may end up containing the tail of one album and the head of the next).
mixtape_pack_normal() {
  local j=0
  local dur
  local slot=0
  local i

  i=0
  while [ "$i" -lt "$mixtape_slot_count" ]; do
    mixtape_slot_tracks[$i]=""
    mixtape_slot_duration[$i]=0
    i=$((i + 1))
  done

  while [ "$j" -lt "$mixtape_seq_count" ]; do
    dur="${mixtape_seq_duration[$j]}"
    while [ "$slot" -lt "$mixtape_slot_count" ] && \
      [ "$((mixtape_slot_duration[slot] + dur))" -gt "${mixtape_slot_capacity[$slot]}" ]; do
      slot=$((slot + 1))
    done
    [ "$slot" -lt "$mixtape_slot_count" ] || mixtape_die \
      "internal error: no tape side available for track '${mixtape_seq_title[$j]}' (this should have been caught by capacity validation)"
    mixtape_slot_tracks[$slot]="${mixtape_slot_tracks[$slot]}$j "
    mixtape_slot_duration[$slot]=$((mixtape_slot_duration[slot] + dur))
    j=$((j + 1))
  done
}

# --fit-to-side packing attempt: like mixtape_pack_normal, but whenever a
# track belongs to a different album than the previous track, and the
# current side already holds anything, packing jumps ahead to the next
# side first. This guarantees no side ever mixes tracks from two albums.
# A single album's own tracks may still span multiple sides as normal, if
# the album itself is longer than one side.
#
# Returns 0 and leaves the packed result in mixtape_slot_tracks/duration on
# success, or returns 1 (with slot state undefined/partial) if the forced
# album/side alignment runs out of tape sides. The caller must fall back to
# mixtape_pack_normal in that case.
mixtape_pack_fit_to_side() {
  local j=0
  local dur
  local album_idx
  local prev_album=""
  local slot=0
  local i

  i=0
  while [ "$i" -lt "$mixtape_slot_count" ]; do
    mixtape_slot_tracks[$i]=""
    mixtape_slot_duration[$i]=0
    i=$((i + 1))
  done

  while [ "$j" -lt "$mixtape_seq_count" ]; do
    dur="${mixtape_seq_duration[$j]}"
    album_idx="${mixtape_seq_album_idx[$j]}"

    if [ -n "$prev_album" ] && [ "$album_idx" != "$prev_album" ] && \
      [ "${mixtape_slot_duration[$slot]:-0}" -gt 0 ]; then
      slot=$((slot + 1))
    fi

    while [ "$slot" -lt "$mixtape_slot_count" ] && \
      [ "$((mixtape_slot_duration[slot] + dur))" -gt "${mixtape_slot_capacity[$slot]}" ]; do
      slot=$((slot + 1))
    done

    [ "$slot" -lt "$mixtape_slot_count" ] || return 1

    mixtape_slot_tracks[$slot]="${mixtape_slot_tracks[$slot]}$j "
    mixtape_slot_duration[$slot]=$((mixtape_slot_duration[slot] + dur))
    prev_album="$album_idx"
    j=$((j + 1))
  done

  return 0
}

# ---------------------------------------------------------------------------
# Duration formatting helpers
# ---------------------------------------------------------------------------

mixtape_format_hhmmss() {
  local sec="$1"
  printf '%02d:%02d:%02d' $((sec / 3600)) $(((sec % 3600) / 60)) $((sec % 60))
}

mixtape_format_mss() {
  local sec="$1"
  printf '%d:%02d' $((sec / 60)) $((sec % 60))
}

# ---------------------------------------------------------------------------
# WAV conversion and per-side .m3u playlists (P04-T01, P04-T02)
# ---------------------------------------------------------------------------

mixtape_seq_wavname=()

mixtape_convert_to_wav() {
  local j
  local seq_pos
  local title
  local wavname
  local src
  local start
  local dur
  local out_path
  local track_start

  mixtape_log "Converting $mixtape_seq_count track(s) to lossless WAV under '$mixtape_opt_dest'..."

  j=0
  while [ "$j" -lt "$mixtape_seq_count" ]; do
    seq_pos=$((j + 1))
    title="${mixtape_seq_title[$j]}"
    # Named by combined-sequence position (not the track's own Track Number
    # tag) so filenames stay unique across multiple --path albums, even
    # when albums restart their own Track Number at 1.
    wavname=$(printf '%0'"$mixtape_num_pad_width"'d.wav' "$seq_pos")
    mixtape_seq_wavname[$j]="$wavname"
    out_path="$mixtape_opt_dest/$wavname"
    src="${mixtape_seq_src[$j]}"
    start="${mixtape_seq_start[$j]}"

    mixtape_log "Converting track $seq_pos/$mixtape_seq_count: '$title' -> '$wavname'..."
    track_start="$SECONDS"

    if [ -n "$start" ]; then
      dur="${mixtape_seq_duration[$j]}"
      ffmpeg -y -v error -i "$src" -ss "$start" -t "$dur" -c:a pcm_s16le "$out_path" || \
        mixtape_die "failed to convert track '$title' from '$src' to WAV"
    else
      ffmpeg -y -v error -i "$src" -c:a pcm_s16le "$out_path" || \
        mixtape_die "failed to convert track '$title' from '$src' to WAV"
    fi

    mixtape_log "Converted track $seq_pos/$mixtape_seq_count: '$title' in $((SECONDS - track_start))s"

    if [ "$mixtape_opt_normalize" -eq 1 ]; then
      mixtape_normalize_wav "$out_path" "$title"
    fi

    j=$((j + 1))
  done
}

# Normalizes one WAV file in place so its perceived loudness matches a
# fixed target across every track and album in the run: removes any DC
# offset, then runs ffmpeg's `loudnorm` filter as a proper two-pass EBU
# R128 loudness normalization (measure, then apply using the measured
# values) targeting MIXTAPE_NORMALIZE_TARGET_LUFS while keeping the true
# peak at or under MIXTAPE_NORMALIZE_PEAK_CEILING_DB.
#
# A single flat gain cannot always satisfy both the loudness target and
# the peak ceiling at once: a track with a few hot moments but an
# otherwise quiet, dynamic body would need its *entire* gain held back
# just to tame those few peaks, leaving it quieter overall than a more
# consistently loud track normalized the same way - which is exactly what
# produced uneven-sounding tracks within the same album previously.
# `loudnorm`'s two-pass mode avoids this by only reining in the moments
# that actually approach the ceiling (falling back to a plain gain when a
# track's dynamics allow it), so most tracks land within a fraction of a
# dB of the target regardless of how peaky or how dynamic they are.
#
# All numeric parsing/formatting is forced to the "C" locale so the
# decimal point ffmpeg expects is never replaced by a locale-specific
# decimal comma.
mixtape_normalize_wav() {
  local wav="$1"
  local title="$2"
  local tmp="${wav}.normalize.tmp.wav"
  local dc_offset
  local shift_val
  local measured_json
  local measured_i
  local measured_tp
  local measured_lra
  local measured_thresh
  local measured_offset
  local loudnorm_args
  local normalize_start="$SECONDS"

  dc_offset=$(LC_ALL=C ffmpeg -i "$wav" -af astats=measure_perchannel=0:metadata=0 -f null - 2>&1 \
    | awk '/\] Overall$/{o=1} o && /DC offset:/{print $NF; exit}')
  [ -n "$dc_offset" ] || dc_offset="0"
  shift_val=$(LC_ALL=C awk -v d="$dc_offset" 'BEGIN { printf "%.6f", -d }')

  LC_ALL=C ffmpeg -y -v error -i "$wav" -af "dcshift=shift=$shift_val" -c:a pcm_s16le "$tmp" || \
    mixtape_die "failed to remove DC offset while normalizing '$title'"

  loudnorm_args="I=${MIXTAPE_NORMALIZE_TARGET_LUFS}:TP=${MIXTAPE_NORMALIZE_PEAK_CEILING_DB}:LRA=${MIXTAPE_NORMALIZE_LRA}"

  measured_json=$(LC_ALL=C ffmpeg -i "$tmp" -af "loudnorm=${loudnorm_args}:print_format=json" -f null - 2>&1)
  measured_i=$(printf '%s' "$measured_json" | awk -F'"' '/"input_i"/{print $4; exit}')
  measured_tp=$(printf '%s' "$measured_json" | awk -F'"' '/"input_tp"/{print $4; exit}')
  measured_lra=$(printf '%s' "$measured_json" | awk -F'"' '/"input_lra"/{print $4; exit}')
  measured_thresh=$(printf '%s' "$measured_json" | awk -F'"' '/"input_thresh"/{print $4; exit}')
  measured_offset=$(printf '%s' "$measured_json" | awk -F'"' '/"target_offset"/{print $4; exit}')

  case "$measured_i" in
    ''|*inf*|*nan*|*-nan*|*-NaN*)
      mv -f "$tmp" "$wav" || \
        mixtape_die "failed to finalize DC-offset removal while normalizing '$title'"
      mixtape_log "Normalized '$title': removed DC offset $dc_offset; loudness unavailable (silent track), gain skipped (in $((SECONDS - normalize_start))s)"
      return 0
      ;;
  esac

  LC_ALL=C ffmpeg -y -v error -i "$tmp" \
    -af "loudnorm=${loudnorm_args}:measured_I=${measured_i}:measured_TP=${measured_tp}:measured_LRA=${measured_lra}:measured_thresh=${measured_thresh}:offset=${measured_offset}:print_format=summary" \
    -c:a pcm_s16le "$wav" || \
    mixtape_die "failed to apply normalization to '$title'"

  rm -f "$tmp"
  mixtape_log "Normalized '$title': removed DC offset $dc_offset, applied loudness normalization (was ${measured_i} LUFS / ${measured_tp}dBTP true peak; target ${MIXTAPE_NORMALIZE_TARGET_LUFS} LUFS / ${MIXTAPE_NORMALIZE_PEAK_CEILING_DB}dBTP ceiling) in $((SECONDS - normalize_start))s"
}

mixtape_track_label() {
  # Report ("mixtape.txt") label: artist is only shown when
  # --include-artist-name is set.
  local idx="$1"
  local title="${mixtape_seq_title[$idx]}"
  local artist="${mixtape_seq_artist[$idx]:-}"

  if [ "$mixtape_opt_include_artist_name" -eq 1 ] && [ -n "$artist" ]; then
    printf '%s - %s' "$artist" "$title"
  else
    printf '%s' "$title"
  fi
}

mixtape_track_label_m3u() {
  # .m3u #EXTINF label: artist is shown whenever metadata provides one,
  # independent of --include-artist-name.
  local idx="$1"
  local title="${mixtape_seq_title[$idx]}"
  local artist="${mixtape_seq_artist[$idx]:-}"

  if [ -n "$artist" ]; then
    printf '%s - %s' "$artist" "$title"
  else
    printf '%s' "$title"
  fi
}

mixtape_write_playlists() {
  local slot
  local tape
  local side_letter
  local playlist
  local indices
  local idx

  mixtape_log "Writing .m3u playlists for $mixtape_slot_count tape side(s)..."

  slot=0
  while [ "$slot" -lt "$mixtape_slot_count" ]; do
    indices="${mixtape_slot_tracks[$slot]}"
    if [ -n "$indices" ]; then
      tape=$((slot / 2 + 1))
      if [ "$((slot % 2))" -eq 0 ]; then
        side_letter="a"
      else
        side_letter="b"
      fi
      playlist=$(printf '%s/tape-%02d-side-%s.m3u' "$mixtape_opt_dest" "$tape" "$side_letter")
      printf '#EXTM3U\n' > "$playlist"
      for idx in $indices; do
        printf '#EXTINF:%d,%s\n' \
          "${mixtape_seq_duration[$idx]}" \
          "$(mixtape_track_label_m3u "$idx")" >> "$playlist"
        printf '%s\n' "${mixtape_seq_wavname[$idx]}" >> "$playlist"
      done
    fi
    slot=$((slot + 1))
  done
}

# ---------------------------------------------------------------------------
# mixtape.txt report rendering (P05-T01)
# ---------------------------------------------------------------------------

mixtape_render_report() {
  local report_path="$mixtape_opt_dest/mixtape.txt"
  local tape
  local side_a
  local side_b
  local tape_duration
  local indices
  local idx
  local i
  local last_used_tape=-1

  mixtape_log "Rendering report to '$report_path'..."

  : > "$report_path"

  # Find the last tape index (0-based) that actually has at least one track
  # on either side, so tapes with nothing left to record onto (e.g. trailing
  # requested --length values beyond what the tracks fill) are omitted from
  # the report entirely instead of being printed as empty.
  i=0
  while [ "$i" -lt "$mixtape_tape_count" ]; do
    side_a=$((i * 2))
    side_b=$((i * 2 + 1))
    if [ -n "${mixtape_slot_tracks[$side_a]}" ] || [ -n "${mixtape_slot_tracks[$side_b]}" ]; then
      last_used_tape="$i"
    fi
    i=$((i + 1))
  done

  i=0
  while [ "$i" -lt "$mixtape_tape_count" ]; do
    side_a=$((i * 2))
    side_b=$((i * 2 + 1))

    if [ -z "${mixtape_slot_tracks[$side_a]}" ] && [ -z "${mixtape_slot_tracks[$side_b]}" ]; then
      i=$((i + 1))
      continue
    fi

    tape=$((i + 1))
    tape_duration=$((mixtape_slot_duration[side_a] + mixtape_slot_duration[side_b]))

    {
      printf 'Tape %d\n' "$tape"
      printf 'Length: %s\n' "${mixtape_tape_lengths[$i]}"
      printf 'Duration: %s\n' "$(mixtape_format_hhmmss "$tape_duration")"
      printf 'Sides: %s/%s\n' \
        "$(mixtape_format_hhmmss "${mixtape_slot_duration[$side_a]}")" \
        "$(mixtape_format_hhmmss "${mixtape_slot_duration[$side_b]}")"
      printf '\n'
      printf 'Side A\n'
      indices="${mixtape_slot_tracks[$side_a]}"
      for idx in $indices; do
        # Numbered by position in the combined cross-album sequence (not the
        # track's own per-album Track Number tag), so numbering stays in
        # strictly increasing mathematical order across multiple albums.
        printf '%0'"$mixtape_num_pad_width"'d. %s. %s\n' \
          "$((idx + 1))" \
          "$(mixtape_format_mss "${mixtape_seq_duration[$idx]}")" \
          "$(mixtape_track_label "$idx")"
      done
      printf '\n'
      printf 'Side B\n'
      indices="${mixtape_slot_tracks[$side_b]}"
      for idx in $indices; do
        printf '%0'"$mixtape_num_pad_width"'d. %s. %s\n' \
          "$((idx + 1))" \
          "$(mixtape_format_mss "${mixtape_seq_duration[$idx]}")" \
          "$(mixtape_track_label "$idx")"
      done
      if [ "$i" -lt "$last_used_tape" ]; then
        printf '\n'
      fi
    } >> "$report_path"

    i=$((i + 1))
  done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

mixtape_prepare_destination() {
  # Refuse a handful of literal --dest values that would make clearing it
  # catastrophic (filesystem root, current/parent directory, or empty),
  # since --dest is about to be wiped and recreated wholesale.
  case "$mixtape_opt_dest" in
    ''|/|.|..)
      mixtape_die "refusing to use '$mixtape_opt_dest' as --dest: too dangerous to remove"
      ;;
  esac

  if [ -d "$mixtape_opt_dest" ]; then
    # Clear the directory's contents rather than removing the directory
    # itself: --dest may be a bind-mounted path (e.g. under Docker), where
    # the mount point itself cannot be removed even though its contents can.
    mixtape_log "Clearing existing destination directory '$mixtape_opt_dest'..."
    find "$mixtape_opt_dest" -mindepth 1 -exec rm -rf {} + || \
      mixtape_die "could not clear existing destination directory '$mixtape_opt_dest'"
  elif [ -e "$mixtape_opt_dest" ]; then
    mixtape_log "Removing existing file at destination path '$mixtape_opt_dest'..."
    rm -f -- "$mixtape_opt_dest" || \
      mixtape_die "could not remove existing file at destination path '$mixtape_opt_dest'"
  fi

  mixtape_log "Creating destination directory '$mixtape_opt_dest'..."
  mkdir -p -- "$mixtape_opt_dest" || \
    mixtape_die "could not create destination directory '$mixtape_opt_dest'"
}

mixtape_copy_covers() {
  # Copies each album's detected cover image (see mixtape_find_cover_image)
  # into --dest as cover-NN.<ext>, NN being that album's 1-based position
  # among --path arguments (matching the order given), padded to at least
  # 2 digits. Albums with no qualifying cover image are silently skipped.
  local total="${#mixtape_opt_paths[@]}"
  local pad_width=${#total}
  local i=0
  local src
  local ext
  local dest_name

  [ "$pad_width" -ge 2 ] || pad_width=2

  while [ "$i" -lt "$total" ]; do
    src="${mixtape_album_cover_src[$i]:-}"
    if [ -n "$src" ]; then
      ext="${src##*.}"
      dest_name=$(printf 'cover-%0'"$pad_width"'d.%s' "$((i + 1))" "$ext")
      mixtape_log "Copying cover art for album $((i + 1))/$total: '$src' -> '$dest_name'"
      cp -- "$src" "$mixtape_opt_dest/$dest_name" || \
        mixtape_die "could not copy cover art '$src' to '$mixtape_opt_dest/$dest_name'"
    fi
    i=$((i + 1))
  done
}

mixtape_main() {
  local mixtape_total_start="$SECONDS"

  mixtape_parse_args "$@"
  mixtape_run_stage "dependency check" mixtape_check_dependencies
  mixtape_run_stage "path validation" mixtape_validate_paths
  mixtape_run_stage "length validation" mixtape_validate_length_list
  mixtape_run_stage "album scanning" mixtape_process_albums
  mixtape_run_stage "capacity validation" mixtape_validate_capacity
  mixtape_run_stage "tape/side packing" mixtape_pack_tracks
  mixtape_run_stage "destination setup" mixtape_prepare_destination

  if [ "$mixtape_opt_dry_run" -eq 1 ]; then
    mixtape_log "Dry-run mode: skipping cover art copying, WAV conversion, and playlist writing"
  else
    mixtape_run_stage "cover art copying" mixtape_copy_covers
    mixtape_run_stage "WAV conversion" mixtape_convert_to_wav
    mixtape_run_stage "playlist writing" mixtape_write_playlists
  fi

  mixtape_run_stage "report rendering" mixtape_render_report
  mixtape_log "Done."
  mixtape_log "Total execution time: $((SECONDS - mixtape_total_start))s"

  if [ "$mixtape_opt_dry_run" -eq 1 ]; then
    printf 'mixtape.sh: (dry run) wrote %d tape(s) for %d track(s) from %d album(s) to %s (mixtape.txt only)\n' \
      "$mixtape_tape_count" "$mixtape_seq_count" "${#mixtape_opt_paths[@]}" "$mixtape_opt_dest"
  else
    printf 'mixtape.sh: wrote %d tape(s) for %d track(s) from %d album(s) to %s\n' \
      "$mixtape_tape_count" "$mixtape_seq_count" "${#mixtape_opt_paths[@]}" "$mixtape_opt_dest"
  fi
  exit 0
}

mixtape_main "$@"
