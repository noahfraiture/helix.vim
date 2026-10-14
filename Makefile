.PHONY: test test-local test-engine test-host test-nvim
LUA ?= texlua
NVIM ?= nvim

test: test-nvim

test-local: test-engine test-host

test-engine:
	$(LUA) tests/engine_spec.lua

test-host:
	$(LUA) tests/host_spec.lua

test-nvim:
	$(NVIM) --headless -u NONE -l tests/engine_spec.lua
	$(NVIM) --headless -u NONE -l tests/host_runner.lua
	$(NVIM) --headless -u NONE -l tests/nvim_spec.lua
