#!/bin/sh
# Replays the baseline-46 bring-up (compute-run.sh MODE=real, HOOK=46) on the
# host against local files instead of debugfs, producing the exact firmware
# window and scratch images plus a log of register writes and mailbox
# messages. The kernel driver's firmware layout is checked against these.
#
#   tools/golden.sh OUTDIR [HOOK]      (HOOK defaults to 46)
#
# Uses the device's observed addresses: window 0x802100000, scratch
# 0x802400000. Hardware access is stubbed: devmem writes are logged and the
# Fender power-state register acknowledges requests 0x10/0x11.
set -eu
OUT=$1
HOOK=${2:-46}
TOOLS=$(cd "$(dirname "$0")" && pwd)
rm -rf "$OUT" && mkdir -p "$OUT/run" "$OUT/debugfs/apple_gpu_iop" "$OUT/bin"
D=$OUT/debugfs/apple_gpu_iop
dd if=/dev/zero of="$D/mem" bs=1024 count=1024 2>/dev/null
dd if=/dev/zero of="$D/scratch" bs=1024 count=4096 2>/dev/null
: > "$D/crashlog"
: > "$OUT/devmem.log"

# Scripts reference /run and the debugfs path; point both at OUT.
for f in "$TOOLS"/agx-init*.sh "$TOOLS"/compute-run.sh "$TOOLS"/fender-power-on.sh; do
    sed -e "s|/run/|$OUT/run/|g" -e "s|/sys/kernel/debug/apple_gpu_iop|$D|g" \
        -e 's|^#!/bin/busybox sh|#!/bin/sh|' -e 's|> \$D/send|>> $D/send|' -e 's|> "\$D/send"|>> "$D/send"|' "$f" > "$OUT/run/$(basename "$f")"
done

cat > "$OUT/bin/devmem" <<EOF
#!/bin/sh
# devmem ADDR [WIDTH [VALUE]]: log writes; Fender state follows requests.
state=$OUT/fender-state
if [ \$# -ge 3 ]; then
    echo "write \$1 \$2 \$3" >> $OUT/devmem.log
    [ "\$((\$1))" = "\$((0x201d01000))" ] && printf '%s' "\$((\$3 & 0xf))" > \$state
    exit 0
fi
if [ "\$((\$1))" = "\$((0x201d01000))" ]; then printf '0x%08X\n' "\$(cat \$state 2>/dev/null || echo 0)"; else echo 0x00000000; fi
EOF
cat > "$OUT/bin/dmesg" <<'EOF'
#!/bin/sh
echo 'apple-gpu-iop 201000000.gpu: GFX firmware up, window 0x802100000'
echo 'apple-gpu-iop 201000000.gpu: scratch 0x802400000 + 0x400000'
EOF
for stub in rmmod insmod mountpoint sleep; do printf '#!/bin/sh\nexit 0\n' > "$OUT/bin/$stub"; done
chmod +x "$OUT/bin/"*

# The mailbox "send" file collects the messages in order.
: > "$D/send"
PATH="$OUT/bin:$PATH" MODE=real HOOK="$OUT/run/agx-init$HOOK.sh" \
    sh "$OUT/run/compute-run.sh" > "$OUT/run.log" 2>&1 || true
cp "$D/mem" "$OUT/window.bin"
cp "$D/scratch" "$OUT/scratch.bin"
cp "$D/send" "$OUT/send.log"
echo "golden images in $OUT: window.bin scratch.bin devmem.log send.log run.log"
