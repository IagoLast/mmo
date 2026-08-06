import { Injectable } from '@nestjs/common';
import { randomBytes, randomUUID } from 'node:crypto';
import { ClientMessage, PublicPlayer, ServerMessage } from '../domain/protocol';

export interface Peer {
  readonly connectionId: string;
  send(message: ServerMessage): void;
  close(): void;
}

interface PlayerState extends PublicPlayer {
  peer: Peer;
  battleId?: string;
}

interface Challenge {
  id: string;
  fromId: string;
  toId: string;
}

interface Battle {
  id: string;
  playerIds: [string, string];
}

@Injectable()
export class MmoCoordinator {
  private readonly playersByConnection = new Map<string, PlayerState>();
  private readonly playersById = new Map<string, PlayerState>();
  private readonly challenges = new Map<string, Challenge>();
  private readonly battles = new Map<string, Battle>();

  handle(peer: Peer, message: ClientMessage): void {
    if (message.type === 'join_world') {
      this.onHello(peer, message);
      return;
    }

    const player = this.playersByConnection.get(peer.connectionId);
    if (!player) {
      this.error(peer, 'not_initialized', 'Send join_world before other messages');
      return;
    }

    switch (message.type) {
      case 'move': this.onMove(player, message); break;
      case 'challenge': this.onChallenge(player, message.targetId); break;
      case 'challenge_reply': this.onChallengeReply(player, message.challengeId, message.accept); break;
      case 'battle_message': this.onBattleMessage(player, message.battleId, message.payload); break;
      case 'battle_end': this.endBattle(player, message.battleId); break;
      case 'ping': peer.send({ type: 'pong', nonce: message.nonce }); break;
    }
  }

  disconnect(peer: Peer): void {
    const player = this.playersByConnection.get(peer.connectionId);
    if (!player) return;
    this.playersByConnection.delete(peer.connectionId);
    this.playersById.delete(player.id);
    this.removeChallengesFor(player.id);
    if (player.battleId) this.endBattle(player, player.battleId, 'opponent_disconnected');
    this.broadcastMap(player.mapId, { type: 'player_left', playerId: player.id }, player.id);
  }

  get playerCount(): number { return this.playersById.size; }

  private onHello(peer: Peer, message: Extract<ClientMessage, { type: 'join_world' }>): void {
    if (this.playersByConnection.has(peer.connectionId)) {
      this.error(peer, 'already_initialized', 'join_world can only be sent once');
      return;
    }
    const player: PlayerState = {
      id: randomUUID(), peer, name: message.name, mapId: message.mapId,
      x: message.x, y: message.y, px: message.px, py: message.py,
      facing: message.facing, moving: message.moving,
      ...(message.appearance ? { appearance: message.appearance } : {}),
    };
    const snapshot = [...this.playersById.values()]
      .filter((other) => other.mapId === player.mapId)
      .map((other) => this.publicPlayer(other));
    this.playersByConnection.set(peer.connectionId, player);
    this.playersById.set(player.id, player);
    peer.send({ type: 'welcome', playerId: player.id, player: this.publicPlayer(player) });
    peer.send({ type: 'snapshot', mapId: player.mapId, players: snapshot });
    peer.send({ type: 'world_snapshot', selfId: player.id, mapId: player.mapId, players: snapshot });
    this.broadcastMap(player.mapId, { type: 'player_joined', player: this.publicPlayer(player) }, player.id);
  }

  private onMove(player: PlayerState, message: Extract<ClientMessage, { type: 'move' }>): void {
    if (player.battleId) {
      this.error(player.peer, 'in_battle', 'Movement is disabled during a battle');
      return;
    }
    const oldMapId = player.mapId;
    player.mapId = message.mapId;
    player.x = message.x;
    player.y = message.y;
    player.px = message.px;
    player.py = message.py;
    player.facing = message.facing;
    player.moving = message.moving ?? false;
    if (oldMapId !== message.mapId) {
      this.broadcastMap(oldMapId, { type: 'player_left', playerId: player.id }, player.id);
      const snapshot = [...this.playersById.values()]
        .filter((other) => other.id !== player.id && other.mapId === player.mapId)
        .map((other) => this.publicPlayer(other));
      player.peer.send({ type: 'snapshot', mapId: player.mapId, players: snapshot });
      player.peer.send({ type: 'world_snapshot', selfId: player.id, mapId: player.mapId, players: snapshot });
      this.broadcastMap(player.mapId, { type: 'player_joined', player: this.publicPlayer(player) }, player.id);
      return;
    }
    this.broadcastMap(player.mapId, {
      type: 'player_moved', playerId: player.id, mapId: player.mapId,
      x: player.x, y: player.y, px: player.px, py: player.py, facing: player.facing,
      moving: message.moving ?? false, seq: message.seq,
    }, player.id);
  }

