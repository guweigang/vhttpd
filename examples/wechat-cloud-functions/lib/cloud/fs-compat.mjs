import fs from 'node:fs';

const sources = new WeakMap();
const maximum = 64 * 1024 * 1024;
export function readStreamContent(stream, maxBytes) {
  const source = sources.get(stream);
  if (!source) return undefined;
  if (source.closed) throw Error('stream is closed');
  const stat = fs.statSync(source.filename);
  if (!stat.isFile()) throw Error('stream source must be a file');
  const end = Math.min(stat.size, source.end === undefined ? stat.size : source.end + 1);
  const length = Math.max(0, end - source.start);
  // The current vjsx fs API reads whole files. Bound the allocation, even for ranges.
  if (stat.size > maxBytes || length > maxBytes) throw Object.assign(Error('FILE_TOO_LARGE'), {code: 'FILE_TOO_LARGE'});
  const bytes = Buffer.from(fs.readFileSync(source.filename));
  if (bytes.length > maxBytes) throw Object.assign(Error('FILE_TOO_LARGE'), {code: 'FILE_TOO_LARGE'});
  return bytes.subarray(source.start, end);
}
function createReadStream(filename, options = {}) {
  if (typeof filename !== 'string' || !options || typeof options !== 'object') throw TypeError('invalid read stream');
  for (const key of Object.keys(options)) if (!['start', 'end', 'highWaterMark'].includes(key)) throw TypeError('unsupported read stream option: ' + key);
  const start = options.start ?? 0, end = options.end;
  if (!Number.isSafeInteger(start) || start < 0 || (end !== undefined && (!Number.isSafeInteger(end) || end < start))) throw RangeError('invalid read stream range');
  const source = {filename, start, end, closed: false};
  const stream = {
    destroy() { source.closed = true; return this; },
    async *[Symbol.asyncIterator]() {
      const data = readStreamContent(stream, maximum);
      try { yield data; } finally { source.closed = true; }
    },
  };
  sources.set(stream, source);
  return stream;
}
export default Object.freeze({...fs, createReadStream});
