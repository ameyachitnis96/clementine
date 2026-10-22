# Clementine

A free, open-source file converter and toolbox that lives in your Mac's menu bar. Start dragging a file, tap a key, and a radial menu opens at the pointer. Drop the file on an option. Everything runs offline, and results are saved next to the original.

Requires macOS 14 or later.

## Use

Drag any file or folder, then hold:

| Key | Opens | Examples |
|---|---|---|
| ⇧ Shift | Convert formats | HEIC → PNG, MP4 → GIF, DOCX → PDF |
| ⌘ Command | File tools | Compress, crop, trim, redact, annotate, split or merge PDFs, extract archives |
| ⌃ Control | File actions | AirDrop, Float (shelf), Copy, Move, Copy Path, Terminal |

You can change the keys in Settings. Outputs never overwrite the original.

### Tools by file type

- **Images:** compress, strip metadata, resize, rotate, read QR codes, edit, annotate, add a background, crop, redact faces or text; combine several into a PDF or a collage.
- **Video:** compress, strip metadata, mute, trim, split, crop, speed up, save a frame, redact, extract audio; join several clips.
- **Audio:** compress, strip metadata, normalize, trim, mono or stereo, bleep, turn into a waveform video.
- **PDF:** compress, strip metadata, split, merge, reorder or delete pages, export pages as images.
- **Archives:** extract ZIP, TAR, GZIP and RAR into a folder (paths are validated before anything is written).

### Shelf

Push a file drag against the right screen edge, or choose Float, to keep files in a floating shelf you can drag out of later.

## Build

```bash
./build-app.sh
```

This produces `dist/Clementine.app` (ad-hoc signed). It needs only the Xcode Command Line Tools with Swift 6. Optionally run `brew install ffmpeg webp` to enable MP3, FLAC and MKV, WebP output, and faster metadata stripping.

## Command line

The same engine runs headless:

```bash
Clementine --convert png photo.heic
Clementine --tool removeMetadata photo.jpg
Clementine --crop 0.1,0.1,0.8,0.8 clip.mov    # normalized x,y,w,h
Clementine --trim 1.5 4 song.m4a
```

## Test

```bash
swift test
```

## License

MIT. See [LICENSE](LICENSE).
