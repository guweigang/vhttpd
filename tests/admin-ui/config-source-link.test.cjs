const test = require('node:test');
const assert = require('node:assert/strict');
require('../../admin/ui/config-source-link.js');
const {parse, resolve} = globalThis.ConfigSourceLink;
test('source links round trip unicode, spaces and delimiter characters', () => {
  const project = '/tmp/项目 & workspace/vhttpd.toml', source = '/tmp/项目 & workspace/relay #1.toml';
  const link = parse('#config-source?' + new URLSearchParams({project, source}));
  assert.deepEqual(link, {project, source});
  const file = {path: source, relay_ids: ['edge']};
  assert.equal(resolve(link, [{role:'main', path:project}, file]), file);
  assert.equal(parse('#unrelated'), null);
});
test('reject missing fields, control characters, foreign projects and detached sources', () => {
  assert.throws(() => parse('#config-source?source=x'));
  assert.throws(() => parse('#config-source?project=a&source=%00'));
  const files = [{role:'main', path:'/project/vhttpd.toml'}, {path:'/project/relay.toml'}];
  assert.throws(() => resolve({project:'/foreign/vhttpd.toml',source:'/project/relay.toml'},files));
  assert.throws(() => resolve({project:'/project/vhttpd.toml',source:'/etc/private.toml'},files));
});