  private onChallenge(challenger: PlayerState, targetId: string): void {
    const target = this.playersById.get(targetId);
    if (!target || target.mapId !== challenger.mapId) {
      this.error(challenger.peer, 'target_unavailable', 'Player is not available on this map');
      return;
    }
    if (target.id === challenger.id || target.battleId || challenger.battleId) {
      this.error(challenger.peer, 'cannot_challenge', 'One of the players cannot be challenged');
      return;
    }
    const existing = [...this.challenges.values()].some((challenge) =>
      challenge.fromId === challenger.id || challenge.toId === challenger.id ||
      challenge.fromId === target.id || challenge.toId === target.id);
    if (existing) {
      this.error(challenger.peer, 'challenge_pending', 'One of the players already has a pending challenge');
      return;
    }
    const challenge: Challenge = { id: randomUUID(), fromId: challenger.id, toId: target.id };
    this.challenges.set(challenge.id, challenge);
    challenger.peer.send({ type: 'challenge_sent', challengeId: challenge.id, target: this.publicPlayer(target) });
    target.peer.send({ type: 'challenge_received', challengeId: challenge.id, from: { id: challenger.id, name: challenger.name } });
  }

  private onChallengeReply(target: PlayerState, challengeId: string, accept: boolean): void {
    const challenge = this.challenges.get(challengeId);
    if (!challenge || challenge.toId !== target.id) {
      this.error(target.peer, 'challenge_not_found', 'Challenge does not exist');
      return;
    }
    this.challenges.delete(challengeId);
    const challenger = this.playersById.get(challenge.fromId);
    if (!challenger || challenger.mapId !== target.mapId || challenger.battleId || target.battleId) {
      this.error(target.peer, 'challenger_unavailable', 'Challenger is no longer available');
      return;
    }
    if (!accept) {
      challenger.peer.send({ type: 'challenge_declined', challengeId, playerId: target.id });
      target.peer.send({ type: 'challenge_declined', challengeId, playerId: target.id });
      return;
    }
    const battle: Battle = { id: randomUUID(), playerIds: [challenger.id, target.id] };
    this.battles.set(battle.id, battle);
    challenger.battleId = battle.id;
    target.battleId = battle.id;
    const seed = randomBytes(4).readUInt32BE(0);
    challenger.peer.send({ type: 'battle_start', battleId: battle.id, opponent: this.publicPlayer(target), role: 'host', seed });
    target.peer.send({ type: 'battle_start', battleId: battle.id, opponent: this.publicPlayer(challenger), role: 'guest', seed });
  }

  private onBattleMessage(sender: PlayerState, battleId: string, payload: unknown): void {
    const battle = this.battles.get(battleId);
    if (!battle || sender.battleId !== battleId || !battle.playerIds.includes(sender.id)) {
      this.error(sender.peer, 'battle_not_found', 'Battle does not exist for this player');
      return;
    }
    const opponentId = battle.playerIds.find((id) => id !== sender.id)!;
    this.playersById.get(opponentId)?.peer.send({ type: 'battle_message', battleId, fromPlayerId: sender.id, payload });
  }

  private endBattle(sender: PlayerState, battleId: string, reason = 'ended'): void {
    const battle = this.battles.get(battleId);
    if (!battle || !battle.playerIds.includes(sender.id)) return;
    this.battles.delete(battleId);
    for (const playerId of battle.playerIds) {
      const player = this.playersById.get(playerId);
      if (player) {
        player.battleId = undefined;
        player.peer.send({ type: 'battle_ended', battleId, reason });
      }
    }
  }

  private removeChallengesFor(playerId: string): void {
    for (const [id, challenge] of this.challenges) {
      if (challenge.fromId === playerId || challenge.toId === playerId) {
        this.challenges.delete(id);
        const otherId = challenge.fromId === playerId ? challenge.toId : challenge.fromId;
        this.playersById.get(otherId)?.peer.send({ type: 'challenge_cancelled', challengeId: id });
      }
    }
  }

  private broadcastMap(mapId: string, message: ServerMessage, exceptId?: string): void {
    for (const player of this.playersById.values()) {
      if (player.mapId === mapId && player.id !== exceptId) player.peer.send(message);
    }
  }

  private publicPlayer(player: PlayerState): PublicPlayer {
    const { id, name, mapId, x, y, px, py, facing, moving, appearance } = player;
    return { id, name, mapId, x, y, px, py, facing, moving, ...(appearance ? { appearance } : {}) };
  }

  private error(peer: Peer, code: string, message: string): void {
    peer.send({ type: 'error', code, message });
  }
}
