# Verification record

Date: 2026-10-15. Tested locally with Neovim 0.11.4 and 0.12.6 (LuaJIT).

| Suite | Result on each Neovim version |
| --- | --- |
| Selection engine | 54 tests passed |
| Simulated Neovim host | 21 tests passed |
| Real Neovim integration | 38 tests passed |
| Random engine editing | 6,000 command steps, valid ranges and UTF-8 |
| Random adapter batching | 2,000 command steps, output agrees with engine |
| `vim.pack` installation | Passed locally and in CI on 0.12.6 |

Run all 113 tests from the repository root with `make test`. To select a specific
Neovim executable: `make test NVIM=/path/to/nvim`. The engine requires 0.11+;
`vim.pack` installation requires 0.12+.

The real-editor tests cover actual input interception, nested and slash
textobjects, original typed input through normal mappings, multi-key mappings,
multiple cursors, undo/redo, anchored regex matching, prompt callbacks, Unicode
and multiline paste, native writes, external edits, selection decorations,
window switching, and enable/disable lifecycle. The host double checks adapter
logic separately and is not presented as real-editor validation.

CI runs the three suites independently on 0.11.4 and stable. Stable also installs
the current repository revision through `vim.pack` with isolated data/config
folders and performs a textobject edit using the installed plugin. Results:
[Passing run](https://github.com/noahfraiture/helix.vim/actions/runs/38811009644),
verified code revision `8fb5564f1a3851fb8dc9eed5f203842789742901`.

Helix surround behavior was checked against its upstream implementation:
[helix-core/src/surround.rs](https://github.com/helix-editor/helix/blob/master/helix-core/src/surround.rs).
Symmetric delimiters search outward from the cursor; the path-segment regression
checks this explicitly. The plugin still lacks syntax-aware matching and full
Helix conformance. See [doc/usage.md](doc/usage.md) for supported scope.

The word-motion regressions check repeated `w`/`W`, counts, punctuation, tabs,
newlines, select-mode anchors, and EOF. Cursor regressions verify true EOL
insertion, no duplicate primary selection highlight, unchanged `guicursor`, and
restoration of local `virtualedit` across disable, buffer leave, splits, inactive
floating windows, and teardown. The user's personal init.lua was not available
in the cloud workspace; these regressions run in isolated Neovim sessions.
