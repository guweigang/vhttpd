# Desktop brand assets

The approved source artwork lives in `../../assets/1128/`:

- `vhttpd_app_icon.png`: the application icon, including its dark rounded tile.
- `vhttpd_icon.png`: the standalone transparent mark used by the sidebar and tray.
- `vhttpd_logo_dark.png`: the dark-lettered wordmark for the light About page.
- `vhttpd_logo_light.png`: the light-lettered wordmark for the dark About page.

Regenerate from the repository root on macOS:

```sh
swift desktop/prepare_icon.swift desktop
```

The exporter clears near-invisible matte residue (alpha up to 8/255), trims the
remaining transparent canvas and preserves the artwork's aspect ratio. The App
icon has a 5% transparent margin; the sidebar mark has a 2% margin. It produces:

- `vhttpd-macos.icns`: Mac application/Dock icon at native icon sizes.
- `vhttpd-windows.ico`: Windows application icon, 16–256 px.
- `vhttpd-tray.ico`: transparent Windows tray icon, 16–256 px.
- `vhttpd-icon.png`: 1024 px application icon, also included in Linux packages.
- `vhttpd-mark.png`: 512 px transparent sidebar and macOS tray mark.
- `vhttpd-logo.png`: cropped dark-lettered wordmark for light themes.
- `vhttpd-logo-light.png`: cropped light-lettered wordmark for dark themes.

Desktop build, packaging and development fallback paths all use these assets.
