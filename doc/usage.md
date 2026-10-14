# helix.nvim

A selection-first Helix editing engine for Neovim **0.11+**. It owns persistent
selections, multiple cursors, normal/select/insert state, textobjects, and edit
transactions. Input is intercepted with `vim.on_key`; edits use the buffer API;
selections and cursors use extmarks. No editing keymaps or Vim operator replay.

**Release status: experimental.** 49 engine tests and 21 simulated-host tests pass
locally, including 8,000 deterministic random editing steps. The 25 real-Neovim
integration tests are written but have **not run here**: this environment has no
Neovim executable, and the network permission requests for its download were
interrupted. The included CI workflow has not been executed. These results do not
establish production readiness or full Helix parity.

## Try it in isolation

Extract this directory, then run:

```sh
nvim -u NONE --cmd 'set rtp+=/absolute/path/to/helix.nvim' \
  -c "lua require('helix').setup()" example.txt
```

Inside `outer([hello])`, put the cursor on `hello` and type `mimcworld<Esc>`.
The result is `outer([world])`. Inside `let r = /abc/;`, `ma/d` deletes `/abc/`.
At the beginning of three lines, `CCi// <Esc>` prefixes all three lines.

## Install

With lazy.nvim, use a local plugin specification:

```lua
{
  dir = '/absolute/path/to/helix.nvim',
  lazy = false,
  config = function()
    require('helix').setup({
      auto_enable = false,
      history_limit = 200,
    })
  end,
}
```

Without a plugin manager:

```lua
vim.opt.runtimepath:prepend('/absolute/path/to/helix.nvim')
require('helix').setup({ auto_enable = false })
```

Run `:HelixEnable` in an editable ordinary buffer. Use `:HelixDisable` to restore
native Vim editing or `:HelixToggle` to switch. `auto_enable = true` enables
ordinary editable buffers on entry. Explicitly disabling a buffer stays in effect
when you leave it and return. Read-only, terminal, prompt, and special buffers are
excluded. `require('helix').teardown()` removes the hooks and commands.

An optional statusline segment is `%{v:lua.require('helix').statusline()}`.
Highlights are `HelixSelection`, `HelixCursor`, and `HelixPrimaryCursor`.

## Editing

| Input | Operation |
| --- | --- |
| `mim` / `mam` | Inside / around the closest enclosing bracket or quote pair |
| `mi/` / `ma/` | Inside / around paired slashes, respecting escaped slashes |
| `mi(`, `ma[`, `mi"`, etc. | Explicit paired bracket or literal delimiter |
| `2mim` | Second enclosing pair |
| `miw`, `maw`, `miW`, `maW`, `mip`, `map` | Word, WORD, or paragraph textobject |
| `ms` then a delimiter | Surround all selections |
| `h j k l`, arrows | Move every selection |
| `w b e`, `W B E` | Word / WORD selections |
| `f F t T` then a character | Find through text, across line boundaries |
| `v`, Escape | Toggle extension / return to normal state |
| `gg`, `ge`, `gh`, `gl` | File and line boundaries |
| `C`, Alt-Shift-C | Copy the primary selection down / up one line |
| `%`, `x` | Select file / select line; repeated `x` extends down |
| `s`, `S` | Select regex matches / split selections on matches |
| Alt-S | Split selections on newlines |
| `i`, `a`, `c` | Insert before, append after, change every selection |
| `I`, `A`, `o`, `O` | Insert at indentation, append to line, open below / above |
| Backspace, Ctrl-H, Ctrl-W, Delete, Ctrl-D | Delete characters / previous word while inserting |
| Enter, Tab, arrows, Home, End | Insert or move all insertion points |
| `d`, `y`, `p`, `P`, `R` | Delete, yank, paste after / before, replace with register |
| `r` then a character | Replace selected characters |
| `u`, `U` | Engine undo / redo, restoring selection state |
| `~`, backtick, Alt-backtick | Toggle ASCII case / lowercase / uppercase |
| `;`, Alt-`;`, `,`, Alt-`,` | Collapse, reverse, keep primary, remove primary |
| `(`, `)` | Rotate primary selection |

