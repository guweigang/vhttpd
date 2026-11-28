import native from 'node:crypto';

// Compatibility for legacy cloud functions. SHA-256 uses vjsx's native digest;
// HMAC follows RFC 2104, with RFC 4231 vectors in the migration checks.
const bytes = (value, encoding) => typeof value === 'string' ? Buffer.from(value, encoding || 'utf8') : Buffer.from(value);
function concat(...parts) {
  const result = new Uint8Array(parts.reduce((size, part) => size + part.length, 0));
  let offset = 0;
  for (const part of parts) { result.set(part, offset); offset += part.length; }
  return result;
}
function sha1(input) {
  const data = new Uint8Array(Math.ceil((input.length + 9) / 64) * 64);
  data.set(input); data[input.length] = 128;
  const view = new DataView(data.buffer);
  view.setUint32(data.length - 8, Math.floor(input.length / 0x20000000));
  view.setUint32(data.length - 4, (input.length * 8) >>> 0);
  let a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476, e0 = 0xc3d2e1f0;
  const rotate = (value, n) => ((value << n) | (value >>> (32 - n))) >>> 0;
  for (let block = 0; block < data.length; block += 64) {
    const w = new Uint32Array(80);
    for (let i = 0; i < 16; i++) w[i] = view.getUint32(block + i * 4);
    for (let i = 16; i < 80; i++) w[i] = rotate(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    let a = a0, b = b0, c = c0, d = d0, e = e0;
    for (let i = 0; i < 80; i++) {
      const f = i < 20 ? (b & c) | (~b & d) : i < 40 ? b ^ c ^ d : i < 60 ? (b & c) | (b & d) | (c & d) : b ^ c ^ d;
      const k = i < 20 ? 0x5a827999 : i < 40 ? 0x6ed9eba1 : i < 60 ? 0x8f1bbcdc : 0xca62c1d6;
      const next = (rotate(a, 5) + f + e + k + w[i]) >>> 0;
      e = d; d = c; c = rotate(b, 30); b = a; a = next;
    }
    a0 = (a0 + a) >>> 0; b0 = (b0 + b) >>> 0; c0 = (c0 + c) >>> 0; d0 = (d0 + d) >>> 0; e0 = (e0 + e) >>> 0;
  }
  const output = new Uint8Array(20), out = new DataView(output.buffer);
  [a0, b0, c0, d0, e0].forEach((value, index) => out.setUint32(index * 4, value));
  return Buffer.from(output);
}
function createHash(algorithm) {
  if (!['sha1', 'sha-1'].includes(String(algorithm).toLowerCase())) return native.createHash(algorithm);
  const parts = []; let done = false;
  return {
    update(value, encoding) { if (done) throw Error('Digest already called'); parts.push(bytes(value, encoding)); return this; },
    digest(encoding) { if (done) throw Error('Digest already called'); done = true; const result = sha1(concat(...parts)); return encoding ? result.toString(encoding) : result; },
  };
}
function createHmac(algorithm, key) {
  if (!['sha256', 'sha-256'].includes(String(algorithm).toLowerCase())) throw Error('Only HMAC-SHA256 is supported');
  let normalized = bytes(key);
  if (normalized.length > 64) normalized = native.createHash('sha256').update(normalized).digest();
  const inner = new Uint8Array(64).fill(0x36), outer = new Uint8Array(64).fill(0x5c);
  for (let i = 0; i < normalized.length; i++) { inner[i] ^= normalized[i]; outer[i] ^= normalized[i]; }
  const parts = []; let done = false;
  return {
    update(value, encoding) { if (done) throw Error('Digest already called'); parts.push(bytes(value, encoding)); return this; },
    digest(encoding) {
      if (done) throw Error('Digest already called'); done = true;
      const first = native.createHash('sha256').update(concat(inner, ...parts)).digest();
      const result = native.createHash('sha256').update(concat(outer, first)).digest();
      return encoding ? result.toString(encoding) : result;
    },
  };
}
function randomBytes(size) {
  if (!Number.isSafeInteger(size) || size < 0 || size > 1048576) throw new RangeError('invalid random size');
  const result = new Uint8Array(size);
  // vjsx's native UUID uses the OS CSPRNG. Keep only its first six bytes,
  // before the UUID version/variant bits, so every returned bit is random.
  for (let offset = 0; offset < size; offset += 6) {
    const chunk = Buffer.from(native.randomUUID().replace(/-/g, '').slice(0, 12), 'hex');
    result.set(chunk.subarray(0, Math.min(6, size - offset)), offset);
  }
  return Buffer.from(result);
}
function timingSafeEqual(left, right) {
  const a = bytes(left), b = bytes(right);
  if (a.length !== b.length) throw new RangeError('Input buffers must have the same byte length');
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a[i] ^ b[i];
  return difference === 0;
}
export default Object.freeze({...native, createHash, createHmac, randomBytes, timingSafeEqual});
