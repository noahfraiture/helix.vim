# Changes from the first prototype

* Parse input synchronously while deferring buffer writes outside textlock.
  Fast insert sequences preserve literal colons and punctuation.
* Flush pending changes before command entry, saving, buffer leave, and disable.
  Reject stale writes after conflicting external changes.
* Match symmetric delimiters around the cursor, including arbitrary slash path
  segments and counted outward selection, rather than pairing from document start.
* Copy cursors from the current primary selection and advance the primary.
* Use display columns for vertical motion and cursor copying. Cache line starts
  to avoid repeatedly scanning the document when rendering many selections.
* Keep inserts in one undo step, preserve redo on no-op inserts, restore original
  selections after paste undo, and bound undo snapshots.
* Preserve UTF-8 boundaries in edits and minimal buffer diffs. Cover Unicode
  insertion, replacement, backspace, and wide-character cursor copying.
* Preserve per-buffer state, sticky disable, and safe paste-hook teardown.
* Add find motions, line insertion, literal surround addition, regex splitting,
  internal-register arity handling, and additional selection controls.
* Expand to 54 engine and 21 simulated-host tests with randomized invariant and
  batching checks. Add 38 real-editor tests and a Neovim CI matrix.

All 113 tests pass locally and in CI on Neovim 0.11.4 and 0.12.6.
Installation through vim.pack also passes on 0.12.6. Real-editor testing fixed
Neovim normal-mapping expansion during insertion and anchored regex offsets.
This remains an experimental development build with the scope documented in
README.md and doc/usage.md.

## Word movement and insertion cursor fixes

* Fix repeated `w`/`W` getting stuck on the first word's trailing space. Cover
  counts, punctuation, tabs, newlines, select mode, and EOF.
* Use Neovim's cursor for the primary insertion point and allow one cell past
  EOL without changing the user's global cursor settings. Restore temporary
  window options across splits, floating windows, buffer leave, and teardown.
* Add a scoped proposal for implementing a genuine native backend in Neovim.
