import { Injectable, Logger, OnApplicationShutdown, OnModuleInit } from '@nestjs/common';
import { createServer, Server, Socket } from 'node:net';
import { randomUUID } from 'node:crypto';
import { ZodError } from 'zod';
import { MmoCoordinator, Peer } from '../../application/mmo-coordinator';
import { parseClientMessage, ServerMessage } from '../../domain/protocol';
import { JsonLineDecoder } from '../framing/json-line-decoder';

@Injectable()
export class TcpGameServer implements OnModuleInit, OnApplicationShutdown {
  private readonly logger = new Logger(TcpGameServer.name);
  private server?: Server;

  constructor(private readonly coordinator: MmoCoordinator) {}

  onModuleInit(): void {
    const port = Number(process.env.TCP_PORT ?? 7778);
    const host = process.env.HOST ?? '0.0.0.0';
    this.server = createServer((socket) => this.accept(socket));
    this.server.listen(port, host, () => this.logger.log(`Game TCP listening on ${host}:${port}`));
  }

  onApplicationShutdown(): void {
    this.server?.close();
  }

  private accept(socket: Socket): void {
    socket.setKeepAlive(true, 30_000);
    socket.setNoDelay(true);
    const decoder = new JsonLineDecoder();
    const peer: Peer = {
      connectionId: randomUUID(),
      send: (message: ServerMessage) => socket.write(`${JSON.stringify(message)}\n`),
      close: () => socket.destroy(),
    };
    let disconnected = false;
    const disconnect = () => {
      if (disconnected) return;
      disconnected = true;
      this.coordinator.disconnect(peer);
    };
    socket.on('data', (chunk) => {
      try {
        for (const value of decoder.push(chunk)) {
          this.coordinator.handle(peer, parseClientMessage(value));
        }
      } catch (error) {
        const code = error instanceof ZodError ? 'invalid_message' :
          error instanceof SyntaxError ? 'invalid_json' : 'protocol_error';
        peer.send({ type: 'error', code, message: code });
        if (code === 'protocol_error') peer.close();
      }
    });
    socket.on('error', (error) => this.logger.debug(`Socket error: ${error.message}`));
    socket.on('close', disconnect);
    socket.on('end', disconnect);
  }
}