Counts apply to movement, cursor copying, line selection, and surround selection.
Yanks use an internal per-selection register. When register and selection counts
match, paste distributes entries; otherwise, entries are joined with newlines.
A whole insert session is one engine undo step. Entering insert and escaping
without changing text preserves both undo and redo history.

`:HelixSelect pattern` and `:HelixSplit pattern` provide regex operations without
a prompt. Patterns use **Vim regex syntax**. For example, select the whole buffer
with `%`, type `s`, enter `cat`, then `cdog<Esc>` to change all matches.
Bracketed paste inserts multiline text at all insertion points.

## How this relates to a native mode

Neovim does not expose an API for adding a new core mode. The underlying Neovim
mode stays normal while this plugin owns the input parser and editing state.
This provides selection-first operations and simultaneous editing rather than
translating Helix keys into Vim commands. A new value from Neovim's `mode()` would
require a Neovim core change.

Consequently, native insert-mode completion, insert-mode snippets, `InsertEnter`,
Vim dot-repeat, and insert mappings do not run during plugin insertion. This is
not a full Helix implementation. Unsupported editing keys are consumed; they do
not fall through to native Vim operators.

`vim.on_key` runs **after** normal mappings. Existing mappings can therefore delay
or transform input before it reaches this engine. Evaluate the isolated command
above first. Native `:` commands, Ctrl-W window commands, and Ctrl-L redraw remain
available. Input is parsed synchronously; buffer writes are deferred until
Neovim releases textlock, with flushes before command-line entry, writes, and
buffer changes.

## Current boundaries

* Surround matching is literal, not tree-sitter aware. Quotes and brackets inside
  strings/comments participate. There are no tree-sitter objects for functions,
  classes, arguments, or tags, and no surround replace/delete commands yet.
* Editing preserves UTF-8 codepoint boundaries. Vertical moves use Neovim display
  width, including wide characters and tabs. Grapheme clusters, Unicode word
  classes, Unicode case conversion, and bidirectional text need further work.
* Search/navigation, formatting, indentation, LSP, completion, macros, named
  registers, system clipboard integration, and the full Helix command set are
  not implemented.
* Undo uses bounded document snapshots. Native `:undo` and external buffer edits
  start a new engine history boundary. Native Vim undo history and engine undo
  history are separate. A conflicting external edit cancels pending engine text
  instead of overwriting external changes.
* Simultaneous edits commit as one minimal **spanning** buffer edit. Native marks
  inside the span may move even when the text around them is unchanged.
* User-configured normal mappings and other input-intercepting plugins require
  compatibility testing. The included tests do not establish full Helix parity.

## Test

```sh
make test-local                  # texlua by default
make test-local LUA=lua          # Lua 5.1+; no third-party Lua packages required
make test-nvim NVIM=/path/to/nvim # Neovim 0.11+, runs every suite
make test                        # every suite using Neovim's bundled Lua
```

`tests/host_spec.lua` is a **host double**, not a substitute for Neovim. It checks
adapter logic, input ordering, textlock discipline, transaction boundaries,
Unicode diffs, stale edits, native write barriers, paste, and lifecycle.
`tests/nvim_spec.lua` exercises Neovim's real input listener, buffers, extmarks,
command line, paste, window switching, and enable/disable behavior.

`.github/workflows/test.yml` runs the real suites on Neovim 0.11.4 and stable once
this project is placed in a GitHub repository with Actions enabled. See
[TESTING.md](../TESTING.md) for the current verification record.

## Lua API

`setup(opts)`, `enable(buf?)`, `disable(buf?)`, `teardown()`, `feed(key, buf?)`,
`select_regex(pattern, buf?, split?)`, `get_state(buf?)`, and `statusline()`.
`feed` accepts one engine key, such as `'<Esc>'` or a Unicode character.
`get_state` returns a copy. Selection offsets are zero-based half-open UTF-8
byte ranges. `User HelixModeChanged` fires when the rendered editing state changes.

MIT license.
