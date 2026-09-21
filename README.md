# cp

A clipboard manager for macOS that shows you the thing you copied, not a grey
line about it.

Press `⇧⌘V` and the clip you are about to paste fills the top of the panel,
drawn as itself: a link with its page title, code with its colours, a colour as
a swatch, a screenshot as the picture. Hold `⇧⌘` and tap `V` to flick back
through recent clips the way `⌘Tab` flicks through apps, and let go to paste.

- **Quick switch.** Hold the shortcut, tap `V`, release. No window to read.
- **Choose the format after you paste.** A small chip appears where the paste
  landed: Link · Title · Markdown, Rich · Plain, HEX · RGB · HSL. Click one and
  the paste is swapped in place.
- **Search inside screenshots.** Text in images is read on your Mac (Vision),
  so `invoice` finds the screenshot of the invoice.
- **A stack.** `⇧↩` collects clips; each `⌘V` then pastes the next one.
- **Passwords don't stay.** Copies from password managers are never recorded,
  and anything marked concealed shows as a countdown and is forgotten. Nothing
  concealed is ever written to disk.
- **Search that matches what you typed.** Literal, across titles, bodies, page
  titles, URLs, file paths, app names and image text. 2 ms a keystroke at 2,000
  clips.
- **A Library** (`⌥⌘V`) for browsing: by kind, by the app you copied from, by day.

Everything stays on your Mac. There is no account, no sync and no network
access unless you turn on page titles for links.

[`DESIGN.md`](DESIGN.md) explains why it works the way it does.

## Build and run on your Mac

You need **macOS 14 or later** to run it and **Xcode 26 or later** to build it
(the Liquid Glass code needs the macOS 26 SDK; on macOS 14 and 15 the app falls
back to standard materials). There are no other dependencies.

```bash
git clone https://github.com/rishabhshuklax/cp.git
cd cp
make install
```

`make install` builds a release binary, assembles `cp.app`, copies it to
`/Applications` and launches it. cp has no Dock icon: look for the clipboard in
the menu bar, or just press `⇧⌘V`.

Other targets:

```bash
make run        # build and launch from build/cp.app, without installing
make app        # only build build/cp.app
make test       # run the tests (162 of them)
make uninstall  # quit cp and remove it from /Applications
make help       # list everything
```

### First run

1. Press `⇧⌘V`. The picker opens over whatever app you are in.
2. Click **Allow pasting…** and switch cp on under **Privacy & Security →
   Accessibility**. cp needs this for exactly one thing: pressing `⌘V` for you
   in the app you were using. Until you allow it, choosing a clip copies it and
   you press `⌘V` yourself.
3. On macOS 15.4 and later the system may also ask whether cp can read the
   clipboard. Allow it; Settings shows where that stands.

You grant these once. The build signs the app with a stable identity, so the
permission survives rebuilding.

To start cp when you log in, add it under **System Settings → General → Login
Items**.

### If something is off

- **No menu bar icon.** The menu bar is full and macOS has hidden it behind the
  notch. `⌘`-drag another icon out to make room. Every shortcut works without it.
- **`⇧⌘V` does nothing.** Another app owns the shortcut. Open the menu bar
  item → Settings and record a different one.
- **It copies but does not paste.** Accessibility is not granted, or was
  granted to an older copy. Remove cp from the Accessibility list, add it
  again, and relaunch.
- **`⇧⌘V` used to mean "paste and match style" in my editor.** cp takes the
  shortcut system-wide. Pick another in Settings, or use `⌥↩` in the picker to
  paste as plain text.

### Your data

History lives in `~/Library/Application Support/cp/` as a plain JSONL log plus
an `assets` folder of images. Delete that folder to erase everything; **Settings
→ Privacy → Clear history…** does the same without touching pinned clips.

## Keys

| Key | Does |
| --- | --- |
| `⇧⌘V` | Open the picker; hold `⇧⌘` and tap `V` again for quick switch |
| `↑` `↓` | Move the selection; the preview follows |
| `↩` | Paste |
| `⌥↩` | Paste as plain text |
| `⇧↩` | Add to, or take out of, the stack |
| `⌘↩` | Paste the stack in order |
| `⌘1`–`⌘9` | Paste that row (hold `⌘` to see the numbers) |
| `Space` or `⌘Y` | Look: the clip fills the panel |
| `⌘K` | Paste as… |
| `⌘P` | Pin (pinned clips are never trimmed) |
| `⌘⌫` | Delete; `⌘Z` puts it back |
| `⇥` | Take the offered filter, or switch Recent / Pinned |
| `⌫` | Remove the last filter |
| `esc` | Close the actions, leave Look, clear the search, close |
| `⌘,` | Settings |
| `⌥⌘V` | Library |

Words that could be filters — `links`, `yesterday`, `figma` — are *offered* as
a chip on `⇥`. They are never applied behind your back.

## Privacy

A clipboard manager sees everything you copy, so this is the part to be
suspicious of.

1. Copies made in password managers (1Password, Bitwarden, KeePassXC, Keychain
   Access and others; the list is editable) never reach the history.
2. The [nspasteboard.org](https://nspasteboard.org) conventions are honoured:
   concealed items are treated as secrets, transient and auto-generated items
   are not recorded at all.
3. Credential-shaped text (`ghp_…`, `sk-…`, `AKIA…`, JWTs, PEM blocks) is
   treated as a secret too.
4. A secret shows up as a countdown — "Forgets in 42s · not saved" — so the
   rule is something you can watch working. It lives in memory for as long as
   Settings says (or not at all) and is never written to disk.

No analytics, no crash reporting, no update checks.

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
Scripts/      bundle.sh (assembles and signs cp.app), make-icon.swift (draws the icon)
```

Four details that fail silently if you get them wrong, each documented where it
lives:

- **`KeyPanel`** needs both `.nonactivatingPanel` and `canBecomeKey`. Without
  the first the app you are pasting into loses focus; without the second the
  arrow keys do nothing. Its `sendEvent` hands every key to the model before
  the search field can swallow it.
- **`PasteboardMonitor`** polls. macOS has no pasteboard-changed notification
  and never has.
- **`GlobalHotKey`** uses Carbon's `RegisterEventHotKey`. `NSEvent` monitors can
  see a keystroke but not consume it, and a `CGEventTap` would demand
  Accessibility before first launch.
- **`Scripts/bundle.sh`** pins the ad-hoc signature's designated requirement to
  the bundle identifier. The default is a content hash, which changes on every
  build and silently drops the Accessibility grant.

## Not done yet

- Open at login from inside the app (use Login Items for now).
- A signed, notarised download. For now you build it yourself.
- iCloud or any other sync, and exporting the history.
- Editing a clip before pasting it.

## Contributing

Issues and pull requests are welcome. `make test` should pass, new behaviour
should come with a test, and comments should say *why* rather than *what* — the
existing code is the style guide. UI changes are easier to review with a
screenshot.

## Licence

[MIT](LICENSE).
