# Link Battle MMO — Makefile
#
#   make play        brings up everything (backend + web + ROM) behind a
#                   public cloudflared tunnel and prints the link to share.
#                   It's the only thing to remember.
#
#   make play-local  same without a tunnel: your local network only.
#   make rebuild     rebuilds the web client (with the voxel mod) and starts.
#   make setup       prepares the repo without starting anything (ROM + deps).
#   make test        runs the test suite.
#   make clean       removes the web client build.

ROOT := $(CURDIR)

.PHONY: play play-local rebuild setup test clean help

help:
	@echo "make play         everything behind a cloudflared tunnel (prints the link)"
	@echo "make play-local   everything on your local network, no tunnel"
	@echo "make rebuild      rebuilds the web client and starts with a tunnel"
	@echo "make setup        prepares the repo without starting anything"
	@echo "make test         runs the tests"
	@echo "make clean        removes web/dist"

play:
	@./scripts/serve-all.sh

play-local:
	@./scripts/serve-all.sh --local

rebuild:
	@./scripts/serve-all.sh --rebuild

setup:
	@./scripts/setup-mvp.sh

test:
	@(cd backend && npm install --silent && npm test && npm run build)
	@command -v luajit >/dev/null 2>&1 || { echo "luajit is not installed (macOS: brew install luajit)" >&2; exit 2; }
	@(cd gen1recomp && luajit tests/mmo_world_client_test.lua)
	@(cd gen1recomp && luajit tests/mmo_battle_flow_test.lua)
	@(cd gen1recomp && luajit tests/run_engine.lua)

clean:
	rm -rf web/dist
