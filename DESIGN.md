# Design

Why this exists, and what the redesign changed. The short version: **Maccy shows
you strings; the first cp showed you rows about clippings; this one shows you
the clipping.**

## The diagnosis, twice

The first diagnosis still holds. A clipboard manager that stores `String`
forever has to render every row identically — same grey font, same truncated
line — whether it holds a hex colour, a pull-request link, a 400-line Swift file
or a screenshot. Fix the data model and most of the UI falls out for free.

The second diagnosis is about what was built on top of that model. The first cp
typed its clippings correctly and then spent the row on *metadata about* the
clipping: an accent bar, a kind label, a word count, a byte count, an ⌥ badge, a
source app, three lines of body. Nine rows filled the panel, none of them
scannable, and the actual content sat in a preview pane on the right at half
width. It was a list of labels with a preview attached.

So: **preview first**. The selected clipping fills the top 192pt of the panel,
drawn as itself, and the list under it is one line per clipping — a thumbnail,
what it says, when. You choose by looking at the thing.

## The spine: typed clippings

`Classifier` runs once at capture and assigns a `ClippingKind`. Everything reads
off it — how the hero draws, what the row's thumbnail is, which paste formats
exist, what the chip offers afterwards.

| Kind | The hero shows |
| --- | --- |
| `url` | favicon, host, page title, and the URL with its tracking tinted orange |
| `color` | a 128pt swatch and the four notations, each of which pastes |
| `image` | the picture, its size, the text found inside it, and a yellow box on the words you searched for |
| `file` | Finder's icon, the name, the path, the type and the size |
| `code` | the language, and the first lines unwrapped, fading at the right edge |
| `json` | pretty-printed and capped |
| `richText` | the attributed text, redrawn at the hero's size |
| `text` | four lines, with what you typed marked |
| concealed | a countdown ring, `••••••••••••`, "Forgets in 42s · not saved" |

Classification is heuristic and cheap on purpose: a wrong guess costs a
mislabelled badge, not correctness.

## The selection model

This is the part that made the old picker feel broken, and it is worth naming
precisely. The audit clicked row 4 and pasted row 12.

- Opening selects the **newest** clip — what `⌘V` would paste anyway — and never
  a pin for being a pin.
- Every change of query, filter or scope selects the top result.
- `↑` `↓` move; the list scrolls **only** when the selection has left the
  viewport, and then by the smallest amount that brings it back. It never
  re-centres.
- The pointer selects a row only after it has actually moved. A row sliding
  under a still hand is the list moving, not a choice.
- Hover never scrolls. A single click pastes, the way a menu item does.

## Three surfaces, not one

One surface trying to be both a 200 ms keyboard flow and a place to browse a
month of history serves neither.

- **Picker** (`⇧⌘V`) — 720pt wide, hero on top, one-line rows under it. 95% of use.
- **Quick switch** (hold `⇧⌘`, tap `V`) — eight cards, stepped through with the
  key you are already holding, pasted by letting go. For "the thing before this
  one", which is most of what a clipboard manager is for.
- **Library** (`⌥⌘V`) — an ordinary window with a sidebar, tiles, an inspector
  and multi-select. For hunting rather than pasting.

The picker and the Library keep separate models on purpose. Sharing one is how
the old build ended up with a browser showing whatever the picker last searched
for.

## The stack, and the chip

Two ideas that only work because the app already knows what a clipping *is*.

**The stack** (`⇧↩`) collects clips and pastes them in order — as one paste when
they are all text, because three pastes is three undo steps in the target app.
Close the picker with clips still in it and cp takes over `⌘V` itself: each
press pastes the next one. It lets go of the key around its own synthesised
`⌘V`, and gives it back for good when the stack runs out.

**The chip** appears under the caret after a paste, offering the other formats
that clipping could have taken. Clicking one presses `⌘Z`, writes the new
format, and presses `⌘V` again, so the decision can be made *after* seeing the
result. When Accessibility will not say where the caret is — Chrome and Electron
answer with an empty rectangle — it falls back to the foot of the target window,
then to the pointer.

## Privacy, made visible

