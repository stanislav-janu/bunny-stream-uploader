# Design system

Bunny Stream Uploader keeps Apple's look and the system accent color. Views
read every color, radius, spacing, and fixed size from the tokens in
`Sources/BunnyUploader/UI/`, never from raw values. A change in one token
changes the whole app.

## Accent

There is no accent token and no accent picker. Accent-colored elements use
`.tint` or `Color.accentColor`, which follow the accent the person set for
their Mac.

## Palette.swift

`Palette` holds the two status colors:

- `Palette.success`: a finished upload, a saved or accepted value.
- `Palette.failure`: an error, missing credentials, a failed processing step.

Status never rests on color alone: each colored state also has a symbol or
a word.

`Surface` holds the custom fills and borders. They are translucent, so they
pick up the window's material in light and dark mode:

- `Surface.row`: the fill of an upload row.
- `Surface.rowSelected` and `Surface.rowSelectedBorder`: the selected row.
- `Surface.dropBorder`: the dashed border of the drop zone at rest.
- `Surface.dropTarget`: the drop zone fill while files are dragged over it.

Never copy a semantic color (`.secondary`, `.separator`) into a new token;
use it directly.

## Radius.swift

- `Radius.row` (10): upload rows.
- `Radius.md` (12): the drop zone and other cards.

Inner corners are concentric: inner radius = outer radius - inset.

## Grid.swift

`Space` is the spacing scale: `xxs 2`, `xs 4`, `s 8`, `m 12`, `l 16`,
`xl 20`, `xxl 24`.

- `xxs`: a title and its caption.
- `xs`: an icon and its label inside one control.
- `s`: items in a row or a stack of rows.
- `m`: row padding and grouped controls.
- `l`: window margins.
- `xl` and `xxl`: Settings sections and their outer padding.

`spacing: 0` stays literal where views must touch (a header over a divider).

## Layout.swift

Fixed sizes that are not spacing:

- `windowMinWidth`, `windowMinHeight`: the main window minimum.
- `settingsWidth`: the Settings window width.
- `dropZoneHeight`: the drop zone height.
- `stepperValueWidth`: the value next to a stepper, so it does not jump.
- `heroSymbol`, `dropSymbol`: symbol sizes in the empty state and drop zone.
- `dropBorderWidth`, `dropBorderDash`: the drop zone border.
- `selectionBorderWidth`: the selected row border.

## Rules

- Text uses system text styles (`.headline`, `.caption`), never fixed sizes.
  Only SF Symbols use `Layout` sizes.
- Style controls with system controls and `ButtonStyle`. Never rebuild a
  control from shapes: it loses the keyboard, focus, and VoiceOver.
- Units ("MB/s", "%") never animate; numbers use `.monospacedDigit()` so
  they do not shift.
- One primary button per window or sheet.
