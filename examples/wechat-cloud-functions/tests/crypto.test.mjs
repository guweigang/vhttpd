import test, {assert} from './support.mjs';
import crypto from '../lib/cloud/crypto-compat.mjs';

test('legacy SHA1 and HMAC-SHA256 match published vectors, including multi-block and long keys', () => {
  for (const [input, digest] of [
    ['', 'da39a3ee5e6b4b0d3255bfef95601890afd80709'],
    ['abc', 'a9993e364706816aba3e25717850c26c9cd0d89d'],
    ['abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq', '84983e441c3bd26ebaae4aa1f95129e5e54670f1'],
  ]) assert.equal(crypto.createHash('sha1').update(input).digest('hex'), digest);
  // RFC 4231 cases 1, 2 and 6.
  for (const [key, data, expected] of [
    [new Uint8Array(20).fill(0x0b), 'Hi There', 'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7'],
    ['Jefe', 'what do ya want for nothing?', '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843'],
    [new Uint8Array(131).fill(0xaa), 'Test Using Larger Than Block-Size Key - Hash Key First', '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54'],
  ]) assert.equal(crypto.createHmac('sha256', key).update(data).digest('hex'), expected);
  const digest = crypto.createHash('sha1').update('a').update('bc');
  assert.equal(digest.digest('hex'), 'a9993e364706816aba3e25717850c26c9cd0d89d');
  assert.throws(() => digest.update('d'));
});

test('legacy crypto uses CSPRNG bytes and compares complete equal-length buffers', () => {
  const first = crypto.randomBytes(70000), second = crypto.randomBytes(70000);
  assert.equal(first.length, 70000);
  assert.ok(!crypto.timingSafeEqual(first, second));
  assert.ok(crypto.timingSafeEqual(first, first));
  assert.throws(() => crypto.timingSafeEqual(first, new Uint8Array(1)));
  assert.throws(() => crypto.randomBytes(-1));
});
