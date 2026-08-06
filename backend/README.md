# Link Battle MMO — backend MVP

NestJS coordinator server for the `gen1recomp` desktop prototype. There are no
accounts or databases: each connection picks a guest name and all state lives
in memory.

## Startup

Requires Node.js 22 or later.

```bash
npm install
npm run dev
```

- HTTP: `http://localhost:3000/health`
- TCP: `localhost:7778`
- WebSocket: `ws://localhost:7779`
- Variables: `HTTP_PORT`, `TCP_PORT`, `WS_PORT`, and `HOST`

Each TCP message is a JSON object on a single line terminated by `\n`. On
WebSocket, each text frame contains exactly one JSON object, with no `\n` or
NDJSON. Both transports share the same protocol, coordinator, and world: a TCP
client can see and challenge a WebSocket client. The per-message limit is 64
KiB. The ROM and the save must not be uploaded to this service.

## Presence flow

The first message must be:

```json
{"type":"join_world","name":"Red","mapId":"PALLET_TOWN","x":5,"y":6,"px":40,"py":48,"facing":"down","moving":false}
```

`x/y` are tile coordinates; `px/py` are optional and allow visual
interpolation. `facing` is `up`, `down`, `left`, or `right`.

The server replies with three messages. `welcome` + `snapshot` is the main
contract; `world_snapshot` is emitted as an aggregated message to ease early
clients:

```json
{"type":"welcome","playerId":"uuid","player":{"id":"uuid","name":"Red","mapId":"PALLET_TOWN","x":5,"y":6,"px":40,"py":48,"facing":"down","moving":false}}
{"type":"snapshot","mapId":"PALLET_TOWN","players":[]}
{"type":"world_snapshot","selfId":"uuid","mapId":"PALLET_TOWN","players":[]}
```

Incremental changes are `player_joined`, `player_moved`, and `player_left`.
Movement:

```json
{"type":"move","mapId":"PALLET_TOWN","x":6,"y":6,"px":48,"py":48,"facing":"right","moving":true,"seq":42}
```

When `mapId` changes, the server emits a leave on the previous map, an entry on
the new one, and a fresh snapshot to the player.

## Challenges and battle

```json
{"type":"challenge","targetId":"uuid"}
{"type":"challenge_received","challengeId":"uuid","from":{"id":"uuid","name":"Red"}}
{"type":"challenge_reply","challengeId":"uuid","accept":true}
```

If accepted, both receive the same `battleId` and `seed`; their roles differ:

```json
{"type":"battle_start","battleId":"uuid","role":"host","opponent":{"id":"uuid","name":"Blue"},"seed":123456789}
```

The server does not interpret the lockstep protocol. It only forwards `payload`
to the opponent:

```json
{"type":"battle_message","battleId":"uuid","payload":{"frame":12,"input":1}}
```

To end voluntarily: `{"type":"battle_end","battleId":"uuid"}`. Both receive
`battle_ended`. A clean disconnect cleans up presence, pending challenges, and
battles; the opponent receives `battle_ended` with reason
`opponent_disconnected`.

Other messages: `ping`/`pong`, `challenge_sent`, `challenge_declined`,
`challenge_cancelled`, and `error` (`code`, `message`). You can only challenge
someone connected to the same map, and each player can have at most one pending
challenge or active battle.

## Commands

```bash
npm test
npm run build
npm run start:prod
```

The web client can connect directly to the WebSocket adapter. In production it
should be published behind TLS as `wss://`; TCP is kept for the desktop client.
