# Link Battle MMO — web client

The same `gen1recomp` client, packaged as a web page: LÖVE compiled to
WebAssembly with [love.js](https://github.com/Davidobot/love.js), the game in a
`.love` bundled inside the page, and the MMO layer over WebSocket against the
same backend the desktop client uses.

The ROM does not travel: you upload it on the page, it is stored in your
browser, and the importer extracts it right there.

## Build and serve

```bash
./web/build-web.sh        # leaves the build in web/dist/
./web/serve.py            # http://127.0.0.1:8080
```

`build-web.sh` needs `node` and `zip`, and nothing else: **no emsdk required**.
The npm package `love.js` (pinned to `11.4.1` in `web/package.json`) ships a
prebuilt `love.wasm`, and the script runs `npm install` the first time it
can't find `web/node_modules/love.js`.

It's two steps. First it copies the game to `web/.stage/` (`main.lua`,
`conf.lua`, `src`, `libs`, `assets`, `data`, plus the three
`tools/rom_manifest*.json` and `tools/save-editor`, which are read at runtime)
and compresses it into a `.love`; then it hands it to `love.js`, which emits
the runtime. The build aborts if any of those files is missing: without the
manifest, the failure doesn't show up until the player tries to import the ROM.
At the end `web/dist/` contains:

