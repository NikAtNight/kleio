# Kleio app icon

`KleioIcon.svg` is the source artwork: the website's two speech bubbles in navy on a sky-blue tile. The tile is 824 pixels on a 1024 pixel canvas, following the macOS icon grid, with a transparent margin and a soft shadow.

`KleioIcon.png` is the master render of that SVG at 1024 by 1024 with transparency. Re-render it in a browser if you change the SVG. The website favicon in `website/assets/favicon.svg` uses the same mark and colors.

Run `./scripts/make-icon.sh` from the repository root to create `AppIcon.icns`. The renderer preserves alpha and produces standard and Retina images from 16 to 1024 pixels, packaged with macOS `iconutil`. App packaging regenerates the icon when its artwork or scripts change.
