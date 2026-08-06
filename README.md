# Link Battle MMO

> **Disclaimer:** this is a non-commercial **proof of concept built for fun
> and for educational purposes**, **not affiliated with Nintendo, The Pokémon
> Company, Game Freak, or Creatures Inc.** "Pokémon" and the creature names are
> trademarks of their respective owners. It is not monetized in any way and is
> intended to be transformative and educational, not a substitute for any
> official product. No ROMs, sprites, or any original assets are distributed
> here: each player supplies their own ROM, which never leaves their browser.
> GitHub is authorized to take this repository down immediately if Nintendo
> requests it (see [`DISCLAIMER.md`](DISCLAIMER.md)).

Gen 1, in the browser, with your friends. You see each other on the map,
you challenge each other by pressing **A** in front of another trainer, and you
battle using the game's original `LinkBattle` engine.

There is no sign-up, no passwords, no accounts. Your public name is your
trainer's name. **Your ROM and your save never leave your browser**: the server
only relays positions and battle turns.

---

## Host a game in 5 minutes

You need two pieces, both free: a **page** (static, on GitHub Pages) and a
**server** (a small process, on your laptop or wherever you want).

### 1. Publish the page

Fork this repository and under **Settings → Pages** choose
`Source: GitHub Actions`. On the next push, your client lives at:

```
https://YOUR-USERNAME.github.io/pokemon-mmo/
```

You can also trigger it manually from **Actions → Publish web client → Run
workflow**. It takes a few minutes: it's the entire engine compiled to
WebAssembly.

### 2. Open the game

```bash
scripts/host-game.sh
```

It starts the server in Docker, opens a public tunnel, and prints the link:

```
  ┌──────────────────────────────────────────────────────────────
  │  Game open
  │
  │  Share this link:
  │  https://your-username.github.io/pokemon-mmo/?server=wss://something.trycloudflare.com/ws
  └──────────────────────────────────────────────────────────────
```

### 3. Share the link

Whoever opens it picks their ROM, their team, and joins. **Ctrl-C** closes the
game. You need [Docker](https://docs.docker.com/get-docker/) and a tunnel
(`brew install cloudflared`; no account or card required). To play only on your
local network, `scripts/host-game.sh --local` skips the tunnel.

---

## The ROM

Each player brings their own and keeps it in their browser. None is
distributed here: this repository contains the source code of
[`pret/pokered`](https://github.com/pret/pokered), with which you can build
your own:

```bash
brew install rgbds     # macOS
make -C pokered red    # leaves pokered/pokered.gbc
```

The `.gitignore` blocks `*.gb`, `*.gbc`, `*.sav`, and extracted data; the
client build aborts if it detects any of them in the bundle, and the workflow
checks again before publishing.

---

## Other ways to serve it

The client is a static folder (`web/dist/`) that needs no special headers:
the default build doesn't use `SharedArrayBuffer`, so no COOP/COEP is needed
and it works the same on Pages, Netlify, Cloudflare Pages, S3, or a
`python -m http.server`.

The server is a single-port container:

```bash
docker build -t pokemon-mmo-server backend
docker run --rm -p 8080:8080 pokemon-mmo-server
```

It serves `GET /health` and the game WebSocket on `/ws`. Any PaaS that injects
`PORT` (Render, Railway, Fly, Cloud Run) runs it with no extra config. Behind
TLS, the URL for players is `wss://your-server/ws`.

If your server is permanent, bake it into the build and hand out a clean URL
with no `?server=`:

```bash
web/build-web.sh --server wss://your-server/ws
```

**Client preference order:** `?server=` from the link → value baked into the
build → whatever the player types by hand.

---

## Development

### Setup

```bash
./scripts/setup-mvp.sh                        # builds the ROM and prepares everything
./scripts/setup-mvp.sh "/path/to/your/Red.gb"  # or start from your own ROM
```

### Two desktop clients

```bash
./scripts/run-server.sh        # terminal 1
./scripts/run-client.sh red     # terminal 2
./scripts/run-client.sh blue    # terminal 3
```

Each identity keeps its own save. Give them different names. When two
identities are on the same map they appear as walkable NPCs: stand in front of
one and press **A**.

### Local web client

```bash
./scripts/run-server.sh   # terminal 1
./web/build-web.sh        # terminal 2
./web/serve.py            # then open http://127.0.0.1:8080
```

Details in [`web/README.md`](web/README.md).

### Ports

| | |
|---|---|
| Desktop (TCP) | `127.0.0.1:7778` |
| Health HTTP | `http://127.0.0.1:3100/health` |
| WebSocket in development | `ws://127.0.0.1:7779` (own port, via `WS_PORT`) |
| WebSocket in production | `/ws` over the HTTP port |

The coordinator and protocol are shared between TCP and WebSocket. In
development the WebSocket also opens its own port because `web/serve.py` acts
as a proxy to it; without `WS_PORT` defined only `/ws` remains, which is the
only thing a PaaS or a tunnel can reach.

### Tests

```bash
(cd backend && npm test && npm run build)
(cd gen1recomp && luajit tests/mmo_world_client_test.lua)
(cd gen1recomp && luajit tests/mmo_battle_flow_test.lua)
(cd gen1recomp && luajit tests/run_engine.lua)   # full engine suite
```

---

## What's inside

| | |
|---|---|
| `gen1recomp/` | the engine, reimplemented in LÖVE ([bryanthaboi/gen1recomp](https://github.com/bryanthaboi/gen1recomp)), with the MMO layer in `src/mmo/` |
| `DramaticShapeVoxelMod/` | the 3D voxel mode ([DramaticShape](https://github.com/DramaticShape/DramaticShapeVoxelMod)), with browser-compatibility patches |
| `pokered/` | the Pokémon Red disassembly ([pret/pokered](https://github.com/pret/pokered)), for building the ROM |
| `backend/` | the game coordinator (NestJS): positions, challenges, and battle relay |
| `web/` | the WebAssembly client packaging and the bootstrap page |

The first three are copies with our own changes, not submodules: the MMO layer
and the browser fixes live inside them. Each keeps its original license.
