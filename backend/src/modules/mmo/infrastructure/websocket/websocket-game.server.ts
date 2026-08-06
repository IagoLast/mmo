import { Injectable, Logger, OnApplicationShutdown, OnModuleInit } from '@nestjs/common';
import { HttpAdapterHost } from '@nestjs/core';
import { randomUUID } from 'node:crypto';
import type { IncomingMessage, Server as HttpServer } from 'node:http';
import type { Duplex } from 'node:stream';
import { ZodError } from 'zod';
import { RawData, WebSocket, WebSocketServer } from 'ws';
import { MmoCoordinator, Peer } from '../../application/mmo-coordinator';
import { parseClientMessage, ServerMessage } from '../../domain/protocol';
import { JsonLineDecoder } from '../framing/json-line-decoder';
import { webSocketFrameToBuffer } from './websocket-frame';

const DEFAULT_PATH = '/ws';

@Injectable()
export class WebSocketGameServer implements OnModuleInit, OnApplicationShutdown {
  private readonly logger = new Logger(WebSocketGameServer.name);
  /** Shares the HTTP port; the only listener a PaaS or a tunnel can reach. */
  private mounted?: WebSocketServer;
  /** Optional second listener on a port of its own, for local development. */
  private standalone?: WebSocketServer;

  constructor(
    private readonly coordinator: MmoCoordinator,
    private readonly adapterHost: HttpAdapterHost,
  ) {}

  onModuleInit(): void {
    this.mount();
    this.listenStandalone();
  }

  /**
   * Upgrade `/ws` on the HTTP server Nest already owns. Hosts that publish a
   * single port -- Render, Railway, Fly, a Cloudflare tunnel -- can only ever
   * reach this one, so the shareable URL is always `wss://<host>/ws`.
   */
  private mount(): void {
    const http = this.adapterHost.httpAdapter?.getHttpServer() as HttpServer | undefined;
    if (!http || typeof http.on !== 'function') {
      this.logger.warn('No HTTP server available: the /ws endpoint is disabled');
      return;
    }
    const path = process.env.WS_PATH ?? DEFAULT_PATH;
    this.mounted = new WebSocketServer({ noServer: true, maxPayload: 64 * 1024 });
    this.mounted.on('connection', (socket) => this.accept(socket));

    http.on('upgrade', (request: IncomingMessage, socket: Duplex, head: Buffer) => {
      // The URL is request-relative, so a base is needed only to parse it.
      const requested = new URL(request.url ?? '/', 'http://localhost').pathname;
      if (requested !== path) {
        // Another handler may own this path; leaving the socket open would
        // hang the client, so refuse only what is clearly ours to refuse.
        socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
        socket.destroy();
        return;
      }
      this.mounted?.handleUpgrade(request, socket, head, (client) => {
        this.mounted?.emit('connection', client, request);
      });
    });
    this.logger.log(`Game WebSocket mounted on the HTTP port at ${path}`);
  }

  /**
   * Only when WS_PORT is set. web/serve.py proxies to it during development,
   * and the desktop tooling has always dialled 7779 directly. Unset in
   * production so a container publishes exactly one port.
   */
  private listenStandalone(): void {
    const configured = process.env.WS_PORT?.trim();
    if (!configured) return;
    const port = Number(configured);
    if (!Number.isInteger(port) || port <= 0 || port > 65535) {
      this.logger.error(`Ignoring WS_PORT="${configured}": not a valid port`);
      return;
    }
    const host = process.env.HOST ?? '0.0.0.0';
    this.standalone = new WebSocketServer({ port, host, maxPayload: 64 * 1024 });
    this.standalone.on('connection', (socket) => this.accept(socket));
    this.standalone.on('listening', () => this.logger.log(`Game WebSocket listening on ws://${host}:${port}`));
    this.standalone.on('error', (error) => this.logger.error(`WebSocket server error: ${error.message}`));
  }

  onApplicationShutdown(): void {
    for (const server of [this.mounted, this.standalone]) {
      for (const socket of server?.clients ?? []) socket.terminate();
      server?.close();
    }
  }

  private accept(socket: WebSocket): void {
    // Same framing as the TCP transport, and for the same reason: the browser
    // client is LOVE + LuaSocket running under Emscripten, whose SOCKFS turns
    // a TCP socket into a WebSocket. It forwards raw stream bytes as binary
    // frames, so frame boundaries carry no meaning -- a frame may hold two
    // messages or half of one. Newlines are the message boundary in both
    // directions, which is also why send() below terminates with '\n'.
    const decoder = new JsonLineDecoder();
    const peer: Peer = {
      connectionId: randomUUID(),
      send: (message: ServerMessage) => {
        if (socket.readyState === WebSocket.OPEN) socket.send(`${JSON.stringify(message)}\n`);
      },
      close: () => socket.close(1002, 'protocol_error'),
    };
    let disconnected = false;
    const disconnect = () => {
      if (disconnected) return;
      disconnected = true;
      this.coordinator.disconnect(peer);
    };

    socket.on('message', (frame: RawData) => {
      try {
        for (const value of decoder.push(webSocketFrameToBuffer(frame))) {
          this.coordinator.handle(peer, parseClientMessage(value));
        }
      } catch (error) {
        const code = error instanceof ZodError ? 'invalid_message' :
          error instanceof SyntaxError ? 'invalid_json' : 'protocol_error';
        peer.send({ type: 'error', code, message: code });
        if (code === 'protocol_error') peer.close();
      }
    });
    socket.on('error', (error) => this.logger.debug(`WebSocket error: ${error.message}`));
    socket.on('close', disconnect);
  }
}
