#!/bin/sh
# query_zst.sh index.tsv framed.zst key
# Prints every line from framed.zst whose third column equals key.

set -e
LC_ALL=C
export LC_ALL

prog=$(basename "$0")

usage() {
    printf 'Usage: %s index.tsv framed.zst key\n' "$prog" >&2
    exit 1
}

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf '%s: required command "%s" not found\n' "$prog" "$1" >&2
        exit 1
    fi
}

# ----- arguments ---------------------------------------------------------
[ "$#" -eq 3 ] || usage
idx="$1"
framed="$2"
key="$3"

[ -f "$idx" ]    || { printf '%s: index not found: %s\n' "$prog" "$idx" >&2; exit 1; }
[ -f "$framed" ] || { printf '%s: framed file not found: %s\n' "$prog" "$framed" >&2; exit 1; }

need_cmd zstd
need_cmd awk
need_cmd tail
need_cmd head

# ----- binary search in the index ----------------------------------------
# Find the rightmost frame whose first key is <= the query key.
range=$(awk -F '\t' -v q="$key" '
    { keys[NR] = $1; offs[NR] = $2 }
    END {
        n = NR
        if (n < 1) { print "error: empty index" > "/dev/stderr"; exit 1 }

        lo = 1; hi = n; ans = 0
        while (lo <= hi) {
            mid = int((lo + hi) / 2)
            if (keys[mid] <= q) { ans = mid; lo = mid + 1 }
            else                { hi = mid - 1 }
        }

        if (ans == 0) { print "error: key is before the first frame" > "/dev/stderr"; exit 1 }

        start   = offs[ans]
        nextoff = (ans < n) ? offs[ans + 1] : offs[NR]
        len     = nextoff - start
        print start, len
    }
' $idx)

echo "looking into range "$range
set -- $range
start=$1
len=$2

# ----- extract that one frame and filter ---------------------------------
if [[ $framed == *.tsv* ]]; then
    tail -c +$((start + 1)) "$framed" | head -c "$len" | zstd -dc | \
    	awk -v k="$key" '$1 == k'
else
    tail -c +$((start + 1)) "$framed" | head -c "$len" | zstd -dc | \
        grep -A 1 "$key$"
fi
