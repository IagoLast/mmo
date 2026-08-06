/**
 * Newline-delimited JSON framing over a byte stream.
 *
 * Shared by both transports on purpose: the wire format is identical, and the
 * browser is the reason it has to be. A WebSocket looks message-oriented, but
 * the browser client reaches it through Emscripten's SOCKFS, which emulates a
 * TCP socket on top of a WebSocket -- it forwards whatever bytes the socket
 * write produced, so one frame may carry two messages, or half of one. Framing
 * therefore belongs to the stream, not to the frame, on both sides.
 */
export class JsonLineDecoder {
  private buffer = '';

  constructor(private readonly maxBufferBytes = 64 * 1024) {}

  push(chunk: Buffer | string): unknown[] {
    this.buffer += chunk.toString();
    if (Buffer.byteLength(this.buffer) > this.maxBufferBytes) {
      this.buffer = '';
      throw new Error('message_too_large');
    }
    const lines = this.buffer.split('\n');
    this.buffer = lines.pop() ?? '';
    return lines
      .map((line) => line.trim())
      .filter(Boolean)
      .map((line) => JSON.parse(line) as unknown);
  }
}
