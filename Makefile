# Link Battle MMO — Makefile
#
#   make play        levanta todo (backend + web + ROM) detras de un tunel
#                   publico de cloudflared e imprime el enlace para compartir.
#                   Es lo unico que hay que recordar.
#
#   make play-local  lo mismo sin tunel: solo tu red local.
#   make rebuild     rehace el cliente web (con el mod de voxels) y arranca.
#   make setup       prepara el repo sin arrancar nada (ROM + dependencias).
#   make test        pasa la suite de tests.
#   make clean       borra el build del cliente web.

ROOT := $(CURDIR)

.PHONY: play play-local rebuild setup test clean help

help:
	@echo "make play         todo detras de un tunel cloudflared (imprime el enlace)"
	@echo "make play-local   todo en tu red local, sin tunel"
	@echo "make rebuild      rehace el cliente web y arranca con tunel"
	@echo "make setup        prepara el repo sin arrancar nada"
	@echo "make test         pasa los tests"
	@echo "make clean        borra web/dist"

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
	@command -v luajit >/dev/null 2>&1 || { echo "luajit no esta instalado (macOS: brew install luajit)" >&2; exit 2; }
	@(cd gen1recomp && luajit tests/mmo_world_client_test.lua)
	@(cd gen1recomp && luajit tests/mmo_battle_flow_test.lua)
	@(cd gen1recomp && luajit tests/run_engine.lua)

clean:
	rm -rf web/dist
