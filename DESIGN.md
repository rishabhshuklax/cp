# Design

Why this exists and what it argues for. The short version: **Maccy shows you
strings; `cp` shows you objects.**

## The diagnosis

Maccy is a good engine wearing a 2013 UI, and its visual problems are all
downstream of one structural choice: a clipping is a `String` forever. Once that
is true, every row must render identically — same grey system font, same single
truncated line — whether it holds a hex colour, a pull-request link, a 400-line
Swift file, or a screenshot. Four consequences follow directly:

1. **Two code snippets are visually identical.** Truncated to one line, an
   indented block renders as leading whitespace and nothing else.
2. **The strongest retrieval cue is hidden.** You remember *which app* you copied
   from long before you remember the text. Maccy knows the source app — it's in
   the hover preview — but the row doesn't show it.
3. **Time has no structure.** A flat reverse-chronological list gives "that thing
   from the call an hour ago" nothing to grab.
4. **The preview fights the keyboard.** It appears on hover, after a delay, so the
   keyboard-first path — the one 95% of uses take — never sees the content it is
   choosing between.

Fix the data model and most of the UI design falls out for free.

## The spine: typed clippings

`Classifier` runs once at capture and assigns a `ClippingKind`. Everything
downstream reads off it — row layout, accent colour, preview renderer, which
transforms are offered, how the item ranks against the app you're pasting into.

| Kind | Row renders as |
| --- | --- |
| `url` | favicon + resolved page title + host |
| `color` | the actual swatch + notation |
| `image` | thumbnail, dimensions, size |
| `file` | `NSWorkspace` icon, filename bold, parent dimmed |
| `code` | monospace first 3 lines + language badge |
| `json` | pretty head + key/item count |
| `richText` | the attributed string, scaled down |
| `text` | first 2 lines + word count |

Classification is heuristic and cheap on purpose: it runs on every copy, so it
stays well under a millisecond. Everything expensive — link titles, full syntax
highlighting — is deferred to selection time. A wrong guess costs a mislabelled
badge, not correctness, and that budget buys a much simpler implementation than a
real tokenizer.

## Row anatomy

```
┌──────────────────────────────────────────────────┐
│ ▍ ⌘ Xcode                          2m        ⌥1  │
│ ▍ struct PullRequestView: View {                  │
│ ▍   @State private var isExpanded = false         │
│ ▍ swift · 47 lines · 1.2 KB                       │
└──────────────────────────────────────────────────┘
```

- **Leading accent bar**, coloured by kind. Hues are spaced far enough apart to
  separate in peripheral vision — you find "the code one" without reading a word.
- **Source app icon in the header**, not in a tooltip. 15pt of width for the
  highest-signal cue available.
- **56pt rows.** Eight readable rows beat twenty you have to squint at.
- **Three body lines for code**, two for prose, one for atoms like colours.

## Two surfaces, not one

One surface trying to be both a 200 ms keyboard flow and a place to browse a
month of history serves neither. That conflict is what traps the popover model
into a hover-delayed sub-popover and a scroll view you can't resize.

- **Picker** (`⇧⌘V`) — centred on screen, 720×460, list left / live preview
  right, dies on Escape. 95% of usage.
- **Browser** (menu bar → Browse history) — a real resizable window with a
  sidebar, multi-select, and bulk actions.

Centring the picker rather than anchoring it to the menu bar is the load-bearing
choice: decoupling from the menu-bar item removes the pressure to stay narrow,
and the width is exactly what buys the preview pane.

## Preview tracks selection, not the mouse

Arrow down, preview updates instantly. No hover delay, no popover, no second
mechanism. Hovering a row also moves the selection, so mouse and keyboard drive
the same single piece of state.

## Four smaller bets

1. **Time sections** — Now / Earlier today / Yesterday / This week / Older.
   Suppressed while searching, because relevance order is the point then and
   buckets would hide the best match under a header.
2. **An invisible query language** — `app:xcode`, `type:link`, `today`, `>1kb`
   commit to chips as you type the trailing space. Unrecognised `foo:bar` is just
   search text, so there is nothing to learn and no syntax-error state.
