#!/usr/bin/env bash
# ab.sh - Concatenate audio files into .m4b with chapters, splitting at 12h max
# Supports --dry-run mode and validation of input files
# Usage: ab.sh [--dry-run] <source_dir>
# Requirements: bash, ffprobe, ffmpeg

set -euo pipefail

MAX_DURATION=$((12 * 3600))  # 12 hours max per part
DRY_RUN=0

# --- Parse Options ---
if [[ ${1:-} == "--dry-run" || ${1:-} == "-n" ]]; then
  DRY_RUN=1
  shift
fi

_usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] <source_dir>
  --dry-run, -n   Show actions without creating files
  <source_dir>: directory containing audio files (mp3, wav, flac)
EOF
  exit 1
}

# --- Args & Setup ---
(( $# == 1 )) || _usage
[[ -d "$1" ]] || { echo "Error: '$1' not found" >&2; _usage; }
SRC_DIR=$(cd "$1" && pwd)
BASE=$(basename "$SRC_DIR")

# Prompt for metadata
read -rp "Author/Artist name [default: $BASE]: " AUTHOR
AUTHOR=${AUTHOR:-$BASE}
read -rp "Title [default: $BASE]: " TITLE
TITLE=${TITLE:-$BASE}

OUT_DIR="$SRC_DIR/output"
if (( DRY_RUN == 0 )); then
  mkdir -p "$OUT_DIR"
else
  echo "[DRY-RUN] Would create output directory: $OUT_DIR"
fi

# --- Dependencies ---
for cmd in ffprobe ffmpeg; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: $cmd required" >&2; exit 2; }
done

# --- Human-readable duration helper ---
_hms() {
  local T=$1
  local h=$((T/3600))
  local m=$(((T%3600)/60))
  local s=$((T%60))
  echo "${h} h: ${m} m: ${s} s"
}

# --- Gather & Sort Files ---
readarray -t FILES < <(
  find "$SRC_DIR" -type f ! -path "$OUT_DIR/*" \( -iname '*.mp3' -o -iname '*.wav' -o -iname '*.flac' \) | sort -V
)
(( ${#FILES[@]} )) || { echo "Error: no audio files found in '$SRC_DIR'" >&2; exit 3; }
echo "Found ${#FILES[@]} files."

# --- Validation Pass & Duration Collection ---
echo "Validating input files with ffprobe..."
declare -a DURS
for f in "${FILES[@]}"; do
  if ! ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$f" >/dev/null; then
    echo "Error: ffprobe cannot read '$f'" >&2
    exit 5
  fi
  dur=$(ffprobe -v error -show_entries format=duration \
         -of default=noprint_wrappers=1:nokey=1 "$f" | cut -d'.' -f1)
  DURS+=("$dur")
  if (( DRY_RUN == 1 )); then
    echo "[DRY-RUN] Validated: $f (duration: $(_hms "$dur"))"
  fi
done

# --- Estimate Parts & Record Ranges ---
declare -a PART_DURS START_IDX END_IDX
total_parts=1 curr_sum=0 start_idx=0
num_files=${#FILES[@]}
for ((i=0; i<num_files; i++)); do
  d=${DURS[i]}
  if (( curr_sum + d > MAX_DURATION )); then
    PART_DURS+=("$curr_sum")
    START_IDX+=("$start_idx")
    END_IDX+=("$((i-1))")
    curr_sum=0
    (( total_parts++ ))
    start_idx=$i
  fi
  (( curr_sum += d ))
done
# Last part
PART_DURS+=("$curr_sum")
START_IDX+=("$start_idx")
END_IDX+=("$((num_files-1))")

echo "Estimated parts: $total_parts"
for idx in "${!PART_DURS[@]}"; do
  dur=${PART_DURS[idx]}
  start=${START_IDX[idx]}
  end=${END_IDX[idx]}
  echo "  Part $((idx+1)) ($(_hms "$dur")): files $start-$end"
done

# If dry-run, stop here
if (( DRY_RUN == 1 )); then
  echo "[DRY-RUN] Completed. No files were created."
  exit 0
fi

# --- Detect Sample Rates & Bitrates ---
declare -A SR_SET BR_SET
for f in "${FILES[@]}"; do
  sr=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate \
       -of default=noprint_wrappers=1:nokey=1 "$f")
  SR_SET[$sr]=1
  raw=$(ffprobe -v error -show_entries format=bit_rate \
        -of default=noprint_wrappers=1:nokey=1 "$f")
  BR_SET[$((raw/1000))]=1
done
mapfile -t SR_LIST < <(printf "%s\n" "${!SR_SET[@]}" | sort -n)
mapfile -t BR_LIST < <(printf "%s\n" "${!BR_SET[@]}" | sort -n)

echo "Detected sample rates: ${SR_LIST[*]}"
echo "Detected bitrates: ${BR_LIST[*]} kbps"

# --- Choose Output Format ---
TARGET_SR=(48000 48000 44100 44100)
TARGET_BR=(128k 64k 128k 64k)
echo "Choose output format (no upscaling beyond inputs):"
for i in "${!TARGET_SR[@]}"; do
  sr=${TARGET_SR[i]} br=${TARGET_BR[i]}
  if printf "%s " "${SR_LIST[*]}" | grep -qw "$sr" || (( i>=2 )); then
    echo "  $((i+1))) $sr Hz @ $br"
  else
    echo "  $((i+1))) $sr Hz @ $br (skip – would upscale)" >&2
  fi
done
read -rp "Enter choice [1-4]: " CHOICE
(( CHOICE>=1 && CHOICE<=4 )) || { echo "Invalid choice" >&2; exit 4; }
OUT_SR=${TARGET_SR[CHOICE-1]}
OUT_BR=${TARGET_BR[CHOICE-1]}
echo "Selected: $OUT_SR Hz @ $OUT_BR"

# --- Encode Parts ---
for ((p=0; p<total_parts; p++)); do
  s=${START_IDX[p]} e=${END_IDX[p]} part_sum=${PART_DURS[p]}
  part_hms=$(_hms "${part_sum}")
  echo "-- Creating Part $((p+1)) (${part_hms}) --" >&2

  if (( total_parts > 1 )); then
    part_name="$AUTHOR — $TITLE — Part $((p+1))"
  else
    part_name="$AUTHOR — $TITLE"
  fi

  for ((i=s; i<=e; i++)); do
    echo "  ${FILES[i]#$SRC_DIR/}" >&2
  done

  listfile=$(mktemp)
  metafile=$(mktemp)
  printf ";FFMETADATA1\n" > "$metafile"
  {
    echo "title=$part_name"
    echo "artist=$AUTHOR"
    echo "album=$TITLE"
    echo "album_artist=$AUTHOR"
  } >> "$metafile"

  offset=0
  for ((i=s; i<=e; i++)); do
    f="${FILES[i]}"
    d="${DURS[i]}"
    printf "file '%s'\n" "$f" >> "$listfile"
    chap_title=$(ffprobe -v error -show_entries format_tags=title \
      -of default=noprint_wrappers=1:nokey=1 "$f")
    [[ -z "$chap_title" ]] && chap_title="$(basename "$f")"
    end=$(( offset + d ))
    cat <<EOF >> "$metafile"
[CHAPTER]
TIMEBASE=1/1
START=$offset
END=$end
title=$chap_title
EOF
    offset=$end
  done

  out="$OUT_DIR/${part_name}.m4b"
  echo "Creating: $out"
  ffmpeg -hide_banner -loglevel error \
    -f concat -safe 0 -i "$listfile" \
    -i "$metafile" \
    -map_metadata 1 \
    -c:a aac -b:a "$OUT_BR" -ar "$OUT_SR" -vn \
    -f ipod "$out"

  rm -f "$listfile" "$metafile"
done

echo "Done. Outputs in $OUT_DIR"

