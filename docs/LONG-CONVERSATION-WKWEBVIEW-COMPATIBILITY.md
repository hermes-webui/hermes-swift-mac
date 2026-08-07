# WKWebView long-conversation freeze

## Observed freeze

Very long conversations could leave the native macOS app unresponsive while the
same server remained usable in browser and iOS clients.

## Root cause

The WebUI transcript virtualizer uses a scheduler for WebKit measurement work.
When WebKit alternated between measurement windows, the scheduler reset its
retry count and could keep scheduling `requestAnimationFrame` layout work.
The resulting loop made the WKWebView appear frozen.

## Mitigation and scope

`BrowserWindowController` injects a main-frame-only `WKUserScript` at document
start. It preserves the server's virtualization setting but temporarily uses
the supported non-virtualized path while the affected scheduler reset is
present. The script only affects the macOS wrapper because it runs in that
wrapper's WKWebView; browser and iOS clients are unchanged.

## Removal

Remove the compatibility script and its tests once the upstream scheduler fix
is included in every supported WebUI version.
