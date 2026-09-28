#!/bin/sh
# finish.sh <poster-seconds> -> ../promo.mp4 (poster baked into frame 0, audio muxed) + ../promo.jpg
set -e
cd "$(dirname "$0")"
node render.mjs stills "$1" >/dev/null
cp "stills/t-$1.png" poster.png
ffmpeg -loglevel error -y -i poster.png -q:v 2 ../promo.jpg
node audio.mjs

# Two-pass loudnorm to -16 LUFS, true peak -1.5 dBTP.
m=$(ffmpeg -hide_banner -i music.wav -af loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json -f null - 2>&1 | sed -n '/^{/,/^}/p')
get() { echo "$m" | sed -n "s/.*\"$1\" : \"\(.*\)\".*/\1/p"; }
ffmpeg -loglevel error -y -i music.wav -af "loudnorm=I=-16:TP=-1.5:LRA=11:measured_I=$(get input_i):measured_TP=$(get input_tp):measured_LRA=$(get input_lra):measured_thresh=$(get input_thresh):offset=$(get target_offset):linear=true,aresample=48000" -c:a pcm_s16le music-norm.wav

ffmpeg -loglevel error -y -i video.mp4 -i poster.png -i music-norm.wav \
  -filter_complex "[0:v][1:v]overlay=enable='eq(n,0)',format=yuv420p[v]" -map "[v]" -map 2:a \
  -c:v libx264 -crf 17 -preset slow -profile:v high -movflags +faststart \
  -c:a aac -b:a 256k -shortest ../promo.mp4
