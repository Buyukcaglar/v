You're working on V, a small AppKit photo viewer in Swift in this folder. There is no Xcode
project: `./build.sh` builds `build.noindex/V.app`. Read `docs/performance-audit.md` in full first.
It covers the findings, the measurements, file:line references and the acceptance number for each
phase. Your job is to implement those findings in the audit's order, measuring as you go.

## Ground rules

- **Version control.** The folder isn't a git repository yet. Before editing anything:
  - run `git init`;
  - add a `.gitignore` covering `build.noindex/`, `_rerefences/` and `.DS_Store`;
  - commit the current tree as the baseline.

  Commit once per phase, so each phase is a reviewable diff.
- **Measuring.** Use `tools/perf/run.sh`. It builds the tools from the current `Sources/` and creates
  about 230 MB of synthetic photos in `$TMPDIR` the first time. It also drives the real
  `ViewerWindowController` in a transparent, click-through window, so nothing shows on screen.
  - Save its output before you change any code.
  - Re-run it after each phase and compare against the audit's acceptance numbers.
  - Those numbers come from a 2560×1600 screen at 1× scale. Check the `screen` line, and expect larger
    screen-sized images on a Retina display.
  - If your measurement disagrees with the audit, trust the measurement and say so.
- **Behaviour to keep:**
  - the Picasa-style overlay and the open and close animations, with their timings;
  - the filmstrip pop-in look;
  - keyboard, mouse and trackpad handling, including the Jump Desktop wheel heuristic in
    `ImageCanvasView.scrollWheel`.

  V must still quit when its window closes; that is an open decision noted in the audit. Keep macOS
  13 as the deployment target and add no third-party dependencies.
- **Code style.** Match the existing code: small focused types and few comments, which explain why
  rather than what. Add only the structure a phase needs.
- **Don'ts.**
  - Don't run `install.sh` or `V --make-default`. The latter rewrites LaunchServices handlers and kills
    `lsd`.
  - Don't launch the app visibly without asking me.
  - `./build.sh` must succeed at the end of every phase.

## Phases

The audit has the details for each phase.

1. **Bound memory (C1, H1).**
   - Trim the full-size cache on every navigation path.
   - Replace the concurrent load queue with an `OperationQueue` that runs 1–2 operations at a time,
     orders the current photo first and cancels stale work before it starts.
   - De-duplicate in-flight decodes by URL.
   - Debounce full decodes while a key is held.
   - Add a memory-pressure handler.
2. **Decode for the screen (H2).**
   - Decode a screen tier at the power-of-two fraction of full size that still covers the fitted photo.
   - Decode the full-resolution tier only when the user zooms past that, and drop it afterwards.
   - Keep trilinear filtering.
   - Prove that 100 % zoom still shows full-resolution pixels.
3. **Startup and main-thread I/O (M1, H3, M2).**
   - Start decoding the opened photo before building the UI.
   - List the folder off the main thread, with the faster listing the audit measured.
   - Read and cache `ImageInfo` off the main thread.
4. **Thumbnails and filmstrip (M4, L1, L2).**
   - Use slot-sized thumbnails in a byte-limited cache.
   - Cancel only thumbnail requests that are off screen.
   - Do the pop-in with `CALayer`s instead of the 60 Hz timer and CPU redraw, keyed by URL.
5. **Smaller fixes (M3, L3–L8, L10).**
   - Copy off the main thread.
   - Keep a rotation made while a photo is loading.
   - Filter and register only decodable types, which drops SVG and AI files.
   - Fix the race when a photo is opened during the close animation.
   - Remove the 0.4 s Open-panel delay.
   - Keep the display awake during the slideshow.
   - Remove the `NSScreen.main!` force unwrap.
   - Fix the remaining small items.
6. **Build (L9).**
   - Add `-wmo`, dead-strip and `strip -x` to `build.sh`.
   - Fix the Swift 6 concurrency warnings in code you touch anyway.

## When you're done

Report back with:

- a before/after table from `tools/perf/run.sh`;
- what changed in each phase;
- anything you deferred, and why;
- a short list for me to check by hand in the real app:
  - the open and close animations;
  - sharpness at 100 % zoom;
  - pan and zoom feel;
  - the slideshow;
  - trash;
  - rotating a photo while it loads;
  - opening a photo in a very large folder;
  - Copy and paste of a HEIC.
