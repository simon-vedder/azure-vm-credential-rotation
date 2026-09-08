# Images

`hero.png` (1600×640 base, rendered at 1.5×) sits at the top of the README and is the banner on the
tool page. Its right half is a diagram rather than a terminal: the tool page shows a console block
directly above the banner, and two terminals stacked read as one thing said twice.

Rendered from `hero.source.html` next to it, so a change is a text edit and a re-render:

```bash
cd docs/images
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=1.5 --window-size=1600,640 --screenshot=hero.png "file://$PWD/hero.source.html"
```

The tools site keeps a copy as `azure-vm-credential-rotation-hero.png`; keep them in step.
