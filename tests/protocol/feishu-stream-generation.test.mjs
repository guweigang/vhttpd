import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
// The command module is JavaScript syntax; load its exact source on Node versions
// that do not recognize .mts without requiring a TypeScript loader.
const source = readFileSync(new URL('../../examples/codexbot-app-ts/lib/commands.mts', import.meta.url), 'utf8');
const { feishuText, feishuStreamAppendText, feishuStreamFinish, feishuSessionClear, feishuSessionBind, feishuUpdateText, feishuUpdateCard } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);

test('serialized stream commands retain the generation captured before identical-ID rebind', () => {
  const old = { streamId: 'same', streamGeneration: 'first' };
  const send = feishuText('chat', ' ', old);
  const append = JSON.stringify(feishuStreamAppendText(old, 'late'));
  const finish = JSON.stringify(feishuStreamFinish(old));
  const replacement = { streamId: 'same', streamGeneration: 'second' };
  assert.equal(send.metadata.stream_generation, 'first');
  assert.equal(JSON.parse(append).metadata.stream_generation, 'first');
  assert.equal(JSON.parse(finish).metadata.stream_generation, 'first');
  assert.equal(feishuStreamAppendText(replacement, 'current').metadata.stream_generation, 'second');
});

test('an ID alone never recovers current generation authority', () => {
  assert.equal(feishuStreamAppendText('same', 'late').metadata.stream_generation, '');
  assert.equal(feishuStreamFinish('same').metadata.stream_generation, '');
});

test('clear retains captured generation and cannot infer it from a reused ID', () => {
 const old = { streamId: 'same', streamGeneration: 'old' };
 const packet = JSON.stringify(feishuSessionClear(old));
 old.streamGeneration = 'new';
 assert.equal(JSON.parse(packet).metadata.stream_generation, 'old');
 assert.equal(feishuSessionClear(old).metadata.stream_generation, 'new');
 assert.equal(feishuSessionClear('same').metadata.stream_generation, '');
});


test('first creation packets retain their one-use capability and bind CAS separately', () => {
 const handle = {streamId: 'same', streamGeneration: 'server-issued', streamCreationToken: 'one-use'};
 const send = JSON.stringify(feishuText('chat', 'hello', handle));
 const bind = JSON.stringify(feishuSessionBind(handle, 'message'));
 handle.streamCreationToken = 'new-ticket';
 assert.equal(JSON.parse(send).metadata.creation_token, 'one-use');
 assert.equal(JSON.parse(bind).metadata.creation_token, 'one-use');
 assert.equal(JSON.parse(bind).metadata.creation_generation, 'server-issued');
 assert.equal(JSON.parse(bind).metadata.stream_generation, '');
 assert.equal(feishuSessionBind(handle, 'message', 'expected-owner').metadata.stream_generation, 'expected-owner');
 assert.equal(feishuText('chat', 'hello', 'same').metadata.creation_token, '');
});


test('ordinary whole-card updates retain captured generation through serialization and reject ID-only authority', () => {
 const handle = {streamId: 'same', streamGeneration: 'old'};
 const text = JSON.stringify(feishuUpdateText(handle, 'late text'));
 const card = JSON.stringify(feishuUpdateCard(handle, {elements: []}));
 handle.streamGeneration = 'replacement';
 assert.equal(JSON.parse(text).metadata.stream_generation, 'old');
 assert.equal(JSON.parse(card).metadata.stream_generation, 'old');
 assert.equal(feishuUpdateText(handle, 'current').metadata.stream_generation, 'replacement');
 assert.equal(feishuUpdateText('same', 'no authority').metadata.stream_generation, '');
});
