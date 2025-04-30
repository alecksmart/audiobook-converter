#!/usr/bin/env bash
# ab.sh - Concatenate audio files → .m4b with chapters, splitting at 12h max,
#         showing real-time encode progress via pv and embedding chapters via FFmpeg
# Supports --dry-run mode and validation of input files
# Usage: ab.sh [--dry-run] <source_dir>
# Requirements: bash, ffprobe, ffmpeg (with libfdk_aac), pv

set -euo pipefail

MAX_DURATION=$((12 * 3600))  # 12 h max per part
DRY_RUN=0

# --- Parse Options ---
if [[ ${1:-} == "--dry-run" || ${1:-} == "-n" ]]; then
  DRY_RUN=1; shift
fi

_usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] <source_dir>
  --dry-run, -n   Show actions without creating files
  <source_dir>: directory containing audio files (mp3, wav, flac)
EOF
  exit 1
}

# --- Setup & metadata prompts ---
(( $# == 1 )) || _usage
[[ -d "$1" ]] || { echo "Error: '$1' not found" >&2; _usage; }
SRC_DIR=$(cd "$1" && pwd)
BASE=$(basename "$SRC_DIR")

read -rp "Author/Artist name [default: $BASE]: " AUTHOR
AUTHOR=${AUTHOR:-$BASE}
read -rp "Title [default: $BASE]: " TITLE
TITLE=${TITLE:-$BASE}

OUT_DIR="$SRC_DIR/output"
(( DRY_RUN )) || mkdir -p "$OUT_DIR"
(( DRY_RUN )) && echo "[DRY-RUN] Would create: $OUT_DIR"

# --- Dependencies ---
for cmd in ffprobe ffmpeg pv; do
  command -v "$cmd" >/dev/null 2>&1 \
    || { echo "Error: $cmd required" >&2; exit 2; }
done

# --- Human‐readable duration helper ---
_hms() {
  local T="${1:-0}"
  printf '%d h: %d m: %d s\n' \
    $((T/3600)) $(((T%3600)/60)) $((T%60))
}

# --- Gather & sort inputs ---
readarray -t FILES < <(
  find "$SRC_DIR" -type f ! -path "$OUT_DIR/*" \
    \( -iname '*.mp3' -o -iname '*.wav' -o -iname '*.flac' \) \
    | sort -V
)
(( ${#FILES[@]} )) || { echo "No audio files found" >&2; exit 3; }
echo "Found ${#FILES[@]} files."

# --- Validate & collect durations ---
echo "Probing durations..."
declare -a DURS
for f in "${FILES[@]}"; do
  dur=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$f" | cut -d. -f1)
  DURS+=("$dur")
  (( DRY_RUN )) && echo "[DRY] $f → $(_hms "$dur")"
done

# --- Split into ≤12 h parts ---
declare -a PART_DURS START_IDX END_IDX
total=1 sum=0 start=0
for ((i=0; i<${#FILES[@]}; i++)); do
  d=${DURS[i]}
  if (( sum + d > MAX_DURATION )); then
    PART_DURS+=("$sum"); START_IDX+=("$start"); END_IDX+=("$((i-1))")
    sum=0; ((total++)); start=$i
  fi
  (( sum+=d ))
done
PART_DURS+=("$sum"); START_IDX+=("$start"); END_IDX+=("$(( ${#FILES[@]} - 1 ))")

echo "Estimated parts: $total"
for idx in "${!PART_DURS[@]}"; do
  echo "  Part $((idx+1)) ($(_hms "${PART_DURS[idx]}")): files ${START_IDX[idx]}–${END_IDX[idx]}"
done
(( DRY_RUN )) && exit 0

# --- Select output sample rate & bitrate ---
declare -A SR_SET BR_SET
for f in "${FILES[@]}"; do
  sr=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate \
       -of default=noprint_wrappers=1:nokey=1 "$f")
  SR_SET[$sr]=1
  br=$(ffprobe -v error -show_entries format=bit_rate \
       -of default=noprint_wrappers=1:nokey=1 "$f")
  BR_SET[$((br/1000))]=1
done
mapfile -t SR_LIST < <(printf "%s\n" "${!SR_SET[@]}" | sort -n)
mapfile -t BR_LIST < <(printf "%s\n" "${!BR_SET[@]}" | sort -n)
echo "Detected sample rates: ${SR_LIST[*]}"
echo "Detected bitrates: ${BR_LIST[*]} kbps"

TARGET_SR=(48000 48000 44100 44100)
TARGET_BR=(128k    64k    128k    64k)
echo "Choose output format (no up-scaling):"
for i in "${!TARGET_SR[@]}"; do
  sr=${TARGET_SR[i]} br=${TARGET_BR[i]}
  if printf "%s " "${SR_LIST[*]}" | grep -qw "$sr" || (( i>=2 )); then
    echo "  $((i+1))) $sr Hz @ $br"
  else
    echo "  $((i+1))) $sr Hz @ $br (skip – would upscale)" >&2
  fi
done
read -rp "Choice [1-4]: " C
(( C>=1 && C<=4 )) || { echo "Invalid"; exit 4; }
OUT_SR=${TARGET_SR[C-1]}; OUT_BR=${TARGET_BR[C-1]}
echo "Selected: $OUT_SR Hz @ $OUT_BR"
BR_KBPS=${OUT_BR%k}

# --- Encode & mux each part ---
for ((p=0; p<total; p++)); do
  s=${START_IDX[p]}; e=${END_IDX[p]}; pd=${PART_DURS[p]}
  echo "-- Part $((p+1)) ($(_hms "$pd")) --" >&2
  for ((i=s; i<=e; i++)); do echo "  ${FILES[i]#$SRC_DIR/}"; done

  # temp AAC
  tmp=$(mktemp "${TMPDIR:-/tmp}/ab.XXXXXX"); AAC="${tmp}.aac"
  bytes=$(( pd * BR_KBPS * 1000 / 8 ))

  # encode w/ pv
  set +o pipefail
  ffmpeg -hide_banner -nostats -loglevel fatal \
    -threads 0 \
    -f concat -safe 0 -i <(for f in "${FILES[@]:s:e-s+1}"; do printf "file '%s'\n" "$f"; done) \
    -c:a libfdk_aac -vbr 3 -ar "$OUT_SR" -vn -f adts - \
  | pv -pter -s "$bytes" >"$AAC"
  set -o pipefail

  # build FFmetadata file
  META=$(mktemp)
  {
    echo ";FFMETADATA1"
    echo "title=$TITLE"
    echo "artist=$AUTHOR"
    echo "album=$TITLE"
    echo "album_artist=$AUTHOR"
  } >"$META"

  offset=0; idx=1
  for ((i=s; i<=e; i++)); do
    d=${DURS[i]}; f=${FILES[i]}
    ms=$((offset*1000)); me=$(((offset+d)*1000))
    tag=$(ffprobe -v error -show_entries format_tags=title \
         -of default=noprint_wrappers=1:nokey=1 "$f")
    [[ -z $tag ]] && tag=$(basename "$f")
    cat <<EOF >>"$META"
[CHAPTER]
TIMEBASE=1/1000
START=$ms
END=$me
title=$tag
EOF
    (( offset+=d, idx++ ))
  done

  # final mux with chapters
  PART_NAME="$TITLE"
  (( total>1 )) && PART_NAME="$TITLE — Part $((p+1))"
  OUT="$OUT_DIR/${AUTHOR} — ${PART_NAME}.m4b"

  ffmpeg -hide_banner -nostats -loglevel error \
    -i "$AAC" -i "$META" \
    -map_metadata 1 -c copy -movflags +faststart "$OUT"

  rm -f "$AAC" "$META"
  echo "→ $OUT"
done

echo "Done. Outputs in $OUT_DIR"

