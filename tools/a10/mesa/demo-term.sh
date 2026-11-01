#!/bin/sh
# What the demo's foot windows show (hypr-demo.sh), in the terminal theme's
# 16 colours: demo-term.sh info|palette|clock
case $1 in
info)
    printf '\n  \033[1;32mHyprland\033[0m on an iPad 6\n\n'
    printf '  \033[36mGPU\033[0m    Apple A10 (PowerVR-derived), drm/imagination\n'
    printf '  \033[36mVulkan\033[0m Mesa G9P + Zink\n'
    printf '  \033[36mKernel\033[0m %s\n\n' "$(uname -r)"
    printf '  \033[90mblur, translucency and animations,\n  all rendered on the GPU\033[0m\n' ;;
palette)
    printf '\n'
    for bright in 0 1; do
        for line in 1 2; do
            printf '  '
            for c in 0 1 2 3 4 5 6 7; do printf '\033[%dm      ' $((40 + 60 * bright + c)); done
            printf '\033[0m\n'
        done
    done ;;
clock)
    while :; do printf '\033[H\033[2J\n\n   \033[1;32m%s\033[0m\n' "$(date +%H:%M:%S)"; sleep 1; done ;;
esac
exec sleep 100000
