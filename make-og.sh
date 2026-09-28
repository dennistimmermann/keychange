#!/bin/sh
# The share assets, cut from the promo video (docs/promo) so the link preview, the posts
# and the video are one look. The 1080p original to attach to a post is the promo itself,
# docs/promo/promo.mp4.
#
#   og.jpg  its end card, cropped to 1.91:1 at 1200x630 (og:image); a JPEG under 300 KB,
#           since WhatsApp drops a preview image any larger
#   og.mp4  a 720p copy for og:video, the few previews that play one (Discord, Telegram)
#   og.gif  the switch scene between two end cards, a loop for where only GIFs play
#
# Re-run after re-rendering the video (docs/promo/work/finish.sh).
set -e
cd "$(dirname "$0")"
video=docs/promo/promo.mp4
poster=docs/promo/work/poster.png
out=docs/share

# The end card holds still from 15.1s; its poster frame is the settled one.
ffmpeg -loglevel error -y -i "$poster" \
  -vf "crop=1920:1008:0:36,scale=1200:630:flags=lanczos" -q:v 3 "$out/og.jpg"

# A preview plays small and should start fast.
ffmpeg -loglevel error -y -i "$video" -vf "scale=1280:720:flags=lanczos" \
  -c:v libx264 -crf 23 -preset slow -pix_fmt yuv420p -movflags +faststart \
  -c:a aac -b:a 128k "$out/og.mp4"

# The end card, then the keypress scene through the video's own wipe back into the end card,
# which holds until the loop comes round to it again: most places show a GIF's first frame
# as its still, and first and last frame match, so the loop has no seam.
ffmpeg -loglevel error -y -loop 1 -framerate 12 -t 1 -i "$poster" \
  -ss 8.6 -to 17 -i "$video" -filter_complex \
  "[0:v]fps=12,crop=1920:1008:0:36,scale=800:420:flags=lanczos,setsar=1[a]; \
   [1:v]fps=12,crop=1920:1008:0:36,scale=800:420:flags=lanczos,setsar=1[b]; \
   [a][b]concat=n=2:v=1,split[c][d];[c]palettegen=max_colors=96:stats_mode=diff[p]; \
   [d][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  -loop 0 "$out/og.gif"
