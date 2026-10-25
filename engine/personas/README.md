# Personas

A persona is a folder of **pieces**: small text files, each placed in one
**slot** of the conversation the reviewer receives. A **recipe** names the
pieces that are on. Config picks a recipe and can toggle single pieces on top:

```
angry            the persona's default recipe
angry:v1         a named recipe
angry:v1-sigh    v1 without the sigh piece
none:plain+x     plain plus piece x
```

`goobreview prompt --persona <spec>` prints the exact conversation a spec
produces.

## Slots

| Slot | Where the text lands |
|---|---|
| `role` | top of the system prompt, before the reviewer contract |
| `history.user`, `history.assistant` | one earlier conversation turn each, before the pull request message; the model reads an assistant turn as something it already said |
| `before` | the user message, before the pull request data |
| `after` | the user message, after the pull request data: the last words the model reads |
| `steer` | a user message delivered mid-review, once after each listed count of completed tool calls |

Pieces in one slot are joined by newlines, in the order `persona.json` lists
them; a recipe is a set, so its order does not matter. History pieces are one
turn each, in that same order, and must alternate, opening with the user and
ending on the assistant, since the pull request message comes next. A steer
piece is declared with its schedule, `{"slot": "steer", "afterToolCalls": [5, 15]}`;
a run that stops reading earlier never receives the later deliveries, and the
transcript records each one that landed. The reviewer contract,
tools, output rules and trust boundary are not pieces and are always on. The
pull request data is identical for every persona.

## Files

```
<name>/
  persona.json   {"pieces": {"<id>": "<slot>"}, "recipes": {"<recipe>": ["<id>", ...]}, "default": "<recipe>"}
  <id>.md        one per piece
```

A piece's text is its file with one trailing newline removed; everything else
is kept byte for byte, trailing spaces included (`angry/sigh.md` ends in
`The ` on purpose). Line endings are normalised to `\n`. Names, recipes and
piece ids are lowercase letters, digits and `_`.

Each research record stores the spec and a SHA-256 of every piece it used, so
editing a line starts a new, distinguishable series rather than blending into
the old one.
