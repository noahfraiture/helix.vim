# A first-class Helix mode in Neovim

A native Helix mode is technically achievable, but the public Lua plugin API
cannot register a new core mode. That requires changes to Neovim itself: either
an upstream contribution or a maintained fork. This document is a proposal, not
an implemented native backend.

The current plugin already owns selection state and applies simultaneous edits.
Its limitation is how that state connects to Neovim: input arrives through
`vim.on_key`, the host still reports normal mode, insertion is performed through
buffer edits, and undo uses plugin snapshots. Compiling the same engine into a
native library would not change those host semantics.

## First experiment

Keep the existing plugin usable while testing a small, separately gated change
to Neovim core. The first milestone should demonstrate:

1. An explicit selection-first editing state with its own input dispatch, entered
   and exited without intercepting Vim normal-mode keys through `vim.on_key`.
2. A window-local collection of oriented selections, with a primary selection.
   The core owns and renders this state, including empty insertion positions.
3. A single edit transaction applied to two selections, with native undo/redo
   restoring both text and selections together.
4. Public APIs and mode-change notifications that let the Lua plugin use that
   backend without carrying a second authoritative selection/undo state.

Acceptance scenario: select two words, change both in one operation, press native
undo once, and recover both words and their selections. While this state is
active, Neovim should report it explicitly and should not first expand Vim's
normal mappings. Existing Vim editing must continue to work when it is disabled.

## Integration after that

* Reuse native insertion machinery and connect it to selection transactions.
  Completion acceptance, backspace, paste, autoindent, and external edits need
  defined behavior at every selection. Mirroring the primary cursor's final text
  is insufficient when contexts or selection lengths differ.
* Add cursor shapes, GUI mode metadata, mouse/selection behavior, registers,
  repeat, and an explicit policy for mappings and mode-specific events.
* Expose sensible defaults for existing Lua integrations. LSP completion,
  diagnostics, snippets, and plugins that assume one cursor or Vim visual mode
  need compatibility testing; they do not become multicursor aware automatically.
* Compare movement and textobject behavior against Helix, including counts,
  selection direction changes, punctuation, Unicode, newlines, and EOF.

Relevant Neovim 0.12.6 starting points:

* [state_defs.h](https://github.com/neovim/neovim/blob/v0.12.6/src/nvim/state_defs.h)
  defines editor states and mode bits used by mappings. Adding a flag alone is
  insufficient: mapping and mode-reporting behavior must be specified too.
* [normal.c](https://github.com/neovim/neovim/blob/v0.12.6/src/nvim/normal.c)
  contains the normal-state dispatcher and its operator-oriented command state.
* Native insertion, undo, rendering, API, and event handling must be considered
  together when implementing and testing the experiment.

## What to improve in the plugin meanwhile

Prioritize predictable editing before adding more shortcuts:

1. Complete movement/selection conformance tests for `w/b/e`, counts, direction
   changes, line boundaries, and Unicode graphemes.
2. Search and selection navigation: `/`, `?`, `n`, `N`, and `*`.
3. Clipboard and named registers; indentation; repeat last edit.
4. Syntax-aware textobjects and surround replacement/deletion.
5. Native insertion/completion interoperability, explicitly treating multicursor
   completion as a design problem rather than blindly replaying the primary edit.

A fork carries ongoing upstream-rebase and compatibility costs. The small core
experiment is intended to measure those costs before committing to a broad fork.
