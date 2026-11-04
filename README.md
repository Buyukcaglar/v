# V

A small, fast image viewer for macOS, in the style of the Picasa Photo Viewer. The desktop dims, the
photo grows out of the middle of the screen, and a filmstrip of the folder's other photos sits
along the bottom. Close it and it's gone.

V is a single native AppKit app written in Swift, with no dependencies. It opens anything ImageIO can
decode: JPEG, HEIC, PNG, TIFF, GIF (animated), WebP, AVIF, camera RAW and more.

## Features

- Opens instantly from Finder and shows a sharp photo in tens of milliseconds, even in folders of
  10,000 photos.
- Keeps memory low while browsing: only the current photo and its neighbours stay decoded, at the
  size your screen needs. Full resolution is loaded only when you zoom in past that.
- Zoom around the pointer with the mouse wheel or a trackpad pinch, and pan by dragging. 1:1 shows
  the photo at its actual size.
- Circle what matters with the pen, in 16 colours and three line widths, and save a copy with the
  marks drawn in next to the photo.
- Slideshow, rotate, copy, show in Finder and move to Trash.
- Can make itself the default viewer for every image type in one step.

## Requirements

macOS 13 Ventura or later, on Apple silicon or Intel.

## Install

Download `V.zip` from the [latest release](https://github.com/Buyukcaglar/v/releases/latest), unzip
it and move `V.app` to Applications.

V isn't notarized, so macOS blocks the first launch. Either open it once and choose **Open Anyway**
in System Settings › Privacy & Security, or clear the download flag in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/V.app
```

To make V your default image viewer, choose **V › Make Default Image Viewer**.

## Build from source

The Xcode command-line tools are enough; there is no Xcode project.

```bash
./build.sh
```

This builds a universal `build.noindex/V.app`. `./install.sh` copies it to `/Applications` and makes
it the default viewer for all image types. That rewrites the Launch Services handler table and
restarts `lsd`.

## Keys

| Key | Action |
|---|---|
| → ↓ Space Page Down | Next photo |
| ← ↑ ⇧Space Page Up | Previous photo |
| Home / End | First / last photo |
| + / − | Zoom in / out |
| 0 or 1, ⌘0 | Actual size |
| 9, ⌘9 | Zoom to fit |
| ⌘L / ⌘R | Rotate left / right |
| P | Pen on / off |
| ⌘S, ⌃S | Save a copy with the marks |
| ⌘Z / ⇧⌘Z | Undo / redo a mark |
| ⇧⌘F | Start slideshow |
| ⌘C | Copy |
| ⇧⌘R | Show in Finder |
| ⌘⌫ | Move to Trash |
| Esc, ⌘W | Put the pen away, stop slideshow / close |

Clicking the dimmed background also closes the viewer. Right-clicking the photo offers Copy Image and
Show in Finder.

## Marking up photos

With the pen on, the colours and line widths take the filmstrip's place. Drag across the photo to
draw an ellipse; hold ⇧ for a circle or ⌥ to draw from the centre. Lines are 1, 3 or 5 pixels on
screen at the zoom you draw at, so at 1:1 they are that many pixels of the photo. The marks stay on
the photo, turned and zoomed with it, until the viewer closes; V asks before closing with marks that
aren't saved.

⌘S saves a copy with the marks drawn in next to the photo, as `IMG_1234_markdown.JPG`, upright and
turned as on screen. Formats macOS can't write, such as camera RAW and WebP, are saved as JPEG (PNG
when they have transparency), and an animated GIF is saved as a still.

## Performance tools

`tools/perf/run.sh` builds a harness from the current sources and measures decode cost, memory
and responsiveness on synthetic photos (about 230 MB, made once in `$TMPDIR`). The window it
drives is invisible. `docs/performance-audit.md` explains the measurements.

## License

[MIT](LICENSE). V is not affiliated with Google; Picasa is a trademark of Google LLC.
