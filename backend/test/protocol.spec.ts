import { JsonLineDecoder } from '../src/modules/mmo/infrastructure/framing/json-line-decoder';
import { parseClientMessage } from '../src/modules/mmo/domain/protocol';

describe('newline-delimited JSON protocol', () => {
  it('decodes fragmented and batched frames', () => {
    const decoder = new JsonLineDecoder();
    expect(decoder.push('{"type":"ping",')).toEqual([]);
    const decoded = decoder.push('"nonce":7}\n{"type":"ping","nonce":8}\n');
    expect(decoded.map(parseClientMessage)).toEqual([
      { type: 'ping', nonce: 7 },
      { type: 'ping', nonce: 8 },
    ]);
  });

  it('rejects unknown fields and invalid names', () => {
    expect(() => parseClientMessage({
      type: 'join_world', name: '', mapId: 'PALLET_TOWN', x: 0, y: 0,
      facing: 'down', moving: false,
    })).toThrow();
    expect(() => parseClientMessage({ type: 'ping', unexpected: true })).toThrow();
  });

  it('protects the server from unbounded frames', () => {
    const decoder = new JsonLineDecoder(10);
    expect(() => decoder.push('this frame has no newline')).toThrow('message_too_large');
  });
});
