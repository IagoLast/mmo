import { MmoCoordinator, Peer } from '../src/modules/mmo/application/mmo-coordinator';
import { ClientMessage, ServerMessage } from '../src/modules/mmo/domain/protocol';

class FakePeer implements Peer {
  readonly messages: ServerMessage[] = [];
  closed = false;
  constructor(readonly connectionId: string) {}
  send(message: ServerMessage): void { this.messages.push(message); }
  close(): void { this.closed = true; }
  last(type: string): ServerMessage | undefined {
    return [...this.messages].reverse().find((message) => message.type === type);
  }
}

const join = (name: string): ClientMessage => ({
  type: 'join_world', name, mapId: 'PALLET_TOWN', x: 5, y: 6,
  px: 40, py: 48, facing: 'down', moving: false,
});

describe('MmoCoordinator', () => {
  let coordinator: MmoCoordinator;
  let red: FakePeer;
  let blue: FakePeer;

  beforeEach(() => {
    coordinator = new MmoCoordinator();
    red = new FakePeer('red-connection');
    blue = new FakePeer('blue-connection');
  });

  it('joins, sends a snapshot and broadcasts movement', () => {
    coordinator.handle(red, join('Red'));
    coordinator.handle(blue, join('Blue'));

    const redId = red.last('welcome')?.playerId as string;
    expect(blue.last('world_snapshot')?.players).toEqual([
      expect.objectContaining({ id: redId, name: 'Red', mapId: 'PALLET_TOWN' }),
    ]);
    expect(red.last('player_joined')?.player).toEqual(expect.objectContaining({ name: 'Blue' }));

    coordinator.handle(blue, {
      type: 'move', mapId: 'PALLET_TOWN', x: 6, y: 6, px: 48, py: 48,
      facing: 'right', moving: true, seq: 2,
    });
    expect(red.last('player_moved')).toEqual(expect.objectContaining({
      playerId: blue.last('welcome')?.playerId, px: 48, facing: 'right', seq: 2,
    }));
  });

  it('creates a battle with a shared seed and relays opaque messages', () => {
    coordinator.handle(red, join('Red'));
    coordinator.handle(blue, join('Blue'));
    const blueId = blue.last('welcome')?.playerId as string;

    coordinator.handle(red, { type: 'challenge', targetId: blueId });
    const challengeId = blue.last('challenge_received')?.challengeId as string;
    expect(blue.last('challenge_received')?.from).toEqual(expect.objectContaining({ name: 'Red' }));
    coordinator.handle(blue, { type: 'challenge_reply', challengeId, accept: true });

    const redStart = red.last('battle_start')!;
    const blueStart = blue.last('battle_start')!;
    expect(redStart.battleId).toBe(blueStart.battleId);
    expect(redStart.seed).toBe(blueStart.seed);
    expect(redStart.role).toBe('host');
    expect(blueStart.role).toBe('guest');

    const payload = { frame: 12, inputs: [1, 0, 1] };
    coordinator.handle(red, { type: 'battle_message', battleId: redStart.battleId as string, payload });
    expect(blue.last('battle_message')).toEqual(expect.objectContaining({ payload }));
  });

  it('notifies the map and battle opponent on disconnect', () => {
    coordinator.handle(red, join('Red'));
    coordinator.handle(blue, join('Blue'));
    const redId = red.last('welcome')?.playerId as string;
    const blueId = blue.last('welcome')?.playerId as string;
    coordinator.handle(red, { type: 'challenge', targetId: blueId });
    coordinator.handle(blue, {
      type: 'challenge_reply',
      challengeId: blue.last('challenge_received')?.challengeId as string,
      accept: true,
    });

    coordinator.disconnect(red);
    expect(blue.last('battle_ended')).toEqual(expect.objectContaining({ reason: 'opponent_disconnected' }));
    expect(blue.last('player_left')).toEqual(expect.objectContaining({ playerId: redId }));
    expect(coordinator.playerCount).toBe(1);
  });
});
