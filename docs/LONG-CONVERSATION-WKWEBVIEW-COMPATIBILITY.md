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

## Upstream tracking

- Issue: [nesquena/hermes-webui#6654](https://github.com/nesquena/hermes-webui/issues/6654)
  (virtual measurement retry budget resets during window-key oscillation).
- Fix: [nesquena/hermes-webui#6717](https://github.com/nesquena/hermes-webui/pull/6717),
  first shipped in the `exp-v0.52.374` experimental release. It deletes the
  per-cycle-key reset, which is the exact text this guard looks for, so the guard
  turns itself off on servers that include the fix.

The guard matches source text, not behaviour. If a later WebUI release fixes
the bug differently and leaves the literal reset in place (for example, by moving
it behind a once-per-burst check), the guard will keep virtualization disabled.
That is the safe failure direction, but the shim would then never retire itself.

## Removal

Remove the compatibility script and its tests once the upstream scheduler fix
is included in every supported WebUI version, including the stable channel.
