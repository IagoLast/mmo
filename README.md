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

## Play in one command

```bash
git clone git@github.com:IagoLast/mmo.git
cd mmo
make play
```

That's it. `make play` does everything:

1. Installs what's missing (`cloudflared`, `rgbds`, npm deps) via Homebrew.
2. Builds the ROM from [`pret/pokered`](https://github.com/pret/pokered) (it's
   not in the repo — it's a copyrighted cart, so the `.gitignore` blocks it).
3. Builds the WebAssembly client **with the 3D voxel mode**.
4. Starts the coordinator server.
5. Opens a public `trycloudflare.com` tunnel and prints a link:

```
  ┌──────────────────────────────────────────────────────────────────
  │  Partida lista
  │
  │  Comparte este enlace (pagina + ROM + servidor, todo en uno):
  │  https://xxxx.trycloudflare.com/?server=wss://xxxx.trycloudflare.com/ws
  │
  │  Ctrl-C cierra la partida para todos.
  └──────────────────────────────────────────────────────────────────
```

Share that link. Whoever opens it loads the page, the ROM, and the server
connection in one go — no file picker, no setup on their side. **Ctrl-C**
closes the game for everyone.

### Variants

```bash
make play-local    # same, but only on your LAN — no public tunnel
make rebuild        # rebuild the web client (e.g. after changing the mod)
```

### Requirements

`make play` auto-installs `cloudflared` and `rgbds` via `brew` if they're
missing, and `npm install` for both `backend/` and `web/`. You need:

- **macOS** (the bootstrap uses `brew` and `ipconfig`). Linux works too if you
  install `cloudflared`, `rgbds`, `node ≥ 22`, `python3`, and `zip` yourself.
- **Node.js ≥ 22** — `brew install node`.

> ⚠️ **The tunnel serves the ROM to anyone who reaches it.** `make play` is for
> a private session with friends: the `trycloudflare.com` URL is public while
> the tunnel is up, so don't leave it open unattended. For the copyright-safe
> model (each player brings their own ROM, none is served), see
> [GitHub Pages](#publish-the-client-on-github-pages) below.

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

`make play` does this for you on first run. The `.gitignore` blocks `*.gb`,
`*.gbc`, `*.sav`, and extracted data; the client build aborts if it detects any
of them in the bundle, and the Pages workflow checks again before publishing.

---

## Publish the client on GitHub Pages

`make play` runs the client from your laptop. For a permanent, copyright-safe
setup (no ROM served, players supply their own), publish the client on GitHub
Pages and point it at a server you run separately.

Fork this repository and under **Settings → Pages** choose
`Source: GitHub Actions`. On the next push, your client lives at:

```
https://YOUR-USERNAME.github.io/pokemon-mmo/
```

You can also trigger it manually from **Actions → Publish web client → Run
workflow**. It takes a few minutes: it's the entire engine compiled to
WebAssembly.

Then run only the server and hand out a link:

```bash
scripts/host-game.sh
```

It starts the server in Docker, opens a public tunnel, and prints:

```
  https://your-username.github.io/pokemon-mmo/?server=wss://something.trycloudflare.com/ws
```

Here the page is on Pages and the ROM is **not** served — each player loads
their own from their browser. You need [Docker](https://docs.docker.com/get-docker/)
and `brew install cloudflared`. To play only on your local network,
`scripts/host-game.sh --local` skips the tunnel.

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
make setup                                # builds the ROM and prepares everything
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
| Health HTTP | `http://127.0.0.1:3000/health` |
| WebSocket (dev) | `ws://127.0.0.1:7779` (own port, via `WS_PORT`) |
| WebSocket (prod) | `/ws` over the HTTP port |

The coordinator and protocol are shared between TCP and WebSocket. In
development the WebSocket also opens its own port because `web/serve.py` acts
as a proxy to it; without `WS_PORT` defined only `/ws` remains, which is the
only thing a PaaS or a tunnel can reach.

### Tests

```bash
make test
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
| `Makefile` / `scripts/` | the `make play` entry point and the launch tooling |

The first three are copies with our own changes, not submodules: the MMO layer
and the browser fixes live inside them. Each keeps its original license.
