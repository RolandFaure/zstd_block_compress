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
# Output (stdout):
#   - one "search:" line per binary-search step, then the chosen frame
#   - then the matching records:
#       *.tsv* data: lines whose first tab-separated field equals KEY
#       otherwise:   lines ending in KEY, plus the line after each (grep -A 1)
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

# The key is passed to awk through the environment (no backslash mangling)
# and every comparison concatenates "" so it is always a string comparison.
QZ_KEY=$key
export QZ_KEY

# fd 3 = real stdout, so awk can print search steps even when its other
# output is captured by $(...).
exec 3>&1

# ----- binary search on the index file, by byte position -----------------
# Invariant:
#   lo = byte offset of a line start whose key is <= KEY
#   hi = byte position such that the first line starting at or after hi
#        has a key > KEY, or there is no such line (hi = file size)
# When hi = lo + 1, no line starts between them, so the line at lo is the
# rightmost frame whose first key is <= KEY.

# The first line must qualify, otherwise the key precedes every frame.
if ! head -n 1 "$idx" | awk -F '\t' '
    NR == 1 {
        q = ENVIRON["QZ_KEY"] ""
        if (($1 "") <= q) {
            exit 0
        }
        printf "search: start: first_key=\"%s\" > \"%s\" -> no frame can contain the key\n", $1, q
        exit 1
    }'
then
    die "key sorts before the first frame"
fi

lo=0
hi=$idx_size
step=0

while [ $((hi - lo)) -gt 1 ]; do
    mid=$(( (lo + hi) / 2 ))
    step=$((step + 1))

    # Read from byte mid-1: the first (possibly empty) fragment is the rest
    # of the line that byte belongs to, the second line is the first line
    # starting at or after mid. tail -c on a regular file seeks, so this
    # costs a couple of lines of I/O, not the whole file.
    probe=$(tail -c +"$mid" "$idx" | head -n 2 | awk -F '\t' \
        -v lo="$lo" -v hi="$hi" -v mid="$mid" -v step="$step" '
        NR == 1 { s = mid - 1 + length($0) + 1; next }
        NR == 2 { found = 1; k = $1 "" }
        END {
            q   = ENVIRON["QZ_KEY"] ""
            out = "cat >&3"
            if (!found) {
                    step, lo, hi, mid | out
                print "left"
            } else if (k <= q) {
                    step, lo, hi, mid, s, k, q | out
                print "right", s
            } else {
                    step, lo, hi, mid, s, k, q | out
                print "left"
            }
            close(out)
        }')

    set -- $probe
    if [ "$1" = right ]; then
        lo=$2
    else
        hi=$mid
    fi
done

# ----- frame offset and length --------------------------------------------
# The line at lo is the chosen frame; the next line (if any) gives its end.
range=$(tail -c +"$((lo + 1))" "$idx" | head -n 2 | awk -F '\t' \
    -v size="$data_size" -v prog="$prog" -v lo="$lo" '
    NR == 1 { k = $1; start = $2 + 0 }
    NR == 2 { end = $2 + 0 }
    END {
        if (NR < 2) end = size + 0
        len = end - start
            lo, k, start, len | "cat >&3"
        close("cat >&3")
        if (len <= 0) {
            print prog ": bad index: frame has non-positive length" | "cat >&2"
            exit 1
        }
        print start, len
    }')

set -- $range
start=$1
len=$2

# ----- extract that one frame and filter ---------------------------------
case $framed in
    *.tsv*)
        tail -c +"$((start + 1))" "$framed" | head -c "$len" | zstd -dc |
            awk -F '\t' 'BEGIN { k = ENVIRON["QZ_KEY"] "" } ($1 "") == k'
        ;;
    *)
        tail -c +"$((start + 1))" "$framed" | head -c "$len" | zstd -dc |
            grep -A 1 -e "$key\$"
        ;;
esac
