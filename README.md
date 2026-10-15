# helix.vim

An experimental Helix editing engine for Neovim: persistent selections,
`mim` / `ma/` textobjects, and multiple cursors. It owns its editing state and
applies edits directly; it does not replay Vim commands through editing keymaps.

## Install with `vim.pack`

Requires **Neovim 0.12+** for `vim.pack`, and Git. Add to `init.lua`:

```lua
vim.pack.add({
  { src = 'https://github.com/noahfraiture/helix.vim', version = 'main' },
})

require('helix').setup({ auto_enable = false })
```

Restart Neovim and run `:HelixEnable` in an editable file. Use `:HelixDisable`
to return to Vim editing, or `:HelixToggle` to switch. Set `auto_enable = true`
to enable the engine automatically in ordinary editable buffers.

## Try it without changing your config

```sh
git clone https://github.com/noahfraiture/helix.vim.git
cd helix.vim
nvim -i NONE -u tests/pack_init.lua tests/demo.txt
```

Confirm installation if prompted. This config loads the plugin with `vim.pack`
and enables it.
Try these sequences in the demo file (Escape means press the Escape key):

| Keys | Expected result |
| --- | --- |
| `gg8lmimcworld<Esc>` | `outer([hello])` becomes `outer([world])` |
| `ggj10lma/d` | `let r = /abc/;` becomes `let r = ;` |
| `ggjjCCi// <Esc>` | Prefix `one`, `two`, and `three` with `// ` using three cursors |
| `u` / `U` | Undo / redo the previous edit |

To test a local checkout directly, without downloading it through `vim.pack`:

```sh
nvim -i NONE -u tests/local_init.lua tests/demo.txt
```

## Automated tests

From the repository root, with Neovim 0.11+ and Make installed:

```sh
make test
# A specific executable:
make test NVIM=/path/to/nvim
```

No external Lua test dependencies are needed. The command runs the selection
engine suite, simulated-host suite, and real Neovim integration suite. Without
Neovim, `make test-local LUA=lua` runs the first two with Lua 5.1+ (`texlua` is
the default when `LUA` is omitted).

**Verification status:** all 113 tests (54 engine, 21 simulated-host, and 38
real-editor tests) pass on Neovim 0.11.4 and 0.12.6. CI also checks installation
with `vim.pack` on stable. [CI results](https://github.com/noahfraiture/helix.vim/actions).
See [TESTING.md](TESTING.md).

This is not yet a complete Helix implementation. Neovim's underlying mode remains
normal, so native insert-mode completion and snippets do not run. Mapping
prefixes may delay input, and expression mappings can run before the input hook. See
[detailed usage and limitations](doc/usage.md).

MIT license.

A genuinely native backend needs Neovim core changes; see the
[native-mode proposal](doc/native-mode.md).
