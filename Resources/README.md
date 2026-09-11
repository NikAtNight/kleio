# Kleio app icon

`KleioIcon.png` is the master artwork: an ivory scroll forming a K on an Aegean blue tile, with a transparent outer margin. It was created with the built-in image generation tool.

Run `./scripts/make-icon.sh` from the repository root to create `AppIcon.icns`. The renderer preserves alpha and produces standard and Retina images from 16 to 1024 pixels, packaged with macOS `iconutil`. App packaging regenerates the icon when its artwork or scripts change.

## Generation prompt

```text
Use case: logo-brand.
Asset type: production macOS app icon for Kleio, a local meeting recorder and transcript library named for the Greek muse of history.
Create one polished, memorable icon, square 1024x1024 composition. A single bold ivory scroll-ribbon forms an abstract but unmistakable capital K. One upright thick ribbon with a restrained rolled-paper curl at its top, and two clean diagonal ribbon arms. The entire silhouette must remain legible at 32 pixels. Greek inspiration comes only through the scroll, not classical ornaments.
The icon tile is a deep Aegean blue rounded square with a subtle blue-teal tonal gradient. The ivory mark has delicate dimensional paper folds, soft bevels and restrained warm highlights, like a carefully designed native Apple app icon. Nearly front-on orthographic view, centered, balanced, quiet and precise. Tile occupies about 84 percent of the image, even transparent margin around it, generous internal breathing space.
No text, no wordmark, no border, no laurel, no temple, no microphone, no waveform, no letters other than the abstract K, no decorative objects, no mockup device, no grid, no drop shadow outside the tile. Transparent background outside the rounded square. Deliver a single finished icon, not a presentation board.
```
