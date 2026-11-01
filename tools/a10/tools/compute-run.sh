#!/bin/busybox sh
# Minimal CDM stream probe. MODE=ram (default) or MODE=real (actual GPU DMA).
# Default hook 26 is historical/provisional; real mode may hang the GPU.
# HOOK=/run/agx-init46.sh is the validated terminate-only baseline. Later PDS
# hooks may dispatch non-empty tasks; none has demonstrated USC shader results.
set -eu
MODE=${MODE:-ram}
case "$MODE" in
    ram) export RGX_REAL=0 ;;
    real) export RGX_REAL=1 ;;
    *) echo 'MODE must be ram or real' >&2; exit 1 ;;
esac
export E0PA=0x201d00000 ESIZE=0x5000
export BEFORE_INIT=${HOOK:-/run/agx-init26.sh}
. /run/agx-init12.sh
put32 scratch 0x11028 1
echo '21 83000000000000' > "$D/send"
if [ "$MODE" = ram ]; then
    i=0
    while [ $i -lt 12 ]; do
        for off in 0x11f00 0xcd8 0xcb8; do put32 scratch $((0x380000 + off)) 0; done
        sleep 0.05
        i=$((i + 1))
    done
else
    i=0
    while [ $i -lt 50 ]; do
        stamp=$(rd32 scratch 0x55004)
        [ "$stamp" = 00000001 ] && break
        [ "$(wc -c < "$D/crashlog")" -eq 0 ] || break
        sleep 0.1
        i=$((i + 1))
    done
fi
echo "MODE=$MODE, completion stamps:"
dd if="$D/scratch" bs=1 skip=$((0x55000)) count=8 2>/dev/null | hexdump -C
echo 'Compute scheduling entry:'
dd if="$D/scratch" bs=1 skip=$((0x50000)) count=44 2>/dev/null | hexdump -C
echo 'Legacy/private unit shadow (not shared state after hook 29):'
dd if="$D/scratch" bs=1 skip=$((0x56000)) count=24 2>/dev/null | hexdump -C
wc -c "$D/crashlog"
strings "$D/crashlog" | head -25
if [ "$MODE" = real ]; then
    echo 'Real RGX state (read-only):'
    for off in 0x130 0x478 0x480 0x498 0x49c 0x4a0 0xe150; do
        printf '%s ' "$off"; devmem $((0x201000000 + off)) 32
    done
fi
[ "$(wc -c < "$D/crashlog")" -eq 0 ] || exit 1
if [ "$MODE" = real ] && [ "$(rd32 scratch 0x55004)" != 00000001 ]; then
    echo 'INCOMPLETE: no host completion stamp; not evidence of GPU execution'
    exit 2
fi