Every clipboard manager persists whatever you copy, passwords included. Three
layers, and the third is the design statement:

1. Copies from known password managers are dropped before they reach history.
2. `org.nspasteboard.ConcealedType` is honoured; transient and auto-generated
   items are not recorded at all.
3. A concealed clipping appears as a **countdown ring**, not as an absence. The
   rule is something you can watch working, rather than a promise in a settings
   pane.

## Visual language

- **Glass on the chrome, never behind a row.** The search capsule, the results
  panel, the HUD, the chip and the toast are glass; content sits on a light wash
  over it. A material behind dense text puts a moving desktop under what you are
  reading, which is the trap most "modernise it with glass" redesigns fall into.
  One helper (`cpGlass`) is `glassEffect` on macOS 26 and a material with a
  hairline edge before it.
- **One shape per surface.** Capsules for controls, 12pt rounded rects for rows,
  28pt for the panel. A control in a different shape reads as a mistake before
  anyone reads its label.
- Selection is an accent-tinted rounded rect with a 1pt accent edge.
- System fonts; SF Mono for code, JSON, colours, URLs and paths.
- Everything under 200 ms. The panel has `animationBehavior = .none`; this is hit
  dozens of times a day and nothing is allowed to play an animation at you.

## What the redesign removed, and why

Each of these was in the first build and is gone on purpose. They are listed so
they do not come back.

- **Accent bars and kind labels on rows.** The thumbnail already says what kind
  it is, and the hero says it louder.
- **Word counts and byte counts on rows.** Nobody has ever chosen a clipping by
  its word count.
- **⌥ badges on every row.** The numbers appear when you hold ⌘, on the rows they
  apply to, and are invisible the rest of the time.
- **The keyboard-hint footer.** A permanent strip teaching five shortcuts to
  someone who learned them on day two.
- **The invisible query language** (`app:xcode`, `type:link`, `>1kb`). Replaced
  by suggestions: cp offers the filter as a chip on `⇥` and never applies one
  silently, so there is no syntax to get wrong.
- **The affinity ranker** that nudged results by the app you were pasting into.
  It made the order unpredictable to justify a guess; empty-query order is now
  strict recency, and a search is ranked by where the words matched.
- **The adaptive image grid.** The picker is a list with a hero; a grid of
  thumbnails is what the Library is for.
- **The hover-delayed preview pane.** The preview is the hero and tracks the
  selection, so the keyboard path sees exactly what the mouse does.
- **Prose in Settings.** Every row was followed by a paragraph explaining it. If
  a row needs a paragraph, the row is wrong.

## Engineering notes that shaped the design

**The picker cannot be a SwiftUI `Window`.** It either activates the app —
stealing focus from whatever you were about to paste into — or cannot take key
events. The combination that works is an `NSPanel` with `.nonactivatingPanel`
*and* `canBecomeKey` overridden.

**A focused `TextField` swallows keys.** That is why `⌥1` used to type `¡` and
`⌘⌫` never fired. Every key goes through the panel's `sendEvent` to the picker's
key map first; what it does not claim reaches the field with focus intact. Keys
are matched on virtual key code and the four modifier flags, never on
characters, because characters depend on the layout.

**Borderless, not titled.** A titled panel keeps an invisible 32pt title-bar band
that eats clicks meant for the search field.

**Pasting is a synthesised `⌘V`** and needs Accessibility. Without it cp degrades
to copy-only and says so. It never presses the key unless the target app is
actually frontmost, so a paste can never land in the wrong window.

**Capture is a 250 ms poll of `changeCount`**, because macOS has no
pasteboard-changed notification. cp's own writes carry a private pasteboard type
so they are never captured back as new copies.

**Storage is an append-only JSONL log**, not a database: at the default 2,000-clip
cap the whole history fits in memory and scans in microseconds, a copy costs one
write on a background queue, and a crash loses at most the last line.

**The designated requirement is load-bearing.** TCC remembers an app by it, and
the default ad-hoc requirement is a content hash — so without pinning it to the
bundle identifier, every rebuild is a new app and the Accessibility grant
silently stops applying.
