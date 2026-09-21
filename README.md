# cp

A macOS clipboard manager built on one idea: **a clipping is a typed value, not a
string.**

Every other clipboard manager stores `String` and renders one truncated grey line
per item, so a hex colour, a pull-request link, a 400-line Swift file and a
screenshot all look identical. `cp` classifies at capture and renders per type —
which is what makes the list scannable instead of readable.

[`DESIGN.md`](DESIGN.md) has the full rationale, the rejected alternatives, and
the three open questions and how they were called.

## Status

**First cut, now compiling.** It was written on Linux without a Swift toolchain,
then built on macOS 26.6 with Swift 6.3 (Xcode 26.6): two compile errors fixed,
no warnings, and the 44 tests pass.

Complete in scope: capture, classification, storage, search, ranking,
transforms, both UI surfaces, and the privacy layer are all implemented rather
than stubbed. Tests cover the pure logic (classifier, query parser, fuzzy matcher,
transforms, privacy heuristics).

## Build

Requires macOS 14+ and a Swift 5.9+ toolchain.

```bash
make app     # build and assemble build/cp.app
make run     # build, assemble, and launch
make test    # run the test suite
```

`make app` wraps `swift build` and assembles a real `.app` bundle. The bundle
matters: `LSUIElement` only applies inside one, and TCC needs a stable bundle
identity to remember the Accessibility grant between launches. Running the bare
binary works but re-prompts every time.

## Using it

`⇧⌘V` opens the picker, centred on screen.

| Key | Does |
| --- | --- |
| `↑` `↓` | Move selection — the preview follows instantly |
| `↩` | Paste |
| `⌘↩` | Paste as plain text |
| `⌥1`–`⌥9` | Jump straight to a row |
| `⌘P` | Pin (pinned items are never trimmed) |
| `⌘⌫` | Delete |
| `esc` | Close |

Search accepts filters that commit to chips as you type: `app:xcode`,
`type:link`, `type:code`, `today`, `pinned`, `>1kb`. Anything unrecognised is
just search text, so there is no syntax to learn.

## Permissions

- **Accessibility** — needed only to press `⌘V` for you. Without it, choosing an
  item still copies it; you press `⌘V` yourself. The app says so rather than
  failing silently.
- **No network access by default.** Link-title lookup is opt-in, fires only for
  the link you have selected, and talks only to the site itself.

## Where things are

```
Sources/CpKit/
  Model/      Clipping, ClippingKind, Classifier, CodeHeuristic, TimeBucket
  Capture/    PasteboardMonitor (250ms changeCount poll), PrivacyFilter
  Store/      ClippingStore (in-memory index), ClippingArchive (JSONL), Settings
  Search/     SearchQuery (the invisible query language), FuzzyMatch, Ranker
  Paste/      Paster (CGEvent ⌘V), Transform (type-aware actions)
  Services/   LinkResolver (lazy, opt-in, first-party only)
  UI/         PickerPanel, PickerView, ClippingRow, PreviewPane, SearchBar,
              ImageGrid, BrowserView, SettingsView, Theme
  App/        AppController, GlobalHotKey (Carbon)
Sources/cp/   CpApp — scenes and app delegate, nothing else
```

Three load-bearing details, spelled out where they live so they aren't
rediscovered the hard way:

- **`PickerPanel`** — `.nonactivatingPanel` **and** `canBecomeKey` overridden.
  Either one alone fails silently, and differently.
- **`PasteboardMonitor`** — polling is the only option; macOS has no
  pasteboard-changed notification.
- **`GlobalHotKey`** — Carbon's `RegisterEventHotKey` is still the right call.
  `NSEvent` global monitors can observe a keystroke but not consume it, and a
  `CGEventTap` would demand Accessibility permission before first launch.

## Privacy

Clipboard managers persist whatever you copy, passwords included — your password
manager clears the system clipboard after ~90s, but the manager already
snapshotted it. Three layers, and the third is the point:

1. Copies from known password managers are dropped before they reach the history.
2. The `org.nspasteboard.ConcealedType` convention is honoured.
3. A concealed clipping shows up as a **locked row** — "Concealed · never saved to
   disk" — rather than silently vanishing, so the rule is something you can see
   working instead of a promise in a settings pane.

Concealed items are held for the session only and never written to the archive.

## Not done yet

- Real syntax highlighting. Code rows are monospace with a detected language
  badge; the tokens aren't coloured.
- iCloud or any other sync.
- A configurable hotkey — `⇧⌘V` is currently hard-coded.
- Multi-select and bulk export in the browser window.
