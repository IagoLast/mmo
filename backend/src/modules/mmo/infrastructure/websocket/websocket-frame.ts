import type { RawData } from 'ws';

/**
 * Normalise anything `ws` hands to a 'message' listener into a Buffer.
 *
 * `ws` delivers a Buffer, an ArrayBuffer or an array of Buffer fragments
 * depending on how the frame arrived. Binary frames matter here: the browser
 * client is Emscripten's WebSocket-emulated TCP socket, which sets
 * binaryType = "arraybuffer" and sends raw stream bytes, so a browser player's
 * traffic is binary even though the payload is UTF-8 JSON.
 *
 * Parsing is deliberately not done here -- see JsonLineDecoder. A frame is a
 * slice of a byte stream, not necessarily one whole message.
 */
export function webSocketFrameToBuffer(frame: RawData | ArrayBuffer): Buffer {
  if (Array.isArray(frame)) return Buffer.concat(frame);
  if (Buffer.isBuffer(frame)) return frame;
  return Buffer.from(new Uint8Array(frame as ArrayBuffer));
}
