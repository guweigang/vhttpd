/* A lossless editor for the scalar TOML fields used by Relay forms.
 * The server remains the TOML parser and runtime-plan validator. Complex values
 * are left untouched; unsupported editable layouts fail closed. */
(function (root) {
  function statements(text) {
    const out = [];
    let start = 0, quote = '', triple = false, depth = 0, comment = false;
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (comment) { if (c !== '\n') continue; comment = false; }
      else if (quote) {
        if (quote === '"' && c === '\\') { i++; continue; }
        if (triple && text.slice(i, i + 3) === quote.repeat(3)) { i += 2; quote = ''; triple = false; }
        else if (!triple && c === quote) quote = '';
        continue;
      } else if (c === '#' ) { comment = true; continue; }
      else if (c === '"' || c === "'") {
        quote = c; triple = text.slice(i, i + 3) === c.repeat(3);
        if (triple) i += 2;
        continue;
      } else if (c === '[' || c === '{') depth++;
      else if (c === ']' || c === '}') depth--;
      if (c === '\n' && depth === 0) { out.push({start, end: i + 1, text: text.slice(start, i + 1)}); start = i + 1; }
      if (depth < 0) throw new Error('TOML 括号不匹配，请使用源码编辑器修复。');
    }
    if (quote || depth) throw new Error('TOML 字符串或数组未闭合。');
    if (start < text.length) out.push({start, end: text.length, text: text.slice(start)});
    return out;
  }
  function keyParts(key) {
    const parts = key.trim().match(/"(?:\\.|[^"\\])*"|'[^']*'|[A-Za-z0-9_-]+|\./g) || [];
    if (parts.join('') !== key.replace(/\s+(?=(?:[^"']*["'][^"']*["'])*[^"']*$)/g, '')) {
      // Only ordinary and quoted dotted keys are editable; never guess ranges.
      throw new Error('此 TOML 键需要使用源码编辑器：' + key);
    }
    const result = [];
    for (let i = 0; i < parts.length; i++) {
      if (i % 2 ? parts[i] !== '.' : parts[i] === '.') throw new Error('无效 TOML 键');
      if (!(i % 2)) result.push(parts[i][0] === '"' ? JSON.parse(parts[i]) : parts[i][0] === "'" ? parts[i].slice(1, -1) : parts[i]);
    }
    return result;
  }
  function scalar(value) {
    value = value.trim();
    if (value.startsWith('"""') || value.startsWith("'''")) throw new Error('多行字段请使用源码编辑器。');
    if (value[0] === '"') return JSON.parse(value);
    if (value[0] === "'" && value.endsWith("'")) return value.slice(1, -1);
    if (value === 'true' || value === 'false') return value === 'true';
    if (/^[+-]?\d[\d_]*$/.test(value)) return Number(value.replaceAll('_', ''));
    throw new Error('此字段使用复杂 TOML 值，请使用源码编辑器。');
  }
  function withoutComment(text) {
    let q = '';
    for (let i = 0; i < text.length; i++) {
      if (q === '"' && text[i] === '\\') { i++; continue; }
      if (q) { if (text[i] === q) q = ''; }
      else if (text[i] === '"' || text[i] === "'") q = text[i];
      else if (text[i] === '#') return text.slice(0, i).trim();
    }
    return text.trim();
  }
  function parse(text) {
    const sections = [{path: [], array: false, start: 0, body: 0, end: text.length, entries: []}];
    let current = sections[0];
    for (const st of statements(text)) {
      const clean = withoutComment(st.text);
      if (!clean) continue;
      if (clean[0] === '[') {
        const array = clean.startsWith('[['), n = array ? 2 : 1;
        if (!clean.endsWith(']'.repeat(n))) throw new Error('无法识别 TOML 表头');
        current.end = st.start;
        current = {path: keyParts(clean.slice(n, -n)), array, start: st.start, body: st.end, end: text.length, entries: []};
        sections.push(current);
      } else {
        // Locate '=' outside a quoted key.
        let q = '', eq = -1;
        for (let i = 0; i < clean.length; i++) {
          if (q === '"' && clean[i] === '\\') { i++; continue; }
          if (q) { if (clean[i] === q) q = ''; }
          else if (clean[i] === '"' || clean[i] === "'") q = clean[i];
          else if (clean[i] === '=') { eq = i; break; }
        }
        if (eq < 0) throw new Error('无法识别 TOML 语句');
        current.entries.push({...st, key: keyParts(clean.slice(0, eq)), raw: clean.slice(eq + 1).trim()});
      }
    }
    return sections;
  }
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  function read(section, key, fallback = '') {
    const entry = section.entries.find(e => same(e.key, key.split('.')));
    return entry ? scalar(entry.raw) : fallback;
  }
  function inspect(text, {fragment = false} = {}) {
    const sections = parse(text);
    if (read(sections[0], 'version', fragment ? 2 : 1) !== 2) throw new Error('Relay 表单需要 version = 2 的项目配置。');
    const relays = sections.filter(s => s.path[0] === 'relays' && s.path.length === 2 && !s.array).map(s => ({
      id: s.path[1], mode: read(s, 'mode', 'hub'), carrier: read(s, 'carrier', 'websocket'),
      url: read(s, 'url'), listener: read(s, 'listener'), path: read(s, 'path', '/vhttpd/relay'),
      node_id: read(s, 'node_id', s.path[1]), token: read(s, 'token'), autostart: read(s, 'autostart', true),
      max_channels: read(s, 'max_channels', 1024), channel_buffer: read(s, 'channel_buffer', 64), reconnect_delay_ms: read(s, 'reconnect_delay_ms', 1000)
    }));
    const pipelines = sections.filter(s => same(s.path, ['pipelines']) && s.array).map(s => ({id: read(s, 'id'), ingress: read(s, 'ingress'), egress: read(s, 'egress')}));
    const listeners = sections.filter(s => s.path[0] === 'listeners' && s.path.length === 2).map(s => ({id: s.path[1], protocol: read(s, 'protocol')}));
    const adapters = sections.filter(s => s.path[0] === 'adapters' && s.path.length === 2).map(s => ({id: s.path[1], kind: read(s, 'kind')}));
    return {relays, pipelines, listeners, adapters};
  }
  function patch(text, path, arrayId, values) {
    const sections = parse(text);
    const candidates = sections.filter(s => same(s.path, path) && (arrayId == null ? !s.array : s.array && read(s, 'id') === arrayId));
    if (candidates.length > 1) throw new Error('TOML 有重复定义，请先修复。');
    const section = candidates[0];
    if (!section) {
      if (arrayId != null) throw new Error('Pipeline 不在当前配置文件中。');
      // Reject inline/dotted definitions and nested options that could conflict.
      if (sections.some(s => s.path.length > path.length && same(s.path.slice(0, path.length), path)) ||
          sections.some(s => s.entries.some(e => same([...s.path, ...e.key].slice(0, path.length), path)))) {
        throw new Error('此定义使用内联表或嵌套表，请使用源码编辑器。');
      }
      return text.trimEnd() + '\n\n[' + path.map(k => JSON.stringify(k)).join('.') + ']\n' +
        Object.entries(values).filter(([,v]) => v !== undefined).map(([k,v]) => k + ' = ' + JSON.stringify(v) + '\n').join('');
    }
    const edits = [], missing = [];
    for (const [key, value] of Object.entries(values)) {
      const parts = key.split('.');
      // Nested table assignments to the same field cannot be safely patched here.
      if (parts.length > 1 && sections.some(s => same(s.path, [...path, ...parts.slice(0, -1)]) && s !== section && s.entries.some(e => same(e.key, parts.slice(-1))))) {
        throw new Error('此字段位于嵌套表，请使用源码编辑器：' + key);
      }
      const entries = section.entries.filter(e => same(e.key, parts));
      if (entries.length > 1) throw new Error('重复 TOML 字段：' + key);
      if (entries[0]) {
        const e = entries[0];
        // Keep inline comments. Untouched statements remain byte-for-byte intact.
        const body = withoutComment(e.text);
        const comment = e.text.slice(e.text.indexOf(body) + body.length).trim();
        edits.push({start: e.start, end: e.end, value: value === undefined ? '' : key + ' = ' + JSON.stringify(value) + (comment.startsWith('#') ? ' ' + comment : '') + '\n'});
      } else if (value !== undefined) missing.push(key + ' = ' + JSON.stringify(value) + '\n');
    }
    if (missing.length) edits.push({start: section.body, end: section.body, value: (section.body && text[section.body - 1] !== '\n' ? '\n' : '') + missing.join('')});
    edits.sort((a,b) => b.start - a.start || b.end - a.end);
    for (const edit of edits) text = text.slice(0, edit.start) + edit.value + text.slice(edit.end);
    return text;
  }
  function update(text, relay, binding, options = {}) {
    if (!/^[A-Za-z0-9_-]+$/.test(relay.id)) throw new Error('Relay ID 只能包含字母、数字、下划线和连字符。');
    if (!['agent','hub'].includes(relay.mode)) throw new Error('请选择 agent 或 hub。');
    if (relay.carrier !== 'websocket') throw new Error('当前仅支持 websocket carrier。');
    if (!relay.node_id.trim()) throw new Error('请填写 Node ID。');
    for (const key of ['max_channels','channel_buffer','reconnect_delay_ms']) {
      if (!Number.isSafeInteger(relay[key]) || relay[key] < (key === 'reconnect_delay_ms' ? 0 : 1)) throw new Error('无效参数：' + key);
    }
    if (relay.mode === 'agent') {
      if (!relay.url.includes('${')) {
        let url; try { url = new URL(relay.url); } catch (_) { throw new Error('Agent 地址需要有效的 ws:// 或 wss:// URL。'); }
        if (!['ws:', 'wss:'].includes(url.protocol) || url.username || url.password || url.hash) throw new Error('Agent 地址应使用 ws/wss，凭证请填入 Token 字段。');
      }
    } else if (!/^listener:.+/.test(relay.listener) || !relay.path.startsWith('/')) throw new Error('Hub 需要 listener 引用和以 / 开始的路径。');
    const {id, ...fields} = relay;
    if (relay.mode === 'agent') { fields.listener = undefined; fields.path = undefined; }
    else { fields.url = undefined; fields.autostart = undefined; }
    let result = patch(text, ['relays', id], null, fields);
    if (binding && binding.pipeline) {
      if (binding.direction === 'incoming') {
        if (!/^adapter:.+/.test(binding.egress)) throw new Error('请选择 Relay 入站的出口 Adapter。');
        result = patch(result, ['pipelines'], binding.pipeline, {ingress: 'relay:' + id, egress: binding.egress});
      } else {
        if (!binding.route.trim()) throw new Error('请填写远端 Pipeline ID（route）。');
        const adapter = 'relay-ui-' + id + '-' + Array.from(new TextEncoder().encode(binding.pipeline), b => b.toString(16).padStart(2, '0')).join('');
        const model = inspect(result, options);
        if (model.adapters.some(a => a.id === adapter && a.kind !== 'relay-delivery')) throw new Error('Adapter ID 已被其他类型占用：' + adapter);
        result = patch(result, ['adapters', adapter], null, {kind: 'relay-delivery', 'options.target': 'relay:' + id,
          'options.route': binding.route, 'options.completion_mode': 'wait', 'options.frame_kind': 'open', 'int_options.completion_timeout_ms': 30000});
        result = patch(result, ['pipelines'], binding.pipeline, {egress: 'adapter:' + adapter});
      }
    }
    return result;
  }
  function projectEdit(workspace, relayPath, relay, binding) {
    const files = new Map(workspace.files.map(f => [f.source.path, {path:f.source.path, original:f.value, value:f.value, fragment:f.source.role !== 'main'}]));
    const source = path => {
      const file = files.get(path);
      if (!file) throw new Error('配置来源不在当前项目中：' + path);
      return file;
    };
    const owner = source(relayPath);
    owner.value = update(owner.value, relay, null, {fragment:owner.fragment});
    const pipelines = workspace.pipelines.map(p => ({...p}));
    const adapters = workspace.adapters.map(a => ({...a}));
    if (binding?.pipeline) {
      const pipeline = pipelines.find(p => p.id === binding.pipeline);
      if (!pipeline) throw new Error('Pipeline 不在当前项目中。');
      const destination = source(pipeline.source_path);
      if (binding.direction === 'incoming') {
        if (!/^adapter:.+/.test(binding.egress)) throw new Error('请选择 Relay 入站的出口 Adapter。');
        destination.value = patch(destination.value, ['pipelines'], pipeline.id, {ingress:'relay:' + relay.id, egress:binding.egress});
        pipeline.ingress = 'relay:' + relay.id;
        pipeline.egress = binding.egress;
      } else if (binding.direction === 'outgoing') {
        if (!binding.route.trim()) throw new Error('请填写远端 Pipeline ID（route）。');
        const base = 'relay-ui-' + relay.id + '-' + Array.from(new TextEncoder().encode(pipeline.id), b => b.toString(16).padStart(2, '0')).join('');
        let id = base, adapter = adapters.find(a => a.id === id);
        if (adapter && adapter.kind !== 'relay-delivery') throw new Error('Adapter ID 已被其他类型占用：' + id);
        // A manually shared adapter must not retarget other pipelines.
        if (adapter && pipelines.some(p => p.id !== pipeline.id && p.egress === 'adapter:' + id)) {
          let suffix = 2;
          do { id = base + '-' + suffix++; } while (adapters.some(a => a.id === id));
          adapter = null;
        }
        const adapterFile = source(adapter?.source_path || pipeline.source_path);
        adapterFile.value = patch(adapterFile.value, ['adapters', id], null, {kind:'relay-delivery', 'options.target':'relay:' + relay.id,
          'options.route':binding.route, 'options.completion_mode':'wait', 'options.frame_kind':'open', 'int_options.completion_timeout_ms':30000});
        destination.value = patch(destination.value, ['pipelines'], pipeline.id, {egress:'adapter:' + id});
        pipeline.egress = 'adapter:' + id;
        if (adapter) Object.assign(adapter, {target:'relay:' + relay.id, route:binding.route});
        else adapters.push({id, source_path:adapterFile.path, kind:'relay-delivery', target:'relay:' + relay.id, route:binding.route});
      } else throw new Error('请选择绑定方向。');
    }
    const changes = [...files.values()].filter(f => f.value !== f.original).map(({path, original, value}) => ({path, original, value}));
    return {changes, pipelines, adapters};
  }
  root.RelayConfig = {inspect, update, parse, read, patch, projectEdit};
})(globalThis);
