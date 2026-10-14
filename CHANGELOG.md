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
* Expand to 49 engine and 21 simulated-host tests with randomized invariant and
  batching checks. Add 25 real-editor tests and a Neovim CI matrix.

The real-editor suite and CI remain unrun in this executor. This is an
experimental development build, not a verified production release.