3. **Type-aware transforms** — a URL offers "remove tracking", JSON offers
   minify/prettify, code offers "strip indentation". Typing is what keeps the
   action menu short enough to be worth opening.
4. **Paste-target awareness** — the frontmost app at invoke time nudges ranking:
   code up in Xcode, colours and images in Figma. A soft re-rank, never a filter,
   so being wrong is cheap.

## Privacy, made visible

Every clipboard manager persists whatever you copy, passwords included. 1Password
clears the system clipboard after ~90s, but the manager already snapshotted it, so
the secret outlives the clear.

Three layers, and the third is the design statement:

1. **App exclusion** — copies from known password managers are dropped before
   they reach the history, seeded on first launch so the safe default doesn't
   depend on anyone opening Settings.
2. **`org.nspasteboard.ConcealedType`** — the community convention for marking an
   item private. Honoured, alongside the transient and auto-generated markers.
3. **Locked rows** — a concealed clipping appears in the list as a blurred, locked
   row reading *"Concealed · never saved to disk"*, rather than silently
   vanishing. The behaviour is something you can check at a glance instead of a
   promise buried in a preferences pane.

Concealed clippings are held for the session only and never written to the
archive. Credential-shaped payloads (`ghp_`, `sk-`, `AKIA`, JWTs, PEM blocks) are
concealed by prefix match — deliberately not by entropy, since flagging every
base64 blob would conceal half a developer's real history.

## Three forks, and how they were called

These were open questions; each was resolved to the first option, and each is a
seam that can be reversed.

**1. Picker shape — wide and centred, or narrow and menu-bar-anchored?**
Wide and centred. The preview pane is worth more than the lightness, and the
lightness is recoverable through speed (no fade-in, ≤200 ms everywhere) rather
than through width. Reversing means changing `Theme.Metric.panelWidth` and
`PickerPanel.positionOnActiveScreen()`.

**2. Link titles — resolve them, or show favicon plus domain only?**
Resolve, but opt-in and lazy. Reading a page title means an outbound request for
something you merely copied, so it's off by default, fires only for the link you
have *selected*, and fetches the favicon from the site itself rather than a
third-party favicon proxy that would otherwise receive your browsing history.

**3. Images — list rows with thumbnails, or a grid?**
Both, switching automatically. When ≥70% of the filtered set is images the list
becomes a thumbnail grid, because a list row gives an image 40pt and wastes the
one property images have that text doesn't — you can recognise one without
reading it.

## Visual language

- **Glass on the container and the search field, never behind the list.**
  `.ultraThinMaterial` under dense text puts a moving desktop behind what you're
  reading. The panel gets the material; rows sit on an opaque surface. This is the
  trap most "modernise it with glass" redesigns fall into.
- Selection is a tinted rounded rect plus a 1pt accent border — not a full-bleed
  blue bar.
- SF Symbols throughout, `.hierarchical` rendering.
- **Everything ≤200 ms.** This is hit dozens of times a day; nothing is allowed to
  feel like it's playing an animation at you. The panel has
  `animationBehavior = .none` for the same reason.

## Engineering notes that shaped the design

**The picker cannot be a SwiftUI `Window`.** A normal window either activates the
app — stealing focus from whatever you were about to paste into, which breaks the
paste — or can't take key events at all. The working combination is an `NSPanel`
with `.nonactivatingPanel` in its style mask **and** `canBecomeKey` overridden to
`true`. Miss either half and it fails silently, differently: without the style
mask the app activates, without the override the arrow keys do nothing.

**Pasting needs Accessibility permission**, because it's a synthesised `⌘V` via
`CGEvent`. Without the grant the app degrades to copy-only and says so, rather
than silently doing nothing.

**Capture is a 250 ms poll of `NSPasteboard.changeCount`.** There is no
pasteboard-changed notification on macOS and there never has been.

**Storage is an append-only JSONL log, not a database.** At the default 2,000-item
cap the whole history fits in memory and scans in microseconds; what the log buys
is that a copy costs one write on a background queue and a crash loses at most the
last line. `ClippingArchive.load()` / `append(_:)` is the entire contract, and the
seam to swap for SQLite if history ever needs to outgrow memory.
