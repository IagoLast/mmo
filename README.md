# Link Battle MMO

> **Disclaimer:** non-commercial proof of concept, built for fun and for
> educational purposes. **Not affiliated with Nintendo, The Pokémon Company,
> Game Freak, or Creatures Inc.** No ROMs, sprites, or original assets are
> distributed here — each player supplies their own ROM, which never leaves
> their browser. Full text in [`DISCLAIMER.md`](DISCLAIMER.md).

Gen 1, in the browser, with your friends. You see each other on the map, you
challenge each other by pressing **A** in front of another trainer, and you
battle using the game's original `LinkBattle` engine.

No sign-up, no passwords, no accounts: your public name is your trainer's name.
The server only relays positions and battle turns.

## Play

```bash
git clone git@github.com:IagoLast/mmo.git
cd mmo
make play
```

`make play` installs what's missing, builds the ROM and the WebAssembly client,
starts the server, and prints a public `trycloudflare.com` link. Share it —
whoever opens it gets the page, the ROM, and the server in one go. **Ctrl-C**
closes the game for everyone.

⚠️ That link serves the ROM to anyone who reaches it, so it's for a private
session with friends — don't leave it up unattended. For the copyright-safe
setup (every player brings their own ROM), see [Hosting](#hosting) below.

**You need** macOS with **Node.js ≥ 22**; `cloudflared` and `rgbds` are
installed via `brew` on first run. Linux works if you install `cloudflared`,
`rgbds`, `node ≥ 22`, `python3`, and `zip` yourself.

```bash
make play-local   # LAN only, no public tunnel
make rebuild      # rebuild the web client
```

## The ROM

Not distributed here. This repo ships the [`pret/pokered`](https://github.com/pret/pokered)
disassembly, and `make play` builds the cart from it on first run
(`make -C pokered red`). `.gitignore` blocks `*.gb`, `*.gbc`, `*.sav`, and
extracted data; the client build and the Pages workflow both abort if any of it
reaches the bundle.

## Hosting

For something permanent, publish the client and run the server separately — the
page serves no ROM, so each player loads their own.

- **Client:** fork, then **Settings → Pages → Source: GitHub Actions**. Lands at
  `https://YOUR-USERNAME.github.io/pokemon-mmo/`. It's a plain static folder
  (`web/dist/`) with no COOP/COEP requirement, so Netlify, S3, or
  `python -m http.server` work the same.
- **Server:** `docker build -t pokemon-mmo-server backend && docker run --rm -p 8080:8080 pokemon-mmo-server`.
  One port, `GET /health` plus the game WebSocket on `/ws`. Any PaaS that
  injects `PORT` runs it as-is.
- **Both at once:** `scripts/host-game.sh` starts the server in Docker, opens a
  tunnel, and prints the ready-made Pages link (`--local` skips the tunnel).

Players reach a server via `?server=wss://your-server/ws` in the URL. Bake in a
default with `web/build-web.sh --server wss://your-server/ws`; the client
prefers `?server=` → baked-in value → whatever the player types.

## Development

```bash
make setup                    # build the ROM and prepare everything
./scripts/run-server.sh       # terminal 1
./scripts/run-client.sh red   # terminal 2  (one identity = one save)
./scripts/run-client.sh blue  # terminal 3
make test
```

Two identities on the same map appear as walkable NPCs: stand in front of one
and press **A**. For the web client, `./web/build-web.sh` then `./web/serve.py`
(<http://127.0.0.1:8080>) — details in [`web/README.md`](web/README.md).

Ports: desktop TCP `7778`, health `3000`, dev WebSocket `7779` (`WS_PORT`),
production WebSocket `/ws` on the HTTP port. The coordinator and protocol are
shared between the two transports.

## What's inside

| | |
|---|---|
| `gen1recomp/` | the engine in LÖVE ([bryanthaboi/gen1recomp](https://github.com/bryanthaboi/gen1recomp)), with the MMO layer in `src/mmo/` |
| `DramaticShapeVoxelMod/` | the 3D voxel mode ([DramaticShape](https://github.com/DramaticShape/DramaticShapeVoxelMod)), with browser fixes |
| `pokered/` | the Pokémon Red disassembly ([pret/pokered](https://github.com/pret/pokered)) |
| `backend/` | the coordinator (NestJS): positions, challenges, battle relay |
| `web/` | WebAssembly client packaging and the bootstrap page |
| `Makefile` / `scripts/` | the `make play` entry point and launch tooling |

The first three are copies with our own changes, not submodules. Each keeps its
original license.
