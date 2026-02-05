#!/usr/bin/env bash
# ab.sh - Concatenate audio files → .m4b with chapters, splitting at 12h max,
#         showing real-time encode progress via FFmpeg and embedding metadata+chapters
# Supports --dry-run mode and validation of input files
# Usage: ab.sh [OPTIONS] <source_dir>
# Requirements: bash, ffprobe, ffmpeg (with libfdk_aac)

VERSION="1.0.0"
SCRIPT_NAME=$(basename "$0")

set -euo pipefail

MAX_DURATION=$((12 * 3600))  # 12 h max per part
DRY_RUN=0
YES_MODE=0
VALIDATE_ONLY=0
VERBOSE=0
QUIET=0
SELF_TEST=0
REM_ARGS=()
TERM_WIDTH=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}

# --- Color codes for output ---
if [[ -t 2 ]]; then
  # stderr is a terminal, enable colors
  C_RESET='\033[0m'
  C_BOLD='\033[1m'
  C_DIM='\033[2m'
  C_RED='\033[31m'
  C_GREEN='\033[32m'
  C_YELLOW='\033[33m'
  C_BLUE='\033[34m'
  C_MAGENTA='\033[35m'
  C_CYAN='\033[36m'
else
  # Not a terminal, disable colors
  C_RESET=''
  C_BOLD=''
  C_DIM=''
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_BLUE=''
  C_MAGENTA=''
  C_CYAN=''
fi

# --- Error handling helpers ---
_die() {
  echo -e "${C_RED}Error: $*${C_RESET}" >&2
  exit "${2:-1}"
}

_warn() {
  (( QUIET )) && return 0
  echo -e "${C_YELLOW}Warning: $*${C_RESET}" >&2
}

_info() {
  (( QUIET )) && return 0
  echo -e "${C_CYAN}$*${C_RESET}" >&2
}

_log() {
  (( QUIET )) && return 0
  echo -e "$*" >&2
}

_vlog() {
  (( QUIET )) && return 0
  (( VERBOSE )) || return 0
  echo -e "$*" >&2
}

# --- File size helper ---
_get_file_size() {
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0
}

_human_size() {
  local bytes="$1"
  if (( bytes >= 1073741824 )); then
    printf "%.2f GB" "$(bc <<< "scale=2; $bytes / 1073741824")"
  elif (( bytes >= 1048576 )); then
    printf "%.2f MB" "$(bc <<< "scale=2; $bytes / 1048576")"
  elif (( bytes >= 1024 )); then
    printf "%.2f KB" "$(bc <<< "scale=2; $bytes / 1024")"
  else
    printf "%d B" "$bytes"
  fi
}

_display_summary() {
  local elapsed="$1" input_count="$2" input_size="$3" output_count="$4" output_size="$5" out_dir="$6"

  (( QUIET )) && return 0
  echo ""
  echo -e "${C_BOLD}${C_CYAN}========== Summary ==========${C_RESET}"
  echo -e "${C_CYAN}Total processing time: $(_hms "$elapsed")${C_RESET}"
  echo -e "${C_CYAN}Input files: $input_count ($(_human_size "$input_size"))${C_RESET}"
  echo -e "${C_CYAN}Output files: $output_count ($(_human_size "$output_size"))${C_RESET}"

  if (( input_size > 0 )); then
    local compression_ratio=$(bc <<< "scale=2; ($input_size - $output_size) * 100 / $input_size")
    echo -e "${C_CYAN}Space saved: ${compression_ratio}%${C_RESET}"
  fi

  echo -e "${C_BOLD}${C_GREEN}Done. Outputs in $out_dir${C_RESET}"
}

_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] <source_dir>
Options:
  --dry-run, -n   Show actions without creating files
  --validate      Validate inputs and exit without encoding
  --self-test     Run dependency checks and exit
  --yes, -y       Skip interactive prompts (use defaults)
  --verbose       More detailed logging
  --quiet         Minimal output (errors only)
  --help, -h      Show this help message
  --version, -v   Show version information
  <source_dir>: directory containing audio files (mp3, wav, flac, m4a, opus)
Notes:
  If cover.jpg, cover.jpeg, or cover.png exists in <source_dir>, it is embedded as cover art.
  Output duration verification allows a small tolerance for encoder/container drift.
EOF
  exit 1
}