| File | What it is |
| --- | --- |
| `index.html` | the launcher (copied from `web/index.html`, replaces love.js's) |
| `game.js` + `game.data` | your `.love` packaged as Emscripten data |
| `love.js` + `love.wasm` | LÖVE 11.4 compiled, as shipped by the npm package |
| `theme/` | love.js loader assets |
| `build-info.json` | title, `threads`, `initialMemory`, `withMods` |

Options:

| Flag | Effect |
| --- | --- |
| `--with-mods` | include `gen1recomp/mods/` (~26 MB; excluded by default) |
| `--threads` | build the threaded variant instead of the compatibility one. **Requires COOP/COEP** on the host or the page won't boot |
| `--memory BYTES` | initial wasm heap (default `268435456`, 256 MB) |
| `--title TEXT` | page and window title |

`serve.py` does four things that `python3 -m http.server` doesn't: it serves
`.wasm` as `application/wasm`, sends `Cache-Control: no-cache` so a rebuild
isn't stuck behind a stale `index.html`, adds COOP/COEP when it detects a
threaded build by reading `build-info.json`, and forwards `/ws` to the game
WebSocket.

| Flag | Effect |
| --- | --- |
| `--port` / `--host` | default `8080` and `127.0.0.1`. Use `--host 0.0.0.0` to reach it from another LAN device |
| `--ws-port` | where `/ws` is forwarded to (default `7779`, or `$WS_PORT`) |
| `--isolate` | force COOP/COEP |
| `--rom PATH` | serve that ROM at `/dev-rom.gb` and the page loads it on its own |

### Why `/ws`

A page served over `https://` **cannot** open a `ws://` connection: the browser
blocks it as mixed content. As soon as the page is no longer on
`http://localhost` — a tunnel, a phone on the LAN, any real deployment — the
WebSocket must hang off the same origin, at `wss://<host>/ws`. `serve.py`
replicates the handshake against the game port and from there passes raw bytes
without interpreting frames, so the framing can't get corrupted. In production
that job belongs to the reverse proxy that terminates TLS: all that's needed is
the wasm MIME and a `/ws` route to the backend.

`web/index.html` prefills the server field. It resolves the value in this
order, and the first one that exists wins:

1. **`?server=wss://…` in the page URL.** That's how a game is shared: the build
   is static and doesn't know who hosts, and the link says so. It's also
   accepted in the fragment (`#server=…`), which never reaches anyone's logs.
   `scripts/host-game.sh` composes this link for you.
2. **The value baked into the build**, via `build-web.sh --server wss://…`,
   which is written to `<meta name="pokemon-mmo:server">`. For a permanent
   server whose address doesn't change.
3. **What the player typed** on a previous visit. It's stored alongside the
   then-current default, to tell a deliberate choice from a default that just
   carried over: if the player never touched it, a new `--server` moves it; if
   they typed it by hand, it's respected.
4. **The origin heuristic:** `ws://localhost:7779` in local development,
   `wss://<host>/ws` behind your own reverse proxy. On a static host
   (`*.github.io`, `*.pages.dev`, `*.netlify.app`, `*.vercel.app`) there's no
   `/ws` to guess, so the default there is to play offline.

### `--rom`, and why it's not in the build

Getting a `.gb` onto a phone for testing ranges from tedious to impossible, so
`--rom` lets the server hand it to the page: the first load does a
`HEAD /dev-rom.gb`, and if it exists it downloads it and stores it in the
browser. If you pick a ROM by hand, that one wins forever (and "Change ROM"
asks again instead of pulling the server's).

The ROM is read into memory and served from a path that **does not exist inside
`web/dist/`**, on purpose: a cartridge must never end up inside the build
output, where it'd be one `git add` or one deploy away from being published.
Even so, while `--rom` is on, anyone who reaches the server can download it —
the server itself warns about this on startup. Don't leave it on an unattended
public tunnel.

## How to use the page

1. **Your ROM.** Drag or pick a `.gb` / `.gbc`. It's stored in the browser and
   never asked for again. If it's not exactly 1.00 MB the page warns but lets
   you continue: the engine importer is the one that decides.
2. **Server URL.** Already resolved (see above): normally nothing to type. In
   development, `ws://localhost:7779`, the WebSocket port of
   `./scripts/run-server.sh`. In production, `wss://…/ws`. Empty = local
   offline game.
3. **Session name.** Default `web`. It separates distinct games within the same
   browser; it's not a user or an account. It's normalized to
   `pokemon-mmo-<name>`, the same scheme `scripts/run-client.sh` uses on
   desktop.

Once in the game, the top bar has **Fullscreen**, **Console** (the LÖVE and
page log), and **Change ROM**, which forgets the stored ROM and reloads.
Changing ROM **does not** delete your save.

On a touch device the page enters immersive mode directly and enables the
**engine's touch controls** (`POKEPORT_TOUCH=1`): the same overlay the
Android/iOS builds ship — d-pad, A/B, START/SELECT drawn over the game, fed by
`love.touch` and repositionable from the launcher's "Touch Controls" editor.
`?pad=html` (or the old `?nativepad=0`) switches to the page's own Game Boy
pad, which goes through synthetic KeyboardEvents; it stays as an alternative
in case some browser doesn't deliver touch to SDL properly.

Configuration reaches the engine through `arg`, not environment: the page
boots LÖVE with `--env POKEPORT_IDENTITY=…` and, if there's a server,
`--env POKEPORT_MMO_ADDR=host:port --env POKEPORT_MMO_DEFAULTS=1`.
`src/core/WebEnv.lua` folds them into `os.getenv`, so all existing readers work
untouched. The `host:port` only needs to be readable: the page gives Emscripten
the real endpoint whole (`Module.websocket.url`), which is what lets a single
`socket.tcp()` in Lua end up in a `wss://` with a different host and path.

## Where the data lives

| Data | Where | How |
| --- | --- | --- |
| The ROM | the page's IndexedDB (`pokemon-mmo-web`) | the page re-injects it into `…/picked_rom.gb` before LÖVE's first frame, and `RomImporter` picks it up just like an Android `pick` |
| Save and extracted cache (`data/generated`, `assets/generated`) | LÖVE's save directory, `/home/web_user/love/pokemon-mmo-<session>` | IDBFS, synced to IndexedDB |
| Server URL and session name | `localStorage` | in private mode they simply don't persist |

Nothing derived from the ROM is served from the server or packaged into the
build. `build-web.sh` deletes `data/generated` and `assets/generated` from
staging and **then checks they're gone**: if they're still there, the build
fails instead of publishing them. The browser obtains that data the same way a
fresh desktop install does — by extracting it from the ROM supplied by whoever
plays.

## Differences from the desktop client

| | Desktop | Browser |
| --- | --- | --- |
| Lua runtime | LuaJIT | plain Lua 5.1 |
| `bit` | built into LuaJIT | `src/core/BitOps.lua`, published as a global from `conf.lua` |
| FFI | yes | no: Discord Rich Presence and the portable mode are out |
| P2P link | `lua-enet` | not available |
| MMO | TCP `7778` | WebSocket `7779` over SOCKFS, with non-blocking connect |
| Configuration | environment variables | `--env NAME=VALUE` pairs in `arg` |
| LÖVE version | 11.5 | 11.4 (the one love.js ships) |
| ROM | native picker or folder | uploaded on the page |

The MMO layer does travel because it goes over WebSocket. `src/mmo/Transport.lua`
doesn't have a second implementation for the browser: love.js links LuaSocket and
Emscripten's SOCKFS maps the TCP socket onto a WebSocket, so `socket.tcp()` and
the line-based JSON framing cross over unchanged. The only thing that doesn't
survive is the *blocking* connect — the handshake only advances when the page's
event loop spins, and it doesn't spin while Lua is stopped inside `connect()`.
That's why on web the dial is a state machine that `update()` drives frame by
frame, and `connect()` returning `true` means "dialing", not "connected".

The framing is line-based in **both directions** precisely because of this: a
WebSocket looks message-oriented, but SOCKFS forwards the bytes the socket
write produced, so one frame can carry two messages or half of one. The message
boundary belongs to the stream, not the frame, and that's why the server
(`JsonLineDecoder`) is the same for TCP and WebSocket and terminates every send
with `\n`.

The P2P link doesn't travel: `src/link/Net.lua` needs `lua-enet`, which doesn't
usefully exist in the browser. The link screen degrades on its own.

## Deployment

The build is static. Copy `web/dist/` to any host — Pages, S3, whatever — with
a single requirement: it must serve `.wasm` as
`Content-Type: application/wasm`. Without that the browser rejects streaming
compilation.

- The **default** build is the compatibility one: it doesn't use
  `SharedArrayBuffer`, so it **needs no COOP/COEP** and works on hosts where you
  can't touch headers.
- With `--threads`, the host **must** send
  `Cross-Origin-Opener-Policy: same-origin` and
  `Cross-Origin-Embedder-Policy: require-corp`. Without cross-origin isolation
  the page won't boot, which is why that variant doesn't work on hosts that
  don't let you set headers.
- If the page is on `https://`, the game server must be `wss://`: the browser
  blocks `ws://` as mixed content.
- Build files always keep the same names (`game.data`, `love.wasm`…), so either
  serve them uncached or version-bust them; `serve.py` sends `no-cache` on
  everything.

## Limitations and known issues

### Performance

The engine runs on the Lua 5.1 interpreter compiled to wasm: there's no JIT
and no native `bit`. Measured in this repo (LuaJIT 2.1, Apple Silicon):

| Workload | With JIT / native `bit` | Interpreter only / `BitOps` |
| --- | --- | --- |
| Typical engine code: tables, strings, `math` (400k iterations) | 0.11 s | 0.87 s (~8x) |
| 5 bit ops × 2M iterations | 0.042 s | 4.29 s (~100x) |

Both measurements are native: they compare LuaJIT's JIT with its own
interpreter, and `bit` with `BitOps`. The browser pays both penalties at once,
plus the cost of running the interpreter on top of wasm. `BitOps` is optimized
to blunt the second one (it walks eight nibbles through 16×16 tables instead of
32 separate bits), but it doesn't eliminate it.

In practice the game at 160×144 runs fine; what you notice is anything that
does heavy work all at once.

### Other

- **The first ROM import is slow.** It happens entirely in the browser, on the
  interpreter and with `BitOps`, and it's exactly the kind of load it handles
  worst. It only happens once per session: after that the extracted cache is
  already in the save directory.
- **Persistence depends on Emscripten syncing.** The save directory is IDBFS,
  and it only reaches IndexedDB when Emscripten does the sync. love.js only
  hooks it to `beforeunload`, which isn't reliable as a save system, so the
  page forces a sync every 10 s and every time the tab is hidden. Even so, a
  hard close can cost up to 10 s of progress.

  The forced sync calls `Module.FS_syncfs`, which `build-web.sh` exports by
  patching `love.js` — and it has to be that way: the first version dispatched a
  synthetic `beforeunload` to reuse love.js's handler, but SDL registers its
  own `beforeunload` callback that pushes an exit event into LOVE. Result: the
  game closed silently (frozen frame, no error) on the first 10 s tick. Never
  dispatch `beforeunload` while the game is running.
- **love.js ships LÖVE 11.4**, while desktop targets 11.5. `conf.lua` declares
  `t.version = "11.4"` on web to avoid printing the version warning on every
  boot, but anything that depends on 11.5 isn't there. The difference that
  matters is covered by `src/core/LoveCompat.lua`: in 11.5 a
  `love.filesystem.read` of a non-existent file returns `nil, message`, and in
  11.4 **it throws**. The engine is written against 11.5, so without that shim
  the first boot died with `Could not open file rom-cache.complete. Does not
  exist.` — which is just "you haven't imported any ROM yet". LoveCompat
  reinstates the 11.5 contract and installs nothing on 11.5+.
- **The heap is set in the page, not in love.js.** love.js's `-m` only sizes the
  `index.html` it generates, and `build-web.sh` replaces that file with ours.
  That's why the build rewrites the `window.POKEMMO_MEMORY` line in
  `web/dist/index.html` with the `--memory` value (and aborts if it can't apply
  it). If you serve `web/index.html` by hand without going through the build,
  the heap is the default value on that line: 256 MB.
- **Fatal errors go to the page console, not a dialog.** love.js implements
  `SDL_ShowSimpleMessageBox` as a `window.alert`, and a modal leaves the
  renderer thread in a nested event loop: the canvas stops and the tab looks
  hung with no way to read the error. The page redirects those notices to the
  log.
- **In private browsing the ROM may not persist**, and neither will settings.
  You'll have to upload it again each session.
