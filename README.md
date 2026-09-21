# cp

A macOS clipboard manager built on one idea: **a clipping is a typed value, not
a string** — and a second one the redesign added: **you choose by looking at the
thing, not by reading a grey line about it.**

[`DESIGN.md`](DESIGN.md) has the rationale, what was thrown away, and why.

## Status

**Redesigned, built, not yet lived with.** The engine (capture, storage, search,
paste formats, pasting) and the UI (picker, quick switch, format chip, Library,
menu bar, Settings) are complete rather than stubbed. 162 tests pass; the
surfaces were checked off-screen against real windows.

Requires macOS 14 or later; the Liquid Glass chrome is macOS 26 and falls back
to a material with a hairline edge before that.

## Build

```bash
make app     # build and assemble build/cp.app
make run     # build, assemble, and launch
make test    # run the test suite
```

The bundle matters: `LSUIElement` only applies inside one, and the Accessibility
grant is remembered per app. `bundle.sh` signs ad-hoc with the designated
requirement pinned to the bundle identifier, so the grant survives a rebuild —
the default ad-hoc requirement is a content hash and changes every time.

## Using it

`⇧⌘V` opens the picker, centred above the middle of the screen. The clipping you
are about to paste fills the top of it, rendered as itself. Hold `⇧⌘` and tap
`V` again to get the switcher instead: a row of recent clips, released to paste.

| Key | Does |
| --- | --- |
| `↑` `↓` | Move the selection; the preview follows |
| `↩` | Paste |
| `⌥↩` | Paste as plain text |
| `⇧↩` | Add to, or take out of, the stack |
| `⌘↩` | Paste the stack in order |
| `⌘1`–`⌘9` | Paste that row (hold ⌘ to see the numbers) |
| `Space` or `⌘Y` | Look: the clipping fills the panel |
| `⌘K` | Paste as… |
| `⌘P` | Pin (pinned clips are never trimmed) |
| `⌘⌫` | Delete; `⌘Z` puts it back |
| `⇥` | Take the offered filter, or switch Recent / Pinned |
| `⌫` | Remove the last filter |
| `esc` | Close the actions, leave Look, clear the search, close |
| `⌘,` | Settings |
| `⌥⌘V` | Library |

Search matches what you typed, literally, in the title, the page title, the
body, the text found inside images, the URL, the file path and the app name.
Words that could be filters — `links`, `yesterday`, `figma` — are *offered* as a
chip on `⇥`, never applied behind your back.

**The stack.** `⇧↩` adds clips to it. Paste them in order with `⌘↩`, or close the
picker and each `⌘V` pastes the next one until it runs out.

**After a paste**, a small capsule appears where the text landed with the other
formats that clipping could have taken — Markdown, the clean link, the text
inside the screenshot. Clicking one swaps the paste in place.

## Permissions

- **Accessibility** — only to press `⌘V` for you. Without it, choosing still
  copies, the button says **Copy**, and the toast tells you to press `⌘V`.
- **Reading the clipboard** — macOS 15.4 and later asks once; Settings shows
  where it stands.
- **No network by default.** Page titles are opt-in, fetched only for the link
  you have selected, and only from the site itself.

## Where things are

```
Sources/CpKit/
  Model/      Clipping, ClippingKind, Classifier, CodeHeuristic
  Capture/    PasteboardMonitor (250 ms changeCount poll), PrivacyFilter, ImageFacts
  Store/      ClippingStore (in-memory index), ClippingArchive (JSONL), Settings
  Search/     ClipSearch (literal, folded, cached), FoldedText
  Paste/      Paster (CGEvent ⌘V), PasteFormat, JSONFormatter, ColorFormats, URLTracking
  Services/   LinkResolver + LinkPreviews, TextRecognizer (Vision)
  UI/
    Picker/     PickerModel, PickerKeys, ListLayout, HeroView, ClipRow, ActionsView, PickerWindow
    Switcher/   QuickSwitch (state machine), ClipCard, SwitcherView
    Chip/       FormatChip (placement, caret lookup)
    Library/    LibraryModel, LibraryView, LibraryWindow
    MenuBar/    MenuBarView
    Settings/   SettingsView, ShortcutRecorder
    Toast/      ToastCenter
    Shared/     MarkedText, CodeHighlighter, RichPreview, Icons, RelativeTime
    Theme, Glass, KeyPanel
  App/        AppController, GlobalHotKey (Carbon), PasteStack
Sources/cp/   CpApp — the MenuBarExtra scene and the app delegate
```

Four load-bearing details, spelled out where they live so they are not
rediscovered the hard way:

- **`KeyPanel`** — `.nonactivatingPanel` **and** `canBecomeKey` overridden, or it
  fails silently and differently. `sendEvent` routes every key to the model
  before the search field can swallow it.
- **`PasteboardMonitor`** — polling is the only option; macOS has no
  pasteboard-changed notification and never has.
- **`GlobalHotKey`** — Carbon's `RegisterEventHotKey` is still the right call.
  `NSEvent` monitors can see a keystroke but not consume it, and a `CGEventTap`
  would demand Accessibility before first launch.
- **`Scripts/bundle.sh`** — the designated requirement is why the Accessibility
  grant survives rebuilds.

## Privacy

Clipboard managers persist whatever you copy, passwords included. Three layers,
and the third is the point:

1. Copies from known password managers never reach the history.
2. The `org.nspasteboard.ConcealedType` convention is honoured; transient and
   auto-generated items are ignored entirely.
3. A concealed clipping shows up as a **countdown** — "Forgets in 42s · not
   saved" — so the rule is something you can watch working.

Concealed clippings live in memory for as long as Settings says, and are never
written to disk.

## Not done yet

- iCloud or any other sync.
- Sharing the history between machines, or exporting it.
- Editing a clipping before pasting it.
