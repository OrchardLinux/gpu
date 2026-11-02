#!/bin/sh
# Writes the video phase's test clips into video/ (not in git): 30 s of
# moving test pattern with noise, so they decode like camera footage, at
# YouTube-like bitrates. Needs ffmpeg with libvpx and libx264.
set -eu
cd "$(dirname "$0")" && mkdir -p video
src() { echo "testsrc2=size=$1:rate=30,noise=alls=12:allf=t+u,format=yuv420p"; }
ffmpeg -loglevel error -y -f lavfi -i "$(src 1280x720)" -t 30 -c:v libvpx-vp9 -b:v 2500k \
  -deadline realtime -cpu-used 8 -row-mt 1 video/vp9-720.webm
ffmpeg -loglevel error -y -f lavfi -i "$(src 1920x1080)" -t 30 -c:v libvpx-vp9 -b:v 4500k \
  -deadline realtime -cpu-used 8 -row-mt 1 video/vp9-1080.webm
ffmpeg -loglevel error -y -f lavfi -i "$(src 1280x720)" -t 30 -c:v libx264 -profile:v high \
  -b:v 2500k -preset fast -movflags +faststart video/h264-720.mp4
ls -l video
