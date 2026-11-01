#!/bin/sh
# The Jade Horse demo's wallpaper (hypr-demo.sh SECONDS jade): Omarchy's
# ink horse (https://github.com/basecamp/omarchy, themes/jade-horse, commit
# 9e0b5e2f2759), downloaded and cropped to the iPad's portrait 1536x2048
# around the horse. Not kept in this repository; needs ImageMagick:
#
#   mesa/jade-wallpaper.sh OUT.png
set -eu
URL=https://raw.githubusercontent.com/basecamp/omarchy/9e0b5e2f275964db85310bf9ab6fadb6a299839c/themes/jade-horse/backgrounds/02-ink-horse.webp
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL --max-time 120 -o "$TMP/horse.webp" "$URL"
# 6688x3764: a 3:4 window of the full height, the horse in its left third
magick "$TMP/horse.webp" -crop 2823x3764+3500+0 +repage -resize '1536x2048!' "$1"
