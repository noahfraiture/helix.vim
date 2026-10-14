# Verification record

Date: 2026-10-14. Runtime: texlua (Lua 5.3).

| Suite | Result |
| --- | --- |
| Selection engine | 49 tests passed |
| Simulated Neovim host | 21 tests passed |
| Random engine editing | 6,000 command steps, valid ranges and UTF-8 |
| Random adapter batching | 2,000 command steps, output agrees with engine |
| Real Neovim integration | 25 tests written; NOT RUN |
| GitHub Actions | Workflow provided; NOT RUN |

The development executor does not contain Neovim. Its filesystem was replaced
on restart, so the sources were restored from this conversation. Outbound curl
cannot reach the configured proxy inside the default command sandbox. Separate
network-permission download calls were interrupted. No real-Neovim result is
claimed, and no release-readiness claim should be inferred from simulated tests.

Run `make test-nvim` with Neovim 0.11+ before everyday use. In particular, verify
actual input suppression, textlock and CmdlineEnter behavior, save barriers,
terminal key encoding, and interactions with existing normal mappings.

Helix surround behavior was checked against its upstream implementation:
[helix-core/src/surround.rs](https://github.com/helix-editor/helix/blob/master/helix-core/src/surround.rs).
Symmetric delimiters search outward from the cursor; the path-segment regression
checks this explicitly. The plugin still lacks syntax-aware matching and full
Helix conformance.
