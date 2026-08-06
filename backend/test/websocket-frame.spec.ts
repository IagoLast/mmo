import { webSocketFrameToBuffer } from '../src/modules/mmo/infrastructure/websocket/websocket-frame';
import { JsonLineDecoder } from '../src/modules/mmo/infrastructure/framing/json-line-decoder';
import { parseClientMessage } from '../src/modules/mmo/domain/protocol';

describe('WebSocket frame handling', () => {
  it('normalises a Buffer frame', () => {
    const bytes = webSocketFrameToBuffer(Buffer.from('{"type":"ping","nonce":"web"}\n'));
    const [value] = new JsonLineDecoder().push(bytes);
    expect(parseClientMessage(value)).toEqual({ type: 'ping', nonce: 'web' });
  });

  it('normalises fragmented RawData represented as Buffer[]', () => {
    const bytes = webSocketFrameToBuffer([Buffer.from('{"type":"ping"'), Buffer.from(',"nonce":9}\n')]);
    const [value] = new JsonLineDecoder().push(bytes);
    expect(parseClientMessage(value)).toEqual({ type: 'ping', nonce: 9 });
  });

  it('normalises an ArrayBuffer frame, which is what the browser client sends', () => {
    // Emscripten's SOCKFS sets binaryType = "arraybuffer" and writes raw
    // stream bytes, so a browser player's frames arrive binary, not text.
    const source = Buffer.from('{"type":"ping","nonce":1}\n');
    const arrayBuffer = source.buffer.slice(source.byteOffset, source.byteOffset + source.byteLength);
    const [value] = new JsonLineDecoder().push(webSocketFrameToBuffer(arrayBuffer));
    expect(parseClientMessage(value)).toEqual({ type: 'ping', nonce: 1 });
  });
});

describe('WebSocket stream framing', () => {
  // Frame boundaries are meaningless on a TCP-over-WebSocket stream, so the
  // decoder -- not the frame -- decides where a message starts and ends.
  it('accepts several messages arriving in a single frame', () => {
    const decoder = new JsonLineDecoder();
    const values = decoder.push(
      webSocketFrameToBuffer(Buffer.from('{"type":"ping","nonce":1}\n{"type":"ping","nonce":2}\n')),
    );
    expect(values.map((value) => parseClientMessage(value))).toEqual([
      { type: 'ping', nonce: 1 },
      { type: 'ping', nonce: 2 },
    ]);
  });

  it('holds a message split across two frames until its newline arrives', () => {
    const decoder = new JsonLineDecoder();
    expect(decoder.push(webSocketFrameToBuffer(Buffer.from('{"type":"ping",')))).toEqual([]);
    const [value] = decoder.push(webSocketFrameToBuffer(Buffer.from('"nonce":7}\n')));
    expect(parseClientMessage(value)).toEqual({ type: 'ping', nonce: 7 });
  });
});
