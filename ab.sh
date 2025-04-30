#!/usr/bin/env bash
# ab.sh - Concatenate audio files → .m4b with chapters, splitting at 12h max,
#         showing real-time encode progress via pv and packaging via MP4Box
# Supports --dry-run mode and validation of input files
# Usage: ab.sh [--dry-run] <source_dir>
# Requirements: bash, ffprobe, ffmpeg (with libfdk_aac), pv, MP4Box

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

read -rp "Author/Artist name [default: $BASE]: " AUTHOR
AUTHOR=${AUTHOR:-$BASE}
read -rp "Title [default: $BASE]: " TITLE
TITLE=${TITLE:-$BASE}

OUT_DIR="$SRC_DIR/output"
(( DRY_RUN )) || mkdir -p "$OUT_DIR"
(( DRY_RUN )) && echo "[DRY-RUN] Would create output directory: $OUT_DIR"

# --- Dependencies ---
for cmd in ffprobe ffmpeg pv MP4Box; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: $cmd required" >&2; exit 2; }
done

# --- Helper: human-readable duration ---
_hms() {
  local T="${1:-0}"
  printf '%d h: %d m: %d s\n' $((T/3600)) $(((T%3600)/60)) $((T%60))
}

# --- Gather & Sort Files ---
readarray -t FILES < <(
  find "$SRC_DIR" -type f ! -path "$OUT_DIR/*" \
    \( -iname '*.mp3' -o -iname '*.wav' -o -iname '*.flac' \) \
    | sort -V
)
(( ${#FILES[@]} )) || { echo "Error: no audio files found" >&2; exit 3; }
echo "Found ${#FILES[@]} files."

# --- Validation & Duration Collection ---
echo "Validating input files with ffprobe..."
declare -a DURS
for f in "${FILES[@]}"; do
  dur=$(ffprobe -v error -show_entries format=duration \
         -of default=noprint_wrappers=1:nokey=1 "$f" | cut -d'.' -f1)
  DURS+=("$dur")
  (( DRY_RUN )) && echo "[DRY-RUN] $f → $(_hms "$dur")"
done

# --- Split into ≤12h parts ---
declare -a PART_DURS START_IDX END_IDX
total_parts=1 curr_sum=0 start_idx=0
for ((i=0; i<${#FILES[@]}; i++)); do
  d=${DURS[i]}
  if (( curr_sum + d > MAX_DURATION )); then
    PART_DURS+=("$curr_sum")
    START_IDX+=("$start_idx")
    END_IDX+=("$((i-1))")
    curr_sum=0
    (( total_parts++ ))
    start_idx=$i
  fi
  (( curr_sum+=d ))
done
PART_DURS+=("$curr_sum")
START_IDX+=("$start_idx")
END_IDX+=("$(( ${#FILES[@]} - 1 ))")

echo "Estimated parts: $total_parts"
for idx in "${!PART_DURS[@]}"; do
  echo "  Part $((idx+1)) ($(_hms "${PART_DURS[idx]}")): files ${START_IDX[idx]}–${END_IDX[idx]}"
done
(( DRY_RUN )) && exit 0

# --- Detect sample rates & bitrates ---
declare -A SR_SET BR_SET
for f in "${FILES[@]}"; do
  sr=$(ffprobe -v error -select_streams a:0 \
       -show_entries stream=sample_rate \
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

# --- Choose output format ---
TARGET_SR=(48000 48000 44100 44100)
TARGET_BR=(128k    64k    128k    64k)
echo "Choose output format (no up-scaling beyond inputs):"
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
BR_KBPS=${OUT_BR%k}

# --- Encode & package each part ---
for ((p=0; p<total_parts; p++)); do
  s=${START_IDX[p]} e=${END_IDX[p]} pd=${PART_DURS[p]}
  echo "-- Creating Part $((p+1)) ($(_hms "$pd")) --" >&2
  for ((i=s; i<=e; i++)); do
    echo "  ${FILES[i]#$SRC_DIR/}" >&2
  done

  part_name="$TITLE"
  (( total_parts>1 )) && part_name="$TITLE — Part $((p+1))"

  # Build concat list & chapter file
  listfile=$(mktemp)
  chapfile=$(mktemp)
  offset=0 idx=1
  for ((i=s; i<=e; i++)); do
    f=${FILES[i]} d=${DURS[i]}
    echo "file '$f'" >> "$listfile"
    hh=$((offset/3600)) mm=$(((offset%3600)/60)) ss=$((offset%60))
    ts=$(printf '%02d:%02d:%02d.000' $hh $mm $ss)
    title_tag=$(ffprobe -v error -show_entries format_tags=title \
               -of default=noprint_wrappers=1:nokey=1 "$f")
    [[ -z $title_tag ]] && title_tag=$(basename "$f")
    printf 'CHAPTER%02d=%s\nCHAPTER%02dNAME=%s\n' \
      $idx "$ts" $idx "$title_tag" >> "$chapfile"
    (( offset+=d, idx++ ))
  done

  tmp=$(mktemp "${TMPDIR:-/tmp}/ab_part.XXXXXX")
  part_aac="${tmp}.aac"
  exp_bytes=$(( pd * BR_KBPS * 1000 / 8 ))

  set +o pipefail
  ffmpeg -hide_banner -nostats -loglevel fatal \
    -threads 0 \
    -f concat -safe 0 -i "$listfile" \
    -c:a libfdk_aac -vbr 3 -ar "$OUT_SR" -vn -f adts - \
  | pv -pter -s "$exp_bytes" >"$part_aac"
  set -o pipefail

  out="$OUT_DIR/${AUTHOR} — ${part_name}.m4b"
  MP4Box -add "$part_aac" \
    -itags "title=$TITLE:album=$TITLE:artist=$AUTHOR:album_artist=$AUTHOR" \
    -chap "$chapfile" \
    -new "$out" >/dev/null

  rm -f "$listfile" "$chapfile" "$part_aac"
  echo "→ $out"
done

echo "Done. Outputs in $OUT_DIR"

