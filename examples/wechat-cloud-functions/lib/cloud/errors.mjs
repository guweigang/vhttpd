export class CloudError extends Error {
  constructor(code, message = code) {
    super(message);
    this.name = 'CloudError';
    this.code = code;
    this.errCode = code;
    this.errMsg = message;
  }
}

export function invalid(message) { throw new CloudError('INVALID_PARAM', message); }
export function unsupported(api) { throw new CloudError('NOT_SUPPORTED', api + ' is not supported'); }
export function record(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null);
}

export function name(value, kind = 'name') {
  const pattern = kind === 'function name' ? /^[A-Za-z][A-Za-z0-9_-]{0,63}$/ : /^[A-Za-z0-9_-]{1,128}$/;
  if (typeof value !== 'string' || !pattern.test(value)) invalid('invalid ' + kind);
  return value;
}

// Fail instead of silently losing unsupported BSON/JS values during JSON encoding.
export function jsonValue(value, depth = 0) {
  if (depth > 32) invalid('document nesting exceeds 32');
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return value;
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (Array.isArray(value)) return value.map(item => jsonValue(item, depth + 1));
  if (record(value)) {
    const result = {};
    for (const [key, item] of Object.entries(value)) {
      if (['__proto__', 'prototype', 'constructor'].includes(key) || key.startsWith('$')) invalid('invalid document key');
      Object.defineProperty(result, key, {value: jsonValue(item, depth + 1), enumerable: true});
    }
    return result;
  }
  invalid('only JSON document values are supported');
}

export function encode(value, maxBytes = 1048576) {
  const text = JSON.stringify(jsonValue(value));
  if (new TextEncoder().encode(text).length > maxBytes) invalid('JSON exceeds configured byte limit');
  return text;
}
