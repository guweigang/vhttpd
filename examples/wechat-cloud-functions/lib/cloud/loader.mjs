import fs from './fs-compat.mjs';
import path from 'node:path';
import crypto from './crypto-compat.mjs';
import {CloudError, name, unsupported} from './errors.mjs';

const builtins = Object.freeze({fs, path, crypto,
  https: Object.freeze({request() { unsupported('https.request; use fetch'); }})});

// Trusted server code only. This loader provides invocation-local CommonJS
// identity binding, not a sandbox. No process/global environment is rewritten.
export function loadFunctions(directory, {environment = {}, include} = {}) {
  const root = path.resolve(directory);
  const scopedProcess = Object.freeze({...process, env: Object.freeze({...process.env, ...environment})});
  const entries = {};
  for (const folder of fs.readdirSync(root).sort()) {
    if (include && !include.includes(folder)) continue;
    if (folder.startsWith('.') || folder === 'node_modules') continue;
    if (!fs.statSync(path.join(root, folder)).isDirectory()) continue;
    name(folder, 'function name');
    const entry = path.join(root, folder, 'index.js');
    if (!fs.existsSync(entry)) throw new CloudError('INVALID_FUNCTION', folder + '/index.js is required');
    const compiled = new Map();
    function resolveFile(candidate, seen = new Set()) {
      if (seen.has(candidate)) throw new CloudError('MODULE_NOT_FOUND', 'circular package main');
      seen.add(candidate);
      for (const filename of [candidate, candidate + '.js', candidate + '.cjs', candidate + '.json']) {
        if (fs.existsSync(filename) && fs.statSync(filename).isFile()) return filename;
      }
      const pkg = path.join(candidate, 'package.json');
      if (fs.existsSync(pkg)) {
        const meta = JSON.parse(fs.readFileSync(pkg, 'utf8'));
        if (meta.type === 'module' || meta.exports) unsupported('ESM / package exports in cloud function dependencies');
        if (typeof meta.main === 'string') return resolveFile(path.resolve(candidate, meta.main), seen);
      }
      const index = path.join(candidate, 'index.js');
      if (fs.existsSync(index)) return index;
      throw new CloudError('MODULE_NOT_FOUND', 'Cannot resolve ' + candidate);
    }
    function resolve(specifier, parent) {
      if (typeof specifier !== 'string') throw new CloudError('MODULE_NOT_FOUND');
      if (specifier.startsWith('.') || path.isAbsolute(specifier)) return resolveFile(path.resolve(path.dirname(parent), specifier));
      if (!/^(@[A-Za-z0-9_.-]+\/)?[A-Za-z0-9_.-]+(\/[A-Za-z0-9_.-]+)*$/.test(specifier)) unsupported('module ' + specifier);
      let current = path.dirname(parent);
      for (;;) {
        const candidate = path.join(current, 'node_modules', specifier);
        if (fs.existsSync(candidate) || fs.existsSync(candidate + '.js')) return resolveFile(candidate);
        const next = path.dirname(current);
        if (next === current) break;
        current = next;
      }
      throw new CloudError('MODULE_NOT_FOUND', 'Cannot resolve ' + specifier);
    }
    entries[folder] = cloud => {
      const cache = new Map();
      const load = filename => {
        if (cache.has(filename)) return cache.get(filename).exports;
        const module = {exports: {}, filename, loaded: false};
        cache.set(filename, module); // CommonJS cycles see partial exports.
        try {
          const requireModule = specifier => {
            if (specifier === 'wx-server-sdk') return cloud;
            const builtin = specifier.startsWith('node:') ? specifier.slice(5) : specifier;
            if (Object.prototype.hasOwnProperty.call(builtins, builtin)) return builtins[builtin];
            return load(resolve(specifier, filename));
          };
          requireModule.resolve = specifier => resolve(specifier, filename);
          if (!compiled.has(filename)) {
            const source = fs.readFileSync(filename, 'utf8');
            compiled.set(filename, filename.endsWith('.json') ? {json: source}
              : {run: new Function('require', 'module', 'exports', '__filename', '__dirname', 'process',
                source.replace(/^#![^\n]*\n/, '') + '\n//# sourceURL=' + filename)});
          }
          const code = compiled.get(filename);
          if (code.run) code.run.call(module.exports, requireModule, module, module.exports, filename, path.dirname(filename), scopedProcess);
          else module.exports = JSON.parse(code.json);
          module.loaded = true;
          return module.exports;
        } catch (error) { cache.delete(filename); throw error; }
      };
      const exports = load(entry);
      if (typeof exports.main !== 'function') throw new CloudError('INVALID_FUNCTION', folder + ' must export main');
      return exports.main;
    };
  }
  return Object.freeze(entries);
}
