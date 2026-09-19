# Audio fixtures

Three tiny files (26 KB total) that let the audio gate run on a machine with
nothing installed. Committed here on purpose: the decode path is exactly what
must work on a bare Mac, so it cannot depend on a dev-time artifact directory or
on Homebrew's ffmpeg.

Provenance — each was produced with ffmpeg, and can be regenerated with:

```sh
# a 3 s video (32×32, 5 fps) with a 440 Hz mono AAC track
ffmpeg -f lavfi -i "testsrc=size=32x32:rate=5:duration=3" \
       -f lavfi -i "sine=frequency=440:duration=3" \
       -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 32k -shortest tone-3s.mp4

# a 2 s video with a digital-silence AAC track
ffmpeg -f lavfi -i "testsrc=size=32x32:rate=5:duration=2" \
       -f lavfi -i "anullsrc=r=44100:cl=mono" \
       -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 32k -shortest silent-2s.mp4

# a 2 s video with no audio track at all
ffmpeg -f lavfi -i "testsrc=size=32x32:rate=5:duration=2" \
       -c:v libx264 -pix_fmt yuv420p no-audio-2s.mp4
```

The gate does not need ffmpeg to run — only to regenerate these.
