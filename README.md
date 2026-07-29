# DeskPulse

A compact, full-screen personal command center for macOS, built natively with
SwiftUI.

## Run

Open `Package.swift` in Xcode and run the `DeskPulse` scheme, or:

```sh
swift run DeskPulse
```

To create a double-clickable macOS application:

```sh
./build-app.sh
open /Applications/DeskPulse.app
```

Drag any card by its title bar and resize it from any edge or corner. Layout
changes persist automatically.
Press **Control–Command–F** for full screen.

Use **Auto arrange** to clean up the current arrangement, or save four complete
widget layouts from the top bar. The grid control enables visible snap-to-grid
placement.

The widget library also includes an interactive Channel 12 live-TV browser surface
from `gurutv.online`, with WebKit media playback and fullscreen video support.

## Web sessions

Gmail, WhatsApp, and YouTube Music are interactive WebKit widgets. Sign in once
inside each widget; WebKit's persistent app-specific cookie store keeps the session
across launches. Safari and Chrome do not allow other apps to read their cookies,
so their existing login sessions cannot be imported. Links leaving a service's
own domains open in Chrome.

The AMD card uses Nasdaq's public quote and intraday-chart endpoints, with a
previous-close baseline and market-session boundaries. Weather uses Open-Meteo;
RSS and weather requests use an ephemeral URL session.

## Add a widget

1. Add a case to `WidgetKind`.
2. Provide its title, symbol, and tint in `Models.swift`.
3. Add its view to `WidgetContent.swift`.

The layout, persistence, card chrome, drag, resize, and removal behavior are then
provided automatically.
