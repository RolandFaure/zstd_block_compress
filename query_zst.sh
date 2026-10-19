#!/bin/sh
# query_zst.sh index.tsv framed.zst key
#
# Looks up KEY in FRAMED.zst, a file made of independently compressed zstd
# frames, using INDEX.tsv (one line per frame: first key <TAB> byte offset,
# sorted by key in byte order, newline-terminated, no header).
#
# The index is binary-searched by byte position directly on disk, so a
# lookup reads about log2(index size) lines instead of the whole index.
#
# Prints the matching records:
#   *.tsv* data: lines whose first tab-separated field equals KEY
#   otherwise:   lines ending in KEY, plus the line after each (grep -A 1)
#
# Keys are always compared as text, in byte order (LC_ALL=C).

set -e
LC_ALL=C
export LC_ALL

prog=$(basename "$0")

die() {
    printf '%s: %s\n' "$prog" "$1" >&2
    exit 1
}

usage() {
    printf 'Usage: %s index.tsv framed.zst key\n' "$prog" >&2
    exit 1
}

need_cmd() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "required command \"$c\" not found"
    done
}

filesize() {
    wc -c < "$1" | tr -d ' \t'
}

# ----- arguments ---------------------------------------------------------
[ "$#" -eq 3 ] || usage
idx=$1
framed=$2
key=$3

[ -f "$idx" ]    || die "index not found: $idx"
[ -f "$framed" ] || die "framed file not found: $framed"
[ -s "$idx" ]    || die "empty index: $idx"

need_cmd zstd awk tail head wc tr grep

idx_size=$(filesize "$idx")
data_size=$(filesize "$framed")

# The key reaches awk through the environment (no backslash mangling), and
# every comparison concatenates "" so it is always a string comparison.
QZ_KEY=$key
export QZ_KEY

# ----- binary search on the index file, by byte position -----------------
# Invariant:
#   lo = byte offset of a line start whose key is <= KEY
#   hi = byte position such that the first line starting at or after hi
#        has a key > KEY, or there is no such line (hi = file size)
# When hi = lo + 1, the line at lo is the rightmost frame whose first
# key is <= KEY.

# The first line must qualify, otherwise the key precedes every frame.
head -n 1 "$idx" |
    awk -F '\t' 'NR == 1 { exit !(($1 "") <= ENVIRON["QZ_KEY"] "") }' ||
    die "key sorts before the first frame"

lo=0
hi=$idx_size

while [ $((hi - lo)) -gt 1 ]; do
    mid=$(( (lo + hi) / 2 ))

    # Read from byte mid-1: the first (possibly empty) fragment is the rest
    # of the line that byte belongs to; the second line is the first line
    # starting at or after mid. Prints its offset if its key is <= KEY.
    next=$(tail -c +"$mid" "$idx" | head -n 2 | awk -F '\t' -v mid="$mid" '
        NR == 1 { s = mid + length($0); next }
        NR == 2 { if (($1 "") <= ENVIRON["QZ_KEY"] "") print s; exit }')

    if [ -n "$next" ]; then
        lo=$next
    else
        hi=$mid
    fi
done

# ----- frame offset and length --------------------------------------------
# The line at lo is the chosen frame; the next line (if any) gives its end.
range=$(tail -c +"$((lo + 1))" "$idx" | head -n 2 | awk -F '\t' -v size="$data_size" '
    NR == 1 { start = $2 + 0 }
    NR == 2 { end = $2 + 0 }
    END {
        if (NR < 2) end = size + 0
        if (end <= start) exit 1
        print start, end - start
    }') || die "bad index: frame at index byte $lo has non-positive length"

set -- $range
start=$1
len=$2

# ----- extract that one frame and filter ---------------------------------
case $framed in
    *.tsv*)
        tail -c +"$((start + 1))" "$framed" | head -c "$len" | zstd -dc |
            awk 'BEGIN { k = ENVIRON["QZ_KEY"] "" } ($1 "") == k'
        ;;
    *)
        tail -c +"$((start + 1))" "$framed" | head -c "$len" | zstd -dc |
            grep -A 1 -e "$key\$"
        ;;
esac
