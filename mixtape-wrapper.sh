#!/usr/bin/env bash
#
# mixtape-wrapper.sh - Cross-platform wrapper that runs the mixtape.sh
# Docker image while imitating the native mixtape.sh command-line
# interface exactly.
#
# All actual work (metadata reading, packing, WAV conversion, playlist and
# report writing) is delegated to the "afrunt/mixtape" Docker image; this
# script's only job is to translate --path/--dest host directories into
# Docker bind mounts (in a way that works unmodified on Linux, macOS, and
# Windows via Git Bash/MSYS2 or WSL) and forward every other flag through
# untouched.
#
# Usage (identical to mixtape.sh itself):
#   mixtape-wrapper.sh --path <album-dir> [--path <album-dir> ...]
#                       [--length <list>] [--dest <dir>]
#                       [--include-artist-name] [--dry-run]
#                       [--normalize] [--fit-to-side]
#   mixtape-wrapper.sh --help
#
# Every option means exactly what it means for mixtape.sh; see mixtape.sh's
# own header comment or README.md for the full description of each flag.
# --path and --dest values are host paths, exactly as you'd pass them to
# the native script - this wrapper takes care of mounting them into the
# container and rewriting them to the corresponding in-container paths.
#
# Configuration (environment variables, not CLI flags, so the CLI surface
# stays identical to mixtape.sh):
#   MIXTAPE_DOCKER_IMAGE   Docker image to run. Default: afrunt/mixtape
#
# Requirements:
#   * Docker (Docker Desktop on macOS/Windows, or the Docker Engine on
#     Linux), reachable as `docker` on PATH.
#   * A bash capable of running this script: the system bash on Linux and
#     macOS, or Git Bash/MSYS2 or WSL bash on Windows.
#
# Exit codes:
#   0   Success (or whatever the container's mixtape.sh returns).
#   1   A wrapper-level error occurred (see the printed message) before
#       the container was even started.
#
# All output and error messages are US technical English.

set -u

readonly MIXTAPE_WRAPPER_DEFAULT_IMAGE="afrunt/mixtape"

mixwrap_err() {
  printf 'mixtape-wrapper.sh: error: %s\n' "$*" >&2
}

mixwrap_die() {
  mixwrap_err "$*"
  exit 1
}

# Resolves an existing directory (or an existing file's parent directory)
# to an absolute POSIX-style path, without depending on GNU coreutils'
# `realpath`/`readlink -f` (not guaranteed present on macOS's stock bash).
mixwrap_abspath() {
  local target="$1"
  if [ -d "$target" ]; then
    (cd "$target" 2>/dev/null && pwd)
    return
  fi
  local parent
  parent=$(dirname -- "$target")
  local base
  base=$(basename -- "$target")
  if [ -d "$parent" ]; then
    printf '%s/%s\n' "$(cd "$parent" && pwd)" "$base"
    return
  fi
  printf '%s\n' "$target"
}

# Detects Git Bash/MSYS2/Cygwin, where Docker Desktop for Windows expects
# host bind-mount paths in "C:/Users/..." form rather than the POSIX-style
# "/c/Users/..." form bash itself works with, and where MSYS's own
# automatic path conversion would otherwise mangle the *container-side*
# half of a "-v host:container" argument. `cygpath` (bundled with both Git
# Bash and Cygwin) does this conversion for us; native Linux/macOS bash
# never has it, so its absence there is the normal case, not an error.
mixwrap_is_windows_bash() {
  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

# Converts an absolute POSIX host path into whatever form `docker run -v`
# needs on the current platform.
mixwrap_docker_hostpath() {
  local path="$1"
  if mixwrap_is_windows_bash && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$path"
  else
    printf '%s\n' "$path"
  fi
}

mixwrap_print_help_note() {
  cat >&2 <<'EOF'
mixtape-wrapper.sh: no --path given; delegating straight to the
afrunt/mixtape image so it can print its own usage/help or its own
argument error, without needing any volume mounts.
EOF
}

mixtape_wrapper_main() {
  if ! command -v docker >/dev/null 2>&1; then
    mixwrap_die "docker is required but was not found on PATH. Install Docker Desktop (macOS/Windows) or Docker Engine (Linux) first: https://docs.docker.com/get-docker/"
  fi

  local image="${MIXTAPE_DOCKER_IMAGE:-$MIXTAPE_WRAPPER_DEFAULT_IMAGE}"

  # First pass: does this invocation include --path at all? --help, -h, or
  # a missing/invalid invocation need no mounts whatsoever - just forward
  # every argument as-is and let the container's own mixtape.sh handle it
  # (including printing its own error/help text).
  local has_path=0
  local scan_arg
  for scan_arg in "$@"; do
    case "$scan_arg" in
      --path | --path=*) has_path=1 ;;
    esac
  done

  local -a docker_mount_args=()
  local -a container_args=()

  if [ "$has_path" -eq 0 ]; then
    mixwrap_print_help_note
    container_args=("$@")
  else
    local album_index=0
    local dest_host=""
    local dest_given=0

    while [ $# -gt 0 ]; do
      case "$1" in
        --path)
          [ $# -ge 2 ] || mixwrap_die "--path requires a value"
          mixtape_wrapper_add_album_mount "$2"
          shift 2
          ;;
        --path=*)
          mixtape_wrapper_add_album_mount "${1#--path=}"
          shift
          ;;
        --dest)
          [ $# -ge 2 ] || mixwrap_die "--dest requires a value"
          dest_host="$2"
          dest_given=1
          shift 2
          ;;
        --dest=*)
          dest_host="${1#--dest=}"
          dest_given=1
          shift
          ;;
        *)
          container_args+=("$1")
          shift
          ;;
      esac
    done

    if [ "$dest_given" -eq 0 ]; then
      dest_host="./mixtape"
    fi
    mkdir -p -- "$dest_host" || mixwrap_die "could not create --dest directory '$dest_host'"
    local dest_abs
    dest_abs=$(mixwrap_abspath "$dest_host")
    docker_mount_args+=(-v "$(mixwrap_docker_hostpath "$dest_abs"):/out")
    container_args+=(--dest /out)
  fi

  local -a tty_args=()
  [ -t 0 ] && tty_args+=(-i)
  [ -t 1 ] && tty_args+=(-t)

  # Under `set -u`, bash 3.2 (the macOS default) treats "${arr[@]}" on an
  # empty array as an unbound-variable error rather than expanding to
  # nothing; the "${arr[@]+"${arr[@]}"}" idiom sidesteps that everywhere.
  docker run --rm \
    ${tty_args[@]+"${tty_args[@]}"} \
    ${docker_mount_args[@]+"${docker_mount_args[@]}"} \
    "$image" \
    ${container_args[@]+"${container_args[@]}"}
}

# Adds a "-v <host>:<container>:ro" mount for one --path album directory
# and appends the rewritten "--path <container-dir>" to container_args.
# Uses the (bash-array) variables set up by the caller; kept as a separate
# function only for readability, not for reuse elsewhere.
mixtape_wrapper_add_album_mount() {
  local host_path="$1"
  [ -d "$host_path" ] || mixwrap_die "--path '$host_path' is not an existing directory"
  local host_abs
  host_abs=$(mixwrap_abspath "$host_path")
  local container_dir="/albums/album-$album_index"
  docker_mount_args+=(-v "$(mixwrap_docker_hostpath "$host_abs"):${container_dir}:ro")
  container_args+=(--path "$container_dir")
  album_index=$((album_index + 1))
}

mixtape_wrapper_main "$@"
