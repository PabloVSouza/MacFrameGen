# Changelog

All notable changes to MacFrameGen are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- The Mac and its display stay awake while MacFrameGen is running, so the screen doesn't dim or
  sleep while you play with a controller.

## [0.1.0] - 2026-11-24

First release.

### Added

- Real-time frame generation for UVC capture cards (tested with an Elgato Game Capture Neo and a PS5):
  30 → 60 fps (2×) or 30 → 120 fps on a 120 Hz screen (4×).
- Two frame generators: a fast Metal shader (about 4 ms per 1080p frame, the default) and Apple's
  VideoToolbox low-latency interpolator (about 14 ms).
- Repeated-frame detection that works with console HDR on and off.
- Extra in-between frames when the game dips below its target frame rate (shader only).
- Low-latency scheduling and a dedicated presenter thread: about 40 ms capture → screen in full screen.
- On-screen readout (⌘F): game fps → output fps, latency, and the game's estimated render resolution.
- Console HDR fix for the dark picture the card produces when the console outputs HDR, with a strength slider.
- Recordable output window, and sharing the card with OBS.
- Game window mode for games running on the Mac.

[Unreleased]: https://github.com/PabloVSouza/MacFrameGen/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/PabloVSouza/MacFrameGen/releases/tag/v0.1.0
