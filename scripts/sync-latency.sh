#!/usr/bin/env bash
# Measure how long Resilio Sync takes to propagate changes between two linked folders.
#
# Usage: scripts/sync-latency.sh <dir-A> <dir-B> [timeout-seconds] [idle-seconds]
#
# Each case starts after <idle-seconds> (default 15) without changes, because Sync batches
# change announcements to a peer roughly every 10 s (docs/research/resilio-sync-speed.md).
# Case start times are printed in UTC so they can be matched against Sync logs.
#
# Only touches a dedicated sub-folder (_sync-latency-test/) in each folder and removes it at exit.
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <dir-A> <dir-B> [timeout-seconds=180] [idle-seconds=15]" >&2
    exit 2
fi

A_ROOT=${1%/}
B_ROOT=${2%/}
TIMEOUT=${3:-180}
IDLE=${4:-15}
TEST_DIR=_sync-latency-test
A="$A_ROOT/$TEST_DIR"
B="$B_ROOT/$TEST_DIR"

for root in "$A_ROOT" "$B_ROOT"; do
    [[ -d "$root" ]] || { echo "Not a directory: $root" >&2; exit 2; }
    [[ -e "$root/$TEST_DIR" ]] && { echo "$root/$TEST_DIR already exists; remove it first" >&2; exit 2; }
done

now() { date +%s.%N; }
elapsed() { awk -v s="$1" -v e="$(now)" 'BEGIN { printf "%.1f", e - s }'; }
hash_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# wait_for <file> <sha256> <start>: print seconds until <file> has <sha256>, or TIMEOUT
wait_for() {
    local file=$1 want=$2 start=$3
    while true; do
        [[ "$(hash_of "$file")" == "$want" ]] && { elapsed "$start"; return; }
        awk -v s="$start" -v e="$(now)" -v t="$TIMEOUT" 'BEGIN { exit !(e - s > t) }' && { echo TIMEOUT; return; }
        sleep 0.2
    done
}

# wait_gone <file> <start>: print seconds until <file> no longer exists, or TIMEOUT
wait_gone() {
    local file=$1 start=$2
    while [[ -e "$file" ]]; do
        awk -v s="$start" -v e="$(now)" -v t="$TIMEOUT" 'BEGIN { exit !(e - s > t) }' && { echo TIMEOUT; return; }
        sleep 0.2
    done
    elapsed "$start"
}

cleanup() {
    rm -rf "$A"
    echo "Removed $A; waiting for the delete to reach B..."
    local result
    result=$(wait_gone "$B" "$(now)")
    if [[ $result == TIMEOUT ]]; then
        echo "Delete didn't propagate within ${TIMEOUT}s; removing $B directly"
        rm -rf "$B"
    fi
}
trap cleanup EXIT

declare -a ROWS
# idle <label>: wait IDLE seconds so the case starts outside the previous batch window
idle() { sleep "$IDLE"; echo "  [$(date -u +%H:%M:%S.%3N) UTC] start: $1"; }
record() { ROWS+=("$(printf '%-36s %10s' "$1" "$2")"); echo "  $1: $2"; }

echo "A: $A_ROOT"
echo "B: $B_ROOT"
echo "Timeout per case: ${TIMEOUT}s, idle before each case: ${IDLE}s"
echo

# 1. New small file A -> B
idle "case 1"
mkdir -p "$A"
f="note-a.md"
printf '# latency test\n\n%s\n' "$(date -Is)" > "$A/$f.tmp" && mv "$A/$f.tmp" "$A/$f"
start=$(now)
record "1. new small file A -> B" "$(wait_for "$B/$f" "$(hash_of "$A/$f")" "$start")"

# 2. New small file B -> A
idle "case 2"
mkdir -p "$B"
f="note-b.md"
printf '# latency test\n\n%s\n' "$(date -Is)" > "$B/$f"
start=$(now)
record "2. new small file B -> A" "$(wait_for "$A/$f" "$(hash_of "$B/$f")" "$start")"

# 3. Edit an existing file A -> B
idle "case 3"
f="note-a.md"
printf 'edited %s\n' "$(date -Is)" >> "$A/$f"
start=$(now)
record "3. edit existing file A -> B" "$(wait_for "$B/$f" "$(hash_of "$A/$f")" "$start")"

# 4. 50 small files A -> B (time until the last one lands)
idle "case 4"
mkdir -p "$A/batch"
for i in $(seq -w 1 50); do printf 'file %s %s\n' "$i" "$RANDOM" > "$A/batch/n$i.md"; done
start=$(now)
for i in $(seq -w 1 49); do wait_for "$B/batch/n$i.md" "$(hash_of "$A/batch/n$i.md")" "$start" > /dev/null; done
record "4. 50 small files A -> B" "$(wait_for "$B/batch/n50.md" "$(hash_of "$A/batch/n50.md")" "$start")"

# 5. 10 MB file A -> B
idle "case 5"
head -c 10M /dev/urandom > "$A/big.bin"
start=$(now)
record "5. 10 MB file A -> B" "$(wait_for "$B/big.bin" "$(hash_of "$A/big.bin")" "$start")"

# 6. Delete A -> B
idle "case 6"
rm "$A/big.bin"
start=$(now)
record "6. delete file A -> B" "$(wait_gone "$B/big.bin" "$start")"

echo
printf '%-36s %10s\n' "Case" "Seconds"
printf '%s\n' "${ROWS[@]}"