# --- Parse Options ---
_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "${1:-}" in
      --dry-run|-n)
        DRY_RUN=1; shift
        ;;
      --validate)
        VALIDATE_ONLY=1; shift
        ;;
      --self-test)
        SELF_TEST=1; shift
        ;;
      --verbose)
        VERBOSE=1; shift
        ;;
      --quiet)
        QUIET=1; shift
        ;;
      --yes|-y)
        YES_MODE=1; shift
        ;;
      --help|-h)
        _usage
        ;;
      --version|-v)
        echo "ab.sh version $VERSION"
        exit 0
        ;;
      *)
        break
        ;;
    esac
  done
  REM_ARGS=("$@")
}

_init_metadata() {
  (( $# == 1 )) || _usage
  local input="$1"
  if [[ -f "$input" && "$input" == *.m3u* ]]; then
    PLAYLIST_PATH=$(cd "$(dirname "$input")" && pwd)/$(basename "$input")
    SRC_DIR=$(dirname "$PLAYLIST_PATH")
    BASE=$(basename "${PLAYLIST_PATH%.*}")
  else
    [[ -d "$input" ]] || _die "'$input' not found"
    SRC_DIR=$(cd "$input" && pwd)
    BASE=$(basename "$SRC_DIR")
    PLAYLIST_PATH=""
  fi

if (( YES_MODE )); then
  AUTHOR=$BASE
  TITLE=$BASE
  NARRATOR=""
  _info "Using defaults: Author='$AUTHOR', Title='$TITLE'"
else
  read -rp "Author/Artist name [default: $BASE]: " AUTHOR
  AUTHOR=${AUTHOR:-$BASE}
  read -rp "Title [default: $BASE]: " TITLE
  TITLE=${TITLE:-$BASE}
  read -rp "Narrator [optional]: " NARRATOR
fi

  OUT_DIR="$SRC_DIR/output"
  if (( !DRY_RUN && !VALIDATE_ONLY )); then
    mkdir -p "$OUT_DIR"
  fi
  if (( DRY_RUN )); then
    _log "${C_YELLOW}[DRY-RUN] Would create: $OUT_DIR${C_RESET}"
  fi
}

_find_cover() {
  local cover=""
  if [[ -n ${SRC_DIR:-} ]]; then
    cover=$(find "$SRC_DIR" -maxdepth 1 -type f \( -iname 'cover.jpg' -o -iname 'cover.jpeg' -o -iname 'cover.png' \) | sort | head -n 1 || true)
  fi
  COVER_PATH=$cover
  if [[ -n $COVER_PATH ]]; then
    _info "Cover art: $(basename "$COVER_PATH")"
  fi
}

_check_deps() {
  for cmd in ffprobe ffmpeg; do
    command -v "$cmd" >/dev/null 2>&1 || _die "$cmd required" 2
  done

  if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q 'libfdk_aac'; then
    _die "ffmpeg not compiled with libfdk_aac support\n       Install ffmpeg with libfdk_aac or use: brew reinstall ffmpeg" 2
  fi
}

_self_test() {
  _log "Self-test:"
  _log "  Bash: ${BASH_VERSION:-unknown}"
  _check_deps
  ffmpeg -hide_banner -version 2>/dev/null | head -n 1 | sed 's/^/  /'
  ffprobe -hide_banner -version 2>/dev/null | head -n 1 | sed 's/^/  /'
  _log "  libfdk_aac: OK"
  _log "Self-test complete."
}

declare -a TEMP_FILES
_cleanup() {
  local exit_code=$?
  if [[ -n "${TEMP_FILES+x}" ]] && [[ ${#TEMP_FILES[@]} -gt 0 ]]; then
    rm -f "${TEMP_FILES[@]}" 2>/dev/null || true
  fi
  exit $exit_code
}

_setup_cleanup() {
  trap _cleanup EXIT INT TERM HUP ERR
}

_track_temp() {
  TEMP_FILES+=("$@")
}

_purge_temp() {
  local remove=("$@")
  local new=()
  local f r skip
  for f in "${TEMP_FILES[@]:-}"; do
    skip=0
    for r in "${remove[@]:-}"; do
      if [[ $f == "$r" ]]; then
        skip=1
        break
      fi
    done
    (( skip )) || new+=("$f")
  done
  TEMP_FILES=()
  if (( ${#new[@]} )); then
    TEMP_FILES=("${new[@]}")
  fi
  if (( ${#remove[@]} )); then
    rm -f "${remove[@]}" 2>/dev/null || true
  fi
}

# --- Human‐readable duration ---
_hms() {
  local T="${1:-0}"
  printf '%d h: %d m: %d s' \
    $((T/3600)) $(((T%3600)/60)) $((T%60))
}

_fs_safe() {
  local s="$1"
  # Single-pass sanitization: replace unsafe chars, remove control chars, normalize spaces
  s=$(printf '%s' "$s" | tr '/:' '-' | tr '\t\n\r' '   ' | LC_CTYPE=C tr -d '[:cntrl:]' | \
      iconv -f UTF-8 -t UTF-8 -c 2>/dev/null | sed -e 's/  */ /g' -e 's/^ *//' -e 's/ *$//' || printf '%s' "$s")
  [[ -n $s ]] && printf '%s' "$s" || printf 'untitled'
}

_meta_escape() {
  local s="$1"
  # Escape special characters for FFMETADATA1 format: = ; # \ and newlines
  s=${s//\\/\\\\}  # Backslash must be escaped first
  s=${s//=/\\=}    # Escape equals
  s=${s//;/\\;}    # Escape semicolon
  s=${s//#/\\#}    # Escape hash
  s=${s//$'\n'/\\n}  # Escape newlines
  s=${s//$'\r'/}   # Remove carriage returns
  printf '%s' "$s"
}

_chapter_title_for_file() {
  local f="$1" tag base
  tag=$(ffprobe -v error -show_entries format_tags=title \
       -of default=noprint_wrappers=1:nokey=1 "$f")

  # Some files carry a full source path as title metadata; ignore those.
  if [[ -n $tag ]] && [[ $tag != */* ]] && [[ $tag != *\\* ]]; then
    printf '%s' "$tag"
    return
  fi

  base=$(basename "$f")
  printf '%s' "${base%.*}"
}

_abs() {
  local n="${1:-0}"
  if (( n < 0 )); then
    echo $(( -n ))
  else
    echo "$n"
  fi
}

_array_last() {
  local -a arr=("$@")
  local n=${#arr[@]}
  if (( n == 0 )); then
    echo ""
  else
    echo "${arr[$((n-1))]}"
  fi
}

_ffmpeg_progress() {
  local total_us="$1" label="$2"
  local us=0 last_pct=-1
  if (( total_us <= 0 )); then
    total_us=1
  fi
  local total_s=$((total_us/1000000))
  local start_time=$(date +%s)

  while IFS= read -r line; do
    case "$line" in
      out_time_ms=*)
        us=${line#out_time_ms=}
        if [[ $us =~ ^[0-9]+$ ]]; then
          pct=$(( us * 100 / total_us ))
          # Cap percentage at 100 to handle corrupt input timestamps
          (( pct > 100 )) && pct=100
          if (( pct != last_pct )); then
            last_pct=$pct
            sec=$((us/1000000))
            # Show actual encoded time but cap display at expected duration
            (( sec > total_s )) && sec=$total_s

            # Calculate ETA based on encoding speed
            local eta_str=""
            if (( pct > 0 && pct < 100 )); then
              local elapsed=$(($(date +%s) - start_time))
              local eta=$((elapsed * (100 - pct) / pct))
              eta_str=" ETA $(_hms "$eta")"
            fi

            local eta_colored=""
            if [[ -n "$eta_str" ]]; then
              eta_colored=" ETA $(_hms "$eta")"
            fi
            local msg_plain=$(printf "[%s] %3d%% Encoded %s of %s%s" "$label" "$pct" "$(_hms "$sec")" "$(_hms "$total_s")" "$eta_colored")
            # Truncate to terminal width if needed
            if (( ${#msg_plain} > TERM_WIDTH )); then
              msg_plain="${msg_plain:0:$((TERM_WIDTH-1))}"
            fi
            # Build colored message after truncation check
            if [[ -n "$eta_str" ]]; then
              printf "\r%-${TERM_WIDTH}s\r${C_CYAN}[%s]${C_RESET} ${C_BLUE}${C_BOLD}%3d%%${C_RESET} Encoded ${C_GREEN}%s${C_RESET} of ${C_MAGENTA}%s${C_RESET} ${C_YELLOW}ETA %s${C_RESET}" "" "$label" "$pct" "$(_hms "$sec")" "$(_hms "$total_s")" "$(_hms "$eta")" >&2
            else
              printf "\r%-${TERM_WIDTH}s\r${C_CYAN}[%s]${C_RESET} ${C_BLUE}${C_BOLD}%3d%%${C_RESET} Encoded ${C_GREEN}%s${C_RESET} of ${C_MAGENTA}%s${C_RESET}" "" "$label" "$pct" "$(_hms "$sec")" "$(_hms "$total_s")" >&2
            fi
          fi
        fi
        ;;
      progress=end)
        ;;
    esac
  done
  printf "\r%-${TERM_WIDTH}s\r${C_GREEN}[%s] done.${C_RESET}\n" "" "$label" >&2
}


_gather_files() {
  FILES=()
  if [[ -n ${PLAYLIST_PATH:-} ]]; then
    local line path
    while IFS= read -r line || [[ -n $line ]]; do
      [[ -z $line || $line == \#* ]] && continue
      if [[ $line == /* ]]; then
        path="$line"
      else
        path="$SRC_DIR/$line"
      fi
      [[ -f $path ]] || _die "playlist entry not found: $line" 3
      FILES+=("$path")
    done < "$PLAYLIST_PATH"
  else
    # Check if sort supports -V (version sort), fallback to regular sort
    if sort -V </dev/null >/dev/null 2>&1; then
      SORT_CMD="sort -V"
    else
      SORT_CMD="sort"
    fi

    while IFS= read -r f; do
      FILES+=("$f")
    done < <(
      find "$SRC_DIR" -type f ! -path "$OUT_DIR/*" \
        \( -iname '*.mp3' -o -iname '*.wav' -o -iname '*.flac' -o -iname '*.m4a' -o -iname '*.opus' \) \
        | $SORT_CMD
    )
  fi
  (( ${#FILES[@]} )) || _die "No audio files found" 3
  _log "${C_GREEN}Found ${#FILES[@]} files.${C_RESET}"
}

_probe_files() {
  _log "${C_BLUE}Probing durations...${C_RESET}"
  DURS=()
  VALID_FILES=()
  BITRATES=()
  # First pass: collect all bitrates to detect outliers
  for f in "${FILES[@]}"; do
    br=$(ffprobe -v error -show_entries format=bit_rate \
         -of default=noprint_wrappers=1:nokey=1 "$f")
    [[ $br =~ ^[0-9]+$ ]] && BITRATES+=("$br")
  done

  # Calculate median bitrate for outlier detection
  if (( ${#BITRATES[@]} > 0 )); then
    sorted_br=($(printf '%s\n' "${BITRATES[@]}" | sort -n))
    median_br=${sorted_br[${#sorted_br[@]}/2]}
  else
    median_br=64000  # default fallback
  fi

  # Second pass: probe durations with bitrate correction
  ZERO_LENGTH_FILES=()
  total_files=${#FILES[@]}
  current_file=0
  for f in "${FILES[@]}"; do
    current_file=$((current_file + 1))
    dur=""  # Initialize for this iteration
    if (( !QUIET )); then
      msg=$(printf "Probing file %d/%d..." "$current_file" "$total_files")
      if (( ${#msg} > TERM_WIDTH )); then
        msg="${msg:0:$((TERM_WIDTH-1))}"
      fi
      printf "\r%-${TERM_WIDTH}s\r%s" "" "$msg" >&2
    fi

    # Validate file is within source directory (prevent path traversal)
    f_real=$(cd "$(dirname "$f")" && pwd)/$(basename "$f")
    if [[ ! "$f_real" =~ ^"$SRC_DIR" ]]; then
      (( QUIET )) || printf "\r%-${TERM_WIDTH}s\n" " " >&2  # Clear progress line
      echo "Warning: ${f##*/} is outside source directory, skipping" >&2
      continue
    fi

    # Get duration and bitrate
    probe_err=$(mktemp "${TMPDIR:-/tmp}/ab-probe-XXXXXX.err") || _die "failed to create probe temp file" 4
    _track_temp "$probe_err"

    dur_raw=$(ffprobe -v error -select_streams a:0 -show_entries stream=duration \
          -of default=noprint_wrappers=1:nokey=1 "$f" 2>"$probe_err")
    if [[ -z $dur_raw || $dur_raw == "N/A" ]]; then
      dur_raw=$(ffprobe -v error -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 "$f" 2>"$probe_err")
    fi

    if [[ -z $dur_raw || $dur_raw == "N/A" ]]; then
      (( QUIET )) || printf "\r%-${TERM_WIDTH}s\n" " " >&2  # Clear progress line
      _die "failed to probe duration for ${f##*/}" 5
      if [[ -s "$probe_err" ]]; then
        echo "       ffprobe output:" >&2
        sed 's/^/       /' "$probe_err" >&2
      fi
      _purge_temp "$probe_err"
    fi

    bitrate=$(ffprobe -v error -show_entries format=bit_rate \
             -of default=noprint_wrappers=1:nokey=1 "$f" 2>"$probe_err")
    file_size=$(_get_file_size "$f")
    _purge_temp "$probe_err"

    # Detect corrupt bitrate metadata (>20x different from median)
    if [[ $bitrate =~ ^[0-9]+$ ]] && (( median_br > 0 )); then
      if (( bitrate < median_br / 20 || bitrate > median_br * 20 )); then
        (( QUIET )) || printf "\r%-${TERM_WIDTH}s\n" " " >&2  # Clear progress line
    _warn "${f##*/} has suspect bitrate ($bitrate bps vs median $median_br bps)"
      _log "${C_YELLOW}         Recalculating duration from file size...${C_RESET}"
        # Recalculate duration using median bitrate
        if (( file_size > 0 && median_br > 0 )); then
          dur=$(( (file_size * 8) / median_br ))
        _log "${C_YELLOW}         Corrected: $(_hms "$dur") (was $(_hms "${dur_raw%.*}")${C_RESET})"
        fi
      fi
    fi

    # Parse duration if not already corrected
    if [[ -z $dur ]]; then
      if [[ $dur_raw =~ ^[0-9]+\.?[0-9]*$ ]]; then
        dur=${dur_raw%.*}
        [[ -n $dur ]] || dur=0
      else
        printf "\r%-${TERM_WIDTH}s\n" " " >&2  # Clear progress line
        _die "invalid duration '$dur_raw' for ${f##*/}" 5
      fi
    fi

    # Check for files with zero length or duration
    if (( dur == 0 || file_size == 0 )); then
      ZERO_LENGTH_FILES+=("$f")
      continue
    fi

    DURS+=("$dur")
    VALID_FILES+=("$f")
    (( DRY_RUN )) && echo "[DRY ] $f → $(_hms "$dur")"
    dur=""  # Clear for next iteration
  done
  (( QUIET )) || printf "\r%-${TERM_WIDTH}s\r" " " >&2  # Clear progress line

  # Report zero-length files if any found
  if (( ${#ZERO_LENGTH_FILES[@]} > 0 )); then
    echo -e "${C_RED}Error: Found ${#ZERO_LENGTH_FILES[@]} file(s) with zero duration or size:${C_RESET}" >&2
    for f in "${ZERO_LENGTH_FILES[@]}"; do
      echo -e "${C_RED}  - ${f#$SRC_DIR/}${C_RESET}" >&2
    done
    echo -e "${C_RED}Please remove or fix these files and try again.${C_RESET}" >&2
    exit 3
  fi

  # Check we still have files after validation
  (( ${#DURS[@]} )) || _die "no valid audio files after validation" 3

  # Update FILES to only include validated files
  FILES=("${VALID_FILES[@]}")
  _log "${C_GREEN}Validated ${#FILES[@]} files.${C_RESET}"
}

_split_parts() {
  PART_DURS=()
  START_IDX=()
  END_IDX=()
  total=1 sum=0 start=0
  for ((i=0; i<${#FILES[@]}; i++)); do
    d=${DURS[i]}

    # Check if single file exceeds MAX_DURATION
    if (( d > MAX_DURATION )); then
      _warn "${FILES[i]#$SRC_DIR/} ($(_hms "$d")) exceeds max duration ($(_hms "$MAX_DURATION"))"
      _log "${C_YELLOW}         Will be placed in its own part.${C_RESET}"
      # Save current part if it has content
      if (( sum > 0 )); then
        PART_DURS+=("$sum")
        START_IDX+=("$start")
        END_IDX+=("$((i-1))")
        total=$((total + 1))
      fi
      # Create part with just this oversized file
      PART_DURS+=("$d")
      START_IDX+=("$i")
      END_IDX+=("$i")
      sum=0; start=$((i+1)); total=$((total + 1))
      continue
    fi

    # Normal splitting logic
    if (( sum + d > MAX_DURATION && sum > 0 )); then
      PART_DURS+=("$sum")
      START_IDX+=("$start")
      END_IDX+=("$((i-1))")
      sum=0; total=$((total + 1)); start=$i
    fi
    sum=$((sum + d))
  done

  # Add final part if it has content
  if (( sum > 0 )); then
    PART_DURS+=("$sum")
    START_IDX+=("$start")
    END_IDX+=("$(( ${#FILES[@]} - 1 ))")
  fi

  _log "${C_CYAN}Estimated parts: $total${C_RESET}"
  for idx in "${!PART_DURS[@]}"; do
    _log "${C_CYAN}  Part $((idx+1)) ($(_hms "${PART_DURS[idx]}")): files ${START_IDX[idx]}–${END_IDX[idx]}${C_RESET}"
  done
  if (( DRY_RUN )); then
    return 0
  fi
}

_validate_out_dir() {
  [[ -w "$OUT_DIR" ]] || _die "no write permission for output directory: $OUT_DIR" 4
}

_select_output_format() {
  # --- Detect sample rates & bitrates (bash 3.2 compatible) ---
  local sr_vals=() br_vals=()
  for f in "${FILES[@]}"; do
    sr=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate \
         -of default=noprint_wrappers=1:nokey=1 "$f")
    [[ -n $sr ]] && sr_vals+=("$sr")
    br=$(ffprobe -v error -show_entries format=bit_rate \
         -of default=noprint_wrappers=1:nokey=1 "$f")
    if [[ $br =~ ^[0-9]+$ ]]; then
      br_vals+=("$((br/1000))")
    fi
  done
  SR_LIST=()
  BR_LIST=()
  while IFS= read -r v; do SR_LIST+=("$v"); done < <(printf "%s\n" "${sr_vals[@]}" | sort -n | uniq)
  while IFS= read -r v; do BR_LIST+=("$v"); done < <(printf "%s\n" "${br_vals[@]}" | sort -n | uniq)
  _vlog "${C_DIM}Detected sample rates: ${SR_LIST[*]}${C_RESET}"
  _vlog "${C_DIM}Detected bitrates: ${BR_LIST[*]} kbps${C_RESET}"

  # --- Choose output sample rate & bitrate (auto) ---
  DEFAULT_SR=44100
  min_sr=${SR_LIST[0]-0}
  max_sr=$(_array_last "${SR_LIST[@]}")
  max_br_kbps=$(_array_last "${BR_LIST[@]}")  # Bitrate in kbps
  max_sr=${max_sr:-0}
  max_br_kbps=${max_br_kbps:-0}

  # Select output sample rate
  if (( min_sr >= 48000 )); then
    OUT_SR=48000
  elif (( max_sr >= 44100 )); then
    OUT_SR=44100
  else
    OUT_SR=$DEFAULT_SR
  fi

  # Select VBR mode based on detected bitrate (in kbps)
  if (( max_br_kbps >= 128 )); then
    VBR_MODE=5  # ~112 kbps average
    VBR_AVG_KBPS=112
    target_br="~112"
  else
    VBR_MODE=4  # ~72 kbps average
    VBR_AVG_KBPS=72
    target_br="~72"
  fi

  _log "${C_GREEN}Selected: $OUT_SR Hz @ VBR mode $VBR_MODE ($target_br kbps) (auto)${C_RESET}"
}

_collect_input_stats() {
  total_input_size=0
  for f in "${FILES[@]}"; do
    fsize=$(_get_file_size "$f")
    total_input_size=$((total_input_size + fsize))
  done
  script_start_time=$(date +%s)
  OUTPUT_FILES=()
  OUTPUT_SIZES=()
}

_estimate_dry_run_summary() {
  local total_bytes=0
  _log "${C_CYAN}Dry-run size estimate (VBR ~${VBR_AVG_KBPS} kbps):${C_RESET}"
  for ((p=0; p<total; p++)); do
    local pd=${PART_DURS[p]}
    local est_bytes=$(( pd * VBR_AVG_KBPS * 1000 / 8 ))
    total_bytes=$((total_bytes + est_bytes))
    _log "${C_CYAN}  Part $((p+1)): $(_human_size "$est_bytes")${C_RESET}"
  done
  _log "${C_CYAN}  Total: $(_human_size "$total_bytes")${C_RESET}"
}

_encode_parts() {
  for ((p=0; p<total; p++)); do
    s=${START_IDX[p]}; e=${END_IDX[p]}; pd=${PART_DURS[p]}
    _log "${C_BOLD}${C_BLUE}-- Part $((p+1)) ($(_hms "$pd")) --${C_RESET}"
    for ((i=s; i<=e; i++)); do _log "${C_DIM}  ${FILES[i]#$SRC_DIR/}${C_RESET}"; done

    # zero-pad track and part suffix if >9 parts
    if (( total > 9 )); then
      num=$(printf "%02d" $((p+1)))
    else
      num=$((p+1))
    fi
    PART_SUFFIX=""
    (( total>1 )) && PART_SUFFIX=" — Part $num"
    PART_NAME="$TITLE$PART_SUFFIX"
    SAFE_AUTHOR=$(_fs_safe "$AUTHOR")
    SAFE_PART_NAME=$(_fs_safe "$PART_NAME")
    OUT_FILE="$OUT_DIR/${SAFE_AUTHOR} — ${SAFE_PART_NAME}.m4b"

    # raw AAC temp - create in secure temp directory
    tmp=$(mktemp "${TMPDIR:-/tmp}/ab-encode-XXXXXX.tmp") || { echo "Error: failed to create temp file" >&2; exit 4; }
    AAC="${tmp%.tmp}.aac"
    mv "$tmp" "$AAC" 2>/dev/null || { rm -f "$tmp"; echo "Error: failed to create AAC temp file" >&2; exit 4; }
    _track_temp "$AAC"

    # Encode with progress monitoring
    # Array slice: FILES[s:e-s+1] extracts elements from index s to e (inclusive)
    if (( QUIET )); then
      ffmpeg -hide_banner -nostats -loglevel error -y \
        -threads 0 \
        -f concat -safe 0 -i <(for f in "${FILES[@]:s:e-s+1}"; do esc=${f//\'/\'\\\'\'}; printf "file '%s'\n" "$esc"; done) \
        -c:a libfdk_aac -vbr "$VBR_MODE" -ar "$OUT_SR" -vn -f adts "$AAC" || {
          echo "Error: encode failed (exit code $?)" >&2
          exit 5
        }
    else
      ( ffmpeg -hide_banner -nostats -loglevel error -y \
        -threads 0 \
        -f concat -safe 0 -i <(for f in "${FILES[@]:s:e-s+1}"; do esc=${f//\'/\'\\\'\'}; printf "file '%s'\n" "$esc"; done) \
        -c:a libfdk_aac -vbr "$VBR_MODE" -ar "$OUT_SR" -vn -f adts "$AAC" \
        -progress pipe:1 \
      | _ffmpeg_progress $((pd*1000000)) "encode"; exit "${PIPESTATUS[0]}" ) || {
        echo "Error: encode failed (exit code $?)" >&2
        exit 5
      }
    fi

    # build metadata+chapters
    META=$(mktemp "${TMPDIR:-/tmp}/ab-metadata-XXXXXX.txt") || { echo "Error: failed to create metadata temp file" >&2; exit 4; }
    _track_temp "$META"
    {
      echo ";FFMETADATA1"
      echo "title=$(_meta_escape "$PART_NAME")"
      echo "artist=$(_meta_escape "$AUTHOR")"
      echo "album=$(_meta_escape "$TITLE")"
      echo "track=$((p+1))/$total"
      echo "album_artist=$(_meta_escape "$AUTHOR")"
      if [[ -n ${NARRATOR:-} ]]; then
        echo "narrator=$(_meta_escape "$NARRATOR")"
      fi
    } >"$META"

    offset=0
    for ((i=s; i<=e; i++)); do
      d=${DURS[i]}; f=${FILES[i]}
      start_ms=$((offset*1000))
      end_ms=$(((offset+d)*1000))
      tag=$(_chapter_title_for_file "$f")
      tag=$(_meta_escape "$tag")
      cat <<EOF >>"$META"
[CHAPTER]
TIMEBASE=1/1000
START=$start_ms
END=$end_ms
title=$tag
EOF
      offset=$((offset + d))
    done

    # mux into .m4b with date & genre (and optional cover art)
    if [[ -n ${COVER_PATH:-} ]]; then
      ffmpeg -hide_banner -nostats -loglevel error -y \
        -i "$AAC" -i "$META" -i "$COVER_PATH" \
        -map 0 -map_metadata 1 -map 2 \
        -metadata date="$(date +%Y)" \
        -metadata genre="Audiobook" \
        -metadata:s:v title="cover" -metadata:s:v comment="Cover (front)" \
        -c:a copy -c:v mjpeg -disposition:v attached_pic -movflags +faststart "$OUT_FILE" || {
          echo "Error: failed to create output file: $OUT_FILE" >&2
          exit 5
        }
    else
      ffmpeg -hide_banner -nostats -loglevel error -y \
        -i "$AAC" -i "$META" \
        -map_metadata 1 \
        -metadata date="$(date +%Y)" \
        -metadata genre="Audiobook" \
        -c copy -movflags +faststart "$OUT_FILE" || {
          echo "Error: failed to create output file: $OUT_FILE" >&2
          exit 5
        }
    fi

    # Validate output file was created successfully
    if [[ ! -f "$OUT_FILE" ]]; then
      echo "Error: output file was not created: $OUT_FILE" >&2
      exit 5
    fi

    out_size=$(_get_file_size "$OUT_FILE")
    if (( out_size == 0 )); then
      echo "Error: output file is empty: $OUT_FILE" >&2
      exit 5
    fi

    # Verify output file is valid media
    if ! ffprobe -v error "$OUT_FILE" >/dev/null 2>&1; then
      echo "Error: output file is not a valid media file: $OUT_FILE" >&2
      exit 5
    fi

    # Verify output duration matches expected part duration (within 2s)
    out_dur_raw=$(ffprobe -v error -show_entries format=duration \
         -of default=noprint_wrappers=1:nokey=1 "$OUT_FILE")
    if [[ $out_dur_raw =~ ^[0-9]+\.?[0-9]*$ ]]; then
      out_dur=${out_dur_raw%.*}
    else
      echo "Error: could not read output duration for $OUT_FILE" >&2
      exit 5
    fi
    diff=$(_abs $((out_dur - pd)))
    tol=$((pd * 2 / 1000))  # 0.2% of expected duration
    if (( tol < 10 )); then
      tol=10
    fi
    if (( diff > tol )); then
      echo "Error: output duration mismatch for $OUT_FILE" >&2
      echo "       expected ~${pd}s, got ${out_dur}s (tolerance ${tol}s)" >&2
      exit 5
    fi

    _purge_temp "$AAC" "$META"
    _log "${C_GREEN}→ $OUT_FILE${C_RESET}"

    # Track output file for statistics
    OUTPUT_FILES+=("$OUT_FILE")
    OUTPUT_SIZES+=("$out_size")
  done
}

_summarize() {
  script_end_time=$(date +%s)
  total_elapsed=$((script_end_time - script_start_time))

  total_output_size=0
  for size in "${OUTPUT_SIZES[@]}"; do
    total_output_size=$((total_output_size + size))
  done

  _display_summary "$total_elapsed" "${#FILES[@]}" "$total_input_size" "${#OUTPUT_FILES[@]}" "$total_output_size" "$OUT_DIR"
}

_main() {
  _parse_args "$@"
  if (( ${#REM_ARGS[@]} )); then
    set -- "${REM_ARGS[@]}"
  else
    set --
  fi

  if (( SELF_TEST )); then
    _self_test
    exit 0
  fi

  _init_metadata "$@"
  _find_cover
  _check_deps
  _setup_cleanup

  _gather_files
  _probe_files
  if (( VALIDATE_ONLY )); then
    _info "Validation complete. ${#FILES[@]} files are ready."
    exit 0
  fi
  _split_parts
  _select_output_format
  if (( DRY_RUN )); then
    _estimate_dry_run_summary
    exit 0
  fi
  _validate_out_dir
  _collect_input_stats
  _encode_parts
  _summarize
}

_main "$@"
