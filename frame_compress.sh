#!/bin/bash
#SBATCH -p seqbio
#SBATCH -c 16

# frame_compress.sh
# Usage:
#   frame_compress.sh input_file               -> input_file.framed.zst + input_file.index.tsv
#   frame_compress.sh - output_stem < input    -> output_stem.framed.zst + output_stem.index.tsv
#   frame_compress.sh input_file output_stem   -> output_stem.framed.zst + output_stem.index.tsv
#
# Assumptions:
#   - Input is sorted by the first column.
#   - Input is newline-delimited text.
#   - A new zstd frame is started only when the key changes AND the current
#     frame has already reached ~300 MB of uncompressed data.
# Outputs are removed on failure; existing outputs are never overwritten.

set -euo pipefail
LC_ALL=C
export LC_ALL

prog=$(basename "$0")

usage() {
    printf 'Usage: %s input_file\n' "$prog" >&2
    printf '       %s - output_stem < input_file\n' "$prog" >&2
    printf '       %s input_file output_stem\n' "$prog" >&2
    exit 1
}

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf '%s: required command "%s" not found\n' "$prog" "$1" >&2
        exit 1
    fi
}

# ----- arguments ---------------------------------------------------------
[ "$#" -eq 0 ] && usage

infile="$1"

if [ "$#" -eq 1 ]; then
    # One argument: must be an existing file; derive stem from it.
    [ "$infile" = "-" ] && usage
    [ -f "$infile" ] || { printf '%s: file not found: %s\n' "$prog" "$infile" >&2; exit 1; }
    stem="${infile%.*}"
    [ "$stem" = "$infile" ] && stem="$infile"
elif [ "$#" -eq 2 ]; then
    stem="$2"
    if [ "$infile" != "-" ] && [ ! -f "$infile" ]; then
        printf '%s: file not found: %s\n' "$prog" "$infile" >&2
        exit 1
    fi
else
    usage
fi

framed="${stem}.framed.zst"
idx="${stem}.index.tsv"
echo "Output files: $idx, $framed"

# ----- dependency checks -------------------------------------------------
need_cmd zstd
need_cmd awk
need_cmd wc
need_cmd cat

# ----- do not overwrite existing outputs ---------------------------------
[ -e "$framed" ] && { printf '%s: already exists: %s\n' "$prog" "$framed" >&2; exit 1; }
[ -e "$idx" ]    && { printf '%s: already exists: %s\n' "$prog" "$idx" >&2; exit 1; }

# ----- create empty outputs and set up cleanup on failure ----------------
: > "$framed"
: > "$idx"

success=0
cleanup() {
    if [ "$success" -ne 1 ]; then
        rm -f "$framed" "$idx"
    fi
}
trap cleanup EXIT INT TERM HUP

TARGET=$((300 * 1024 * 1024))   # ~300 MB uncompressed per frame
SENTINEL='~~~~EOF~~~~'

# ----- main pipeline -----------------------------------------------------
input_source() {
    if [ "$infile" = "-" ]; then
        cat
    else
        cat -- "$infile"
    fi
}

input_source | awk -F '\t' \
    -v infile="$infile" \
    -v framed="$framed" \
    -v idx="$idx" \
    -v target="$TARGET" \
    -v sentinel="$SENTINEL" \
'
function die(msg) {
    printf "%s: line %d: %s\n", infile, NR, msg > "/dev/stderr"
    exit 1
}

function file_size() {
    cmd = "wc -c < \"" framed "\""
    cmd | getline sz
    close(cmd)
    return sz + 0
}

function write_index(key, off) {
    printf "%s\t%s\n", key, off >> idx
}

function open_pipe() {
    frame_num++
    # Unique command string so awk opens a fresh pipe for each frame.
    pipe_cmd = "zstd -T0 -c >> \"" framed "\" # frame " frame_num
}

BEGIN {
    frame_num = 0
    frame_size = 0
    first_key = ""
    prev_key = ""
    pipe_cmd = ""
}

{
    if (NF < 1) die("empty record")

    key = $1
    line_len = length($0) + 1   # +1 for the newline awk adds with print

    if (frame_num == 0) {
        # Very first record: start frame 1 at byte offset 0.
        write_index(key, 0)
        open_pipe()
        first_key = key
    }
    else if (key != prev_key && frame_size >= target) {
        # Key changed and current frame is big enough: seal it and start a new one.

        close(pipe_cmd)
        off = file_size()
	printf "frame %d finished: lines=%d bytes=%d first_key=%s\n", frame_num, NR, off, first_key > "/dev/stderr"
        write_index(key, off)
        open_pipe()
        first_key = key
        frame_size = 0
    }

    print | pipe_cmd
    frame_size += line_len
    prev_key = key
}

END {
    if (frame_num > 0) {
        close(pipe_cmd)
    }
    off = file_size()
    printf "%s\t%s\n", sentinel, off >> idx
    close(idx)
}
'

success=1
