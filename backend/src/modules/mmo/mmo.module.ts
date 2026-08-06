import { Module } from '@nestjs/common';
import { MmoCoordinator } from './application/mmo-coordinator';
import { TcpGameServer } from './infrastructure/tcp/tcp-game.server';
import { WebSocketGameServer } from './infrastructure/websocket/websocket-game.server';

@Module({ providers: [MmoCoordinator, TcpGameServer, WebSocketGameServer], exports: [MmoCoordinator] })
export class MmoModule {}
