#!/bin/busybox sh
# Reproducible T8010/J71b power, real-register init, control-ring and ARM-map test.
# Stage init12..15 and fender-power-on.sh in /run; run this script manually.
# Reloads the experiment module. RAM-only, no storage writes and NO GPU jobs.
set -eu
export E0PA=0x201d00000 ESIZE=0x5000 BEFORE_INIT=/run/agx-init15.sh
unset SEQFILE
. /run/agx-init12.sh

kick() { echo '21 83000000000000' > "$D/send"; }
expect32() { # scratch offset, expected value; bounded asynchronous readback
    off=$1; expected=$2; tries=0
    while [ $tries -lt 100 ]; do
        value=$(rd32 scratch "$off")
        [ "$((0x$value))" -eq "$expected" ] && return 0
        sleep 0.01
        tries=$((tries + 1))
    done
    echo "FAIL scratch+$off: $value, expected $expected" >&2
    exit 1
}
no_crash() {
    bytes=$(wc -c < "$D/crashlog")
    [ "$bytes" -eq 0 ] || { echo "FAIL: $bytes byte firmware crashlog" >&2; exit 1; }
}
expect32 0x5014 1
# Initial kick runs fixed firmware RGX setup; the ring is empty.
kick
# Put an inert (opcode 0, ignored by firmware) control entry on ring 12.
# read index = +0x110c0, cache index = +0x110c4, write index = +0x110c8.
put32 scratch 0x110c8 1
kick
expect32 0x110c0 1
expect32 0x110c4 1
no_crash
echo 'PASS: real-register init and control ring consumption'

# Map two unused scratch pages into the IOP ARM VA space at 0x140000.
# This is NOT proof of GPU MMU mapping: the consumer is the ARM firmware.
put32 scratch 0x25000 0x140000
put32 scratch 0x25004 $(((S + 0x3a000) >> 12))
put32 scratch 0x25008 0
put16 scratch 0x2500c 2
put16 scratch 0x2500e 1
put32 scratch 0x24010 1
kick
expect32 0x24000 1
# Read the next inert entry through that new mapping, not the initial ring VA.
put32 scratch 0xd8 0x140000
put32 scratch 0x110c8 2
kick
expect32 0x110c0 2
expect32 0x110c4 2
no_crash
echo 'PASS: runtime ARM mapping and control-ring access through new VA'
sh /run/fender-power-on.sh
[ "$(devmem 0x201d02058 32)" = 0x00000000 ] || { echo 'FAIL: reset stuck' >&2; exit 1; }
[ "$(devmem 0x20100e208 32)" = 0x4BD22DB4 ] || { echo 'FAIL: RGX init pattern missing' >&2; exit 1; }
echo 'PASS: bring-up smoke only; no shader, compute, or rendering tested'
