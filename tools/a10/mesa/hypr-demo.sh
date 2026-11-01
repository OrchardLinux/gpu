#!/bin/sh
# Hyprland demo on the iPad's screen, no keyboard needed (device host side):
# starts Hyprland in one of two styles and plays a loop of window actions
# through hyprctl for SECONDS (default 120): focus changes, a floating window
# gliding over the wallpaper (blur), split toggles, a workspace switch and
# windows opening and closing (Hyprland started by hypr-start.sh). Pushed by
# setup-device.sh with the configs, demo-term.sh and the wallpapers:
#
#   hypr-demo.sh [SECONDS] [demo|jade]
#     demo   hyprland-demo.lua, every effect, over demo-wallpaper.py's image
#     jade   hyprland-jade.lua, Omarchy's Jade Horse look (jade-wallpaper.sh)
# DEMO_ENV passes variables to Hyprland (G9P_* debugging, MESA.md)
SECS=${1:-120}
STYLE=${2:-demo}
sh /run/hypr-start.sh "$STYLE" || exit 2
case $STYLE in
demo) TERM_CMD='foot -o colors-dark.alpha=0.45 -o colors-dark.blur=yes' ;;
jade) TERM_CMD='foot -c /root/foot-jade.ini' ;;
esac
D() {
    chroot /run/sid sh -c 'export XDG_RUNTIME_DIR=/run/user/0 HOME=/root HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/0/hypr | head -1)
        exec timeout -k 2 5 hyprctl dispatch "$1"' hyprctl "$1" > /dev/null 2>&1
    sleep "${2:-1}"
}
end=$(($(date +%s) + SECS))
while [ "$(date +%s)" -lt "$end" ]; do
    sleep 2
    D 'hl.dsp.window.cycle_next()' 1.2
    D 'hl.dsp.window.cycle_next()' 1.2
    D 'hl.dsp.layout("togglesplit")' 2
    # a floating window over the wallpaper: blur
    D 'hl.dsp.window.float({ action = "toggle" })' 0.5
    D 'hl.dsp.window.resize({ x = 460, y = 320 })' 0.5
    D 'hl.dsp.window.move({ x = 40, y = 360 })' 1.5
    D 'hl.dsp.window.move({ x = 280, y = 560 })' 1.5
    D 'hl.dsp.window.move({ x = 200, y = 120 })' 1.5
    D 'hl.dsp.window.center()' 1.5
    D 'hl.dsp.window.float({ action = "toggle" })' 2
    # an empty workspace shows the wallpaper; a window pops in and out
    D 'hl.dsp.focus({ workspace = 2 })' 1.5
    D "hl.dsp.exec_cmd(\"$TERM_CMD sh /root/demo-term.sh info\")" 3
    D 'hl.dsp.window.close()' 1.5
    D 'hl.dsp.focus({ workspace = 1 })' 1.5
    D 'hl.dsp.layout("togglesplit")' 1
done
D 'hl.dsp.exit()' 3
killall -9 Hyprland seatd foot 2>/dev/null
echo "GPU job timeouts: $(dmesg | grep -c 'timed out')"
