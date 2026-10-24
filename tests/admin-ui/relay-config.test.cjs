const test = require('node:test');
const assert = require('node:assert/strict');
require('../../admin/ui/relay-config.js');
const {inspect, update} = globalThis.RelayConfig;
const base = `version = 2
# Keep this comment
[listeners.web]
protocol = "http"
[listeners.relay]
protocol = "websocket"
[adapters.reply]
kind = "fixed-response"
options.body = """a multiline body
[relays.fake]
# not a real table
"""
[[pipelines]]
id = 'hello'
ingress = "listener:web"
match.paths = [
 "/relay", # keep array
]
egress = "adapter:reply"
`;
const relay = {id:'edge', mode:'agent', carrier:'websocket', url:'ws://127.0.0.1:9999/vhttpd/relay', node_id:'agent', token:'${env.TOKEN:-}', autostart:true, reconnect_delay_ms:1000,max_channels:1024,channel_buffer:64};
test('preserves unrelated multiline TOML and binds ingress, then edits agent to hub', () => {
  const agent = update(base, relay, {pipeline:'hello',direction:'incoming',egress:'adapter:reply'});
  assert(agent.includes(base.slice(0, base.indexOf('[[pipelines]]'))));
  assert(agent.includes('match.paths = [\n "/relay", # keep array\n]'));
  assert.equal(inspect(agent).relays.length,1);
  assert.equal(inspect(agent).pipelines[0].ingress,'relay:edge');
  const hub = update(agent,{...relay,mode:'hub',listener:'listener:relay',path:'/vhttpd/relay'});
  assert(!hub.includes('url ='));
  assert(!hub.includes('autostart ='));
  assert.equal(inspect(hub).relays[0].mode,'hub');
});
test('outbound binding preserves ingress and routes through relay-delivery', () => {
  const next = update(base, relay,{pipeline:'hello',direction:'outgoing',route:'relay/remote'});
  assert.equal(inspect(next).pipelines[0].ingress,'listener:web');
  assert.equal(inspect(next).pipelines[0].egress,'adapter:relay-ui-edge-68656c6c6f');
  assert(next.includes('options.route = "relay/remote"'));
  assert.equal(update(next,relay,{pipeline:'hello',direction:'outgoing',route:'relay/new'}).match(/\["adapters"\."relay-ui-edge-68656c6c6f"\]/g).length,1);
});
test('rejects invalid fields, unsupported layouts and conflicting adapter IDs', () => {
  assert.throws(() => update(base,{...relay,url:'https://example.com'}),/ws\/wss/);
  assert.throws(() => update(base,{...relay,url:''}),/有效/);
  assert.throws(() => update(base,{...relay,channel_buffer:0}),/channel_buffer/);
  assert.throws(() => update(base,{...relay,id:'bad.id'}),/Relay ID/);
  assert.throws(() => update(base+'\n[relays.edge.options]\na = "b"\n',relay),/嵌套表/);
  assert.throws(() => update(base+'\n[adapters.relay-ui-edge-68656c6c6f]\nkind="fixed-response"\n',relay,{pipeline:'hello',direction:'outgoing',route:'remote'}),/占用/);
});
test('quoted IDs, comments, escapes, and nested untouched fields survive editing', () => {
  const original = base + '\n[relays."edge"] # header\nmode="agent" # role\nurl="ws://localhost/x"\nnode_id="a"\ntoken=\'secret#value\'\n[relays.edge.options]\ncustom="x"\n';
  const next = update(original, {...relay, token:'quote" slash\\ newline\n'});
  assert.equal(inspect(next).relays[0].token,'quote" slash\\ newline\n');
  assert(next.includes('[relays.edge.options]\ncustom="x"'));
  assert(next.includes('# role'));
});
test('multiple pipelines keep separate outbound routes and unrelated include directives', () => {
  const original = base.replace('version = 2', 'version = 2\ninclude = ["./extra.toml"]') + '\n[[pipelines]]\nid="another"\ningress="listener:web"\negress="adapter:reply"\n';
  let text = update(original, relay, {pipeline:'hello',direction:'outgoing',route:'remote/one'});
  text = update(text, relay, {pipeline:'another',direction:'outgoing',route:'remote/two'});
  assert(text.includes('include = ["./extra.toml"]'));
  const pipelines=inspect(text).pipelines;
  assert.notEqual(pipelines[0].egress,pipelines[1].egress);
  assert(text.includes('options.route = "remote/one"'));
  assert(text.includes('options.route = "remote/two"'));
});
test('preserves indented comments and supports an empty final relay table', () => {
  const text=update(base+'\n[relays.edge]\n  mode = "agent" # role\nurl="ws://localhost"\n',relay);
  assert(text.includes('mode = "agent" # role'));
  assert.equal(inspect(update(base+'\n[relays.edge]',relay)).relays[0].node_id,'agent');
});
test('versionless include fragments retain their shape and accept outbound bindings', () => {
  const fragment='[relays.edge]\nmode="agent"\nurl="ws://localhost"\nnode_id="before"\n[[pipelines]]\nid="remote"\ningress="listener:web"\negress="adapter:reply"\n';
  assert.throws(()=>inspect(fragment),/version/);
  assert.equal(inspect(fragment,{fragment:true}).relays[0].id,'edge');
  const changed=update(fragment,relay,{pipeline:'remote',direction:'outgoing',route:'remote/reply'},{fragment:true});
  assert(!changed.includes('version ='));
  assert.equal(inspect(changed,{fragment:true}).relays[0].node_id,'agent');
  assert.equal(inspect(changed,{fragment:true}).pipelines[0].ingress,'listener:web');
});
test('cross-file bindings update only their original Relay and Pipeline sources', () => {
  const relayText='[relays.edge]\nmode="agent"\nurl="ws://localhost"\nnode_id="before"\n';
  const pipelineText='[[pipelines]]\nid="remote"\ningress="listener:web"\nmatch.paths=["/relay"]\negress="adapter:reply"\n';
  const workspace={files:[{source:{path:'relay.toml',role:'include'},value:relayText},{source:{path:'routes.toml',role:'include'},value:pipelineText},{source:{path:'main.toml',role:'main'},value:'version=2\n'}],
    pipelines:[{id:'remote',source_path:'routes.toml',ingress:'listener:web',egress:'adapter:reply'}],adapters:[{id:'reply',source_path:'main.toml',kind:'fixed-response',target:'',route:''}]};
  const incoming=RelayConfig.projectEdit(workspace,'relay.toml',relay,{pipeline:'remote',direction:'incoming',egress:'adapter:reply'});
  assert.deepEqual(incoming.changes.map(f=>f.path),['relay.toml','routes.toml']);
  assert(!incoming.changes[1].value.includes('[relays'));
  assert.equal(inspect(incoming.changes[1].value,{fragment:true}).pipelines[0].ingress,'relay:edge');
  const outgoing=RelayConfig.projectEdit(workspace,'relay.toml',relay,{pipeline:'remote',direction:'outgoing',route:'remote/handler'});
  assert(outgoing.changes[1].value.includes('options.route = "remote/handler"'));
  assert(outgoing.changes[1].value.includes('match.paths=["/relay"]'));
  assert.equal(outgoing.adapters.at(-1).source_path,'routes.toml');
  assert.equal(workspace.files[1].value,pipelineText);
});
test('managed Adapter in a third include is edited in place, shared ones are forked', () => {
  const id='relay-ui-edge-72656d6f7465';
  const workspace={files:[{source:{path:'relay.toml',role:'include'},value:'[relays.edge]\nmode="agent"\nurl="ws://localhost"\nnode_id="before"\n'},
    {source:{path:'routes.toml',role:'include'},value:'[[pipelines]]\nid="remote"\ningress="listener:web"\negress="adapter:'+id+'"\n'},
    {source:{path:'adapters.toml',role:'include'},value:'[adapters.'+id+']\nkind="relay-delivery"\noptions.target="relay:edge"\noptions.route="old"\n'}],
    pipelines:[{id:'remote',source_path:'routes.toml',ingress:'listener:web',egress:'adapter:'+id}],
    adapters:[{id,source_path:'adapters.toml',kind:'relay-delivery',target:'relay:edge',route:'old'}]};
  const edit=RelayConfig.projectEdit(workspace,'relay.toml',relay,{pipeline:'remote',direction:'outgoing',route:'new'});
  assert(edit.changes.find(f=>f.path==='adapters.toml').value.includes('options.route = "new"'));
  assert(!edit.changes.find(f=>f.path==='routes.toml')?.value.includes('["adapters"'));
  workspace.pipelines.push({id:'other',source_path:'routes.toml',ingress:'listener:web',egress:'adapter:'+id});
  const fork=RelayConfig.projectEdit(workspace,'relay.toml',relay,{pipeline:'remote',direction:'outgoing',route:'only-one'});
  assert.equal(fork.pipelines[1].egress,'adapter:'+id);
  assert.notEqual(fork.pipelines[0].egress,'adapter:'+id);
  assert(!fork.changes.some(f=>f.path==='adapters.toml'));
});
