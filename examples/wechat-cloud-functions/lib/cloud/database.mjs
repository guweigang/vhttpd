import {randomUUID} from 'node:crypto';
import {CloudError, invalid, unsupported, record, name, jsonValue, encode} from './errors.mjs';

const operations = new WeakMap();
class Command {
  constructor(kind, value) { operations.set(this, {kind, value}); Object.freeze(this); }
  and(other) { return new Command('and', [this, other]); }
  or(other) { return new Command('or', [this, other]); }
}
const commands = {};
for (const kind of ['eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'in', 'nin', 'exists', 'inc', 'mul', 'set', 'remove']) {
  commands[kind] = value => new Command(kind, value);
}
for (const kind of ['and', 'or']) commands[kind] = (...values) => new Command(kind, Array.isArray(values[0]) ? values[0] : values);
export const command = Object.freeze(commands);

function fieldPath(value) {
  if (typeof value !== 'string' || value.length > 256) invalid('invalid field path');
  const parts = value.split('.');
  if (parts.length > 16 || parts.some(part => !/^[A-Za-z_][A-Za-z0-9_]*$/.test(part)
    || ['__proto__', 'constructor', 'prototype'].includes(part))) invalid('invalid field path');
  return parts;
}

class SQL {
  constructor(driver = 'pgsql') { this.params = []; this.driver = driver; }
  bind(value) { this.params.push(String(value)); return '$' + this.params.length; }
  path(parts) { return this.bind('{' + parts.join(',') + '}') + '::text[]'; }
  field(key) {
    const parts = fieldPath(key);
    return this.driver === 'mysql' ? 'JSON_EXTRACT(body, ' + this.bind('$.' + parts.join('.')) + ')'
      : '(body #> ' + this.path(parts) + ')';
  }
  json(value) { const parameter = this.bind(encode(value)); return this.driver === 'mysql' ? 'CAST(' + parameter + ' AS JSON)' : parameter + '::jsonb'; }
  condition(value, field, depth = 0) {
    if (depth > 32) invalid('query nesting exceeds 32');
    const operation = value && typeof value === 'object' ? operations.get(value) : undefined;
    if (!operation) {
      if (field) return field + ' = ' + this.json(value);
      if (!record(value)) invalid('where requires an object or logical command');
      const clauses = Object.entries(value).map(([key, item]) => this.condition(item, this.field(key), depth + 1));
      return clauses.length ? '(' + clauses.join(' AND ') + ')' : 'TRUE';
    }
    const {kind, value: operand} = operation;
    if (kind === 'and' || kind === 'or') {
      if (!Array.isArray(operand) || !operand.length || operand.length > 100) invalid('logical command requires 1..100 conditions');
      return '(' + operand.map(item => this.condition(item, field, depth + 1)).join(kind === 'and' ? ' AND ' : ' OR ') + ')';
    }
    if (!field) invalid('field command requires a field');
    if (kind === 'exists') {
      if (typeof operand !== 'boolean') invalid('exists requires boolean');
      return field + (operand ? ' IS NOT NULL' : ' IS NULL');
    }
    if (kind === 'in' || kind === 'nin') {
      if (!Array.isArray(operand) || operand.length > 100) invalid('in/nin requires at most 100 values');
      if (!operand.length) return kind === 'in' ? 'FALSE' : 'TRUE';
      const match = field + ' IN (' + operand.map(item => this.json(item)).join(',') + ')';
      return kind === 'in' ? match : '(' + field + ' IS NULL OR NOT (' + match + '))';
    }
    const operator = {eq: '=', neq: '<>', gt: '>', gte: '>=', lt: '<', lte: '<='}[kind];
    if (!operator) invalid('update command used in query');
    const match = field + ' ' + operator + ' ' + this.json(operand);
    if (kind === 'neq') return '(' + field + ' IS NULL OR ' + match + ')';
    if (!['eq', 'neq'].includes(kind)) {
      if (!['string', 'number'].includes(typeof operand)) invalid('comparison requires string or number');
      // PostgreSQL JSONB has cross-type ordering; cloud comparisons must not.
      const typeCheck = this.driver === 'mysql'
        ? 'JSON_TYPE(' + field + ')' + (typeof operand === 'number' ? " IN ('INTEGER','DOUBLE','DECIMAL')" : " = 'STRING'")
        : 'jsonb_typeof(' + field + ') = ' + this.bind(typeof operand);
      return '(' + typeCheck + ' AND ' + match + ')';
    }
    return match;
  }
  scope(scope, collection, id, conditions) {
    const clauses = ['app_id = ' + this.bind(scope.appId), 'env_id = ' + this.bind(scope.env),
      'collection_name = ' + this.bind(collection)];
    if (id !== undefined) clauses.push('doc_id = ' + this.bind(id));
    for (const condition of conditions) clauses.push(this.condition(condition));
    return clauses.join(' AND ');
  }
  patch(data) {
    if (!record(data) || !Object.keys(data).length) invalid('update requires nonempty data');
    const paths = Object.keys(data).map(key => fieldPath(key));
    for (let i = 0; i < paths.length; i++) {
      if (paths[i][0] === '_id') invalid('_id is immutable');
      for (let j = 0; j < i; j++) {
        if (paths[i].slice(0, paths[j].length).join('.') === paths[j].join('.')
          || paths[j].slice(0, paths[i].length).join('.') === paths[i].join('.')) invalid('overlapping update paths');
      }
    }
    const tree = new Map(), removed = [];
    for (const [key, value] of Object.entries(data)) {
      let node = tree;
      const parts = fieldPath(key);
      if (value && typeof value === 'object' && operations.get(value)?.kind === 'remove') {
        removed.push(parts);
        continue;
      }
      for (const part of parts.slice(0, -1)) {
        if (!node.has(part)) node.set(part, new Map());
        node = node.get(part);
      }
      node.set(parts[parts.length - 1], {value});
    }
    const build = (node, prefix) => {
      let expression = prefix.length ? "COALESCE(body #> " + this.path(prefix) + ", '{}'::jsonb)" : 'body';
      for (const parts of removed) {
        if (parts.slice(0, prefix.length).join('.') === prefix.join('.')) {
          expression = '(' + expression + ' #- ' + this.path(parts.slice(prefix.length)) + ')';
        }
      }
      for (const [key, child] of node) {
        const localPath = this.path([key]), parts = [...prefix, key];
        if (child instanceof Map) {
          expression = 'jsonb_set(' + expression + ', ' + localPath + ', ' + build(child, parts) + ', true)';
          continue;
        }
        const {value} = child;
        const op = value && typeof value === 'object' ? operations.get(value) : undefined;
        let next;
        if (op && ['inc', 'mul'].includes(op.kind)) {
          const target = this.path(parts);
          if (typeof op.value !== 'number' || !Number.isFinite(op.value)) invalid('arithmetic command requires finite number');
          // Cast through JSON text: strings/objects fail instead of being coerced.
          // Arithmetic stays atomic in one UPDATE.
          next = "to_jsonb((COALESCE(body #> " + target + ", '0'::jsonb)::text)::numeric "
            + (op.kind === 'inc' ? '+' : '*') + ' ' + this.bind(op.value) + '::numeric)';
        } else {
          if (op && op.kind !== 'set') invalid('query command used in update');
          next = this.bind(encode(op ? op.value : value)) + '::jsonb';
        }
        expression = 'jsonb_set(' + expression + ', ' + localPath + ', ' + next + ', true)';
      }
      return expression;
    };
    return build(tree, []);
  }
}

function bounded(value, min, max) {
  if (!Number.isSafeInteger(value) || value < min || value > max) invalid('invalid pagination');
  return value;
}
function optionsData(options) {
  if (!record(options) || !record(options.data)) invalid('expected {data: object}');
  for (const key of Object.keys(options)) if (key !== 'data') unsupported('write option ' + key);
  return options.data;
}

export function createDatabase(scope, {throwOnNotFound = true} = {}) {
  const driver = scope.driver || 'pgsql';
  const execute = (target, method, sql, builder) => {
    let params = builder.params;
    if (driver === 'mysql') {
      params = [];
      sql = sql.replace(/\$(\d+)/g, (_, index) => { params.push(builder.params[Number(index) - 1]); return '?'; });
    }
    return target[method](sql, params);
  };
  const run = async (sql, builder) => {
    const result = await execute(scope, 'query', sql, builder);
    return result.rows;
  };
  class Reference {
    constructor(collection, id, conditions = [], orders = [], max = 100, offset = 0) {
      Object.assign(this, {collectionName: collection, id, conditions, orders, max, offset});
    }
    where(condition) {
      if (this.id !== undefined || scope.inTransaction) unsupported('where in document/transaction');
      // Validate immediately; the expression is compiled again for execution.
      new SQL(driver).condition(condition);
      return new Reference(this.collectionName, this.id, [...this.conditions, condition], this.orders, this.max, this.offset);
    }
    orderBy(key, direction) {
      fieldPath(key);
      if (!['asc', 'desc'].includes(direction)) invalid('invalid order direction');
      return new Reference(this.collectionName, this.id, this.conditions, [...this.orders, [key, direction]], this.max, this.offset);
    }
    limit(max) { return new Reference(this.collectionName, this.id, this.conditions, this.orders, bounded(max, 1, 1000), this.offset); }
    skip(offset) { return new Reference(this.collectionName, this.id, this.conditions, this.orders, this.max, bounded(offset, 0, 100000)); }
    doc(id) {
      if (this.id !== undefined || this.conditions.length || this.orders.length || this.offset || this.max !== 100) invalid('doc must follow collection');
      return new Reference(this.collectionName, name(id, 'document id'));
    }
    async get() {
      if (scope.inTransaction && this.id === undefined) unsupported('collection query in transaction');
      const b = new SQL(driver), where = b.scope(scope, this.collectionName, this.id, this.conditions);
      const orders = this.orders.map(([key, direction]) => b.field(key) + ' ' + direction.toUpperCase());
      orders.push('doc_id ASC');
      const rows = await run((driver === 'mysql' ? 'SELECT CAST(body AS CHAR CHARACTER SET utf8mb4) AS document FROM wcf_documents WHERE ' : 'SELECT body::text AS document FROM wcf_documents WHERE ') + where
        + ' ORDER BY ' + orders.join(', ') + ' LIMIT ' + b.bind(this.id === undefined ? this.max : 1)
        + (driver === 'mysql' ? ' OFFSET ' : '::integer OFFSET ') + b.bind(this.offset)
        + (driver === 'mysql' ? (scope.inTransaction ? ' FOR UPDATE' : '') : '::integer'), b);
      const data = rows.map(row => JSON.parse(row.document));
      if (this.id !== undefined && !data.length && throwOnNotFound) throw new CloudError('DOCUMENT_NOT_FOUND');
      return {data: this.id === undefined ? data : (data[0] || null), errMsg: (this.id === undefined ? 'collection' : 'document') + '.get:ok'};
    }
    async count() {
      if (scope.inTransaction || this.id !== undefined) unsupported('document/transaction count');
      const b = new SQL(driver), where = b.scope(scope, this.collectionName, this.id, this.conditions);
      const rows = await run((driver === 'mysql' ? 'SELECT CAST(count(*) AS CHAR) AS total FROM wcf_documents WHERE ' : 'SELECT count(*)::text AS total FROM wcf_documents WHERE ') + where, b);
      return {total: Number(rows[0].total), errMsg: 'collection.count:ok'};
    }
    async add(options) {
      if (this.id !== undefined || this.conditions.length || this.orders.length || this.offset || this.max !== 100) invalid('add must follow collection');
      const data = optionsData(options), id = name(data._id === undefined ? randomUUID() : data._id, 'document id');
      const b = new SQL(driver);
      const values = [scope.appId, scope.env, this.collectionName, id, encode({...data, _id: id}, scope.documentLimitBytes)].map(value => b.bind(value));
      if (driver === 'mysql') {
        await execute(scope, 'execute', 'INSERT INTO wcf_documents (app_id,env_id,collection_name,doc_id,body) VALUES ('
          + values.slice(0, 4).join(',') + ',CAST(' + values[4] + ' AS JSON))', b);
        return {_id: id, errMsg: 'collection.add:ok'};
      }
      await run('INSERT INTO wcf_documents (app_id, env_id, collection_name, doc_id, body) VALUES ('
        + values.slice(0, 4).join(',') + ',' + values[4] + '::jsonb) RETURNING doc_id', b);
      return {_id: id, errMsg: 'collection.add:ok'};
    }
    async set(options) {
      if (this.id === undefined) invalid('set requires doc');
      const data = optionsData(options);
      if (Object.prototype.hasOwnProperty.call(data, '_id')) invalid('_id cannot be set');
      if (driver === 'mysql') return mysqlWrite(this, 'set', data);
      const b = new SQL(driver), values = [scope.appId, scope.env, this.collectionName, this.id, encode({...data, _id: this.id}, scope.documentLimitBytes)].map(value => b.bind(value));
      const rows = await run('INSERT INTO wcf_documents (app_id, env_id, collection_name, doc_id, body) VALUES ('
        + values.slice(0, 4).join(',') + ',' + values[4] + '::jsonb) ON CONFLICT (app_id, env_id, collection_name, doc_id)'
        + ' DO UPDATE SET body = EXCLUDED.body RETURNING (xmax = 0)::text AS created', b);
      const created = rows[0].created === 'true' || rows[0].created === 't';
      return {_id: this.id, stats: {created: created ? 1 : 0, updated: created ? 0 : 1}, errMsg: 'document.set:ok'};
    }
    async update(options) {
      this.checkMutation();
      const data = optionsData(options);
      if (driver === 'mysql') return mysqlWrite(this, 'update', data);
      const b = new SQL(driver), expression = b.patch(data);
      const where = b.scope(scope, this.collectionName, this.id, this.conditions);
      const rows = await run('WITH changed AS (UPDATE wcf_documents SET body = ' + expression + ' WHERE ' + where
        + ' RETURNING 1) SELECT count(*)::text AS affected FROM changed', b);
      return {stats: {updated: Number(rows[0].affected)}, errMsg: (this.id === undefined ? 'collection' : 'document') + '.update:ok'};
    }
    async remove(options = {}) {
      if (!record(options) || Object.keys(options).length) unsupported('remove options');
      this.checkMutation();
      if (driver === 'mysql') return mysqlWrite(this, 'remove');
      const b = new SQL(driver), where = b.scope(scope, this.collectionName, this.id, this.conditions);
      const rows = await run('WITH changed AS (DELETE FROM wcf_documents WHERE ' + where
        + ' RETURNING 1) SELECT count(*)::text AS affected FROM changed', b);
      return {stats: {removed: Number(rows[0].affected)}, errMsg: (this.id === undefined ? 'collection' : 'document') + '.remove:ok'};
    }
    checkMutation() {
      if (this.orders.length || this.offset || this.max !== 100) unsupported('pagination/order on mutations');
      if (scope.inTransaction && this.id === undefined) unsupported('collection mutation in transaction');
    }
    field() { unsupported('field'); }
    aggregate() { unsupported('aggregate'); }
    watch() { unsupported('watch'); }
  }
  // MySQL has no UPDATE/DELETE RETURNING. Lock matching documents and perform
  // validation + writes on the same native transaction/session. Counts include
  // matched no-op updates and do not depend on CLIENT_FOUND_ROWS flags.
  async function mysqlWrite(reference, action, data) {
    const work = async target => {
      const b = new SQL(driver), where = b.scope(scope, reference.collectionName, reference.id, reference.conditions);
      const found = await execute(target, 'query', 'SELECT CAST(body AS CHAR CHARACTER SET utf8mb4) AS document FROM wcf_documents WHERE '
        + where + ' ORDER BY doc_id FOR UPDATE', b);
      const documents = found.rows.map(row => JSON.parse(row.document));
      if (action === 'set') {
        const next = encode({...data, _id: reference.id}, scope.documentLimitBytes), write = new SQL(driver);
        const values = [scope.appId, scope.env, reference.collectionName, reference.id, next].map(value => write.bind(value));
        await execute(target, 'execute', 'INSERT INTO wcf_documents (app_id,env_id,collection_name,doc_id,body) VALUES ('
          + values.slice(0, 4).join(',') + ',CAST(' + values[4] + ' AS JSON)) ON DUPLICATE KEY UPDATE body=CAST('
          + values[4] + ' AS JSON)', write);
        return {_id: reference.id, stats: {created: documents.length ? 0 : 1, updated: documents.length ? 1 : 0}, errMsg: 'document.set:ok'};
      }
      // Validate even if the filter matches no documents.
      if (action === 'update') validatePatch(data);
      for (const document of documents) {
        const write = new SQL(driver);
        const body = action === 'update' ? write.bind(encode(applyPatch(document, data), scope.documentLimitBytes)) : '';
        const filter = write.scope(scope, reference.collectionName, document._id, []);
        await execute(target, 'execute', (action === 'update' ? 'UPDATE wcf_documents SET body=CAST(' + body + ' AS JSON)' : 'DELETE FROM wcf_documents')
          + ' WHERE ' + filter, write);
      }
      return {stats: {[action === 'update' ? 'updated' : 'removed']: documents.length},
        errMsg: (reference.id === undefined ? 'collection' : 'document') + '.' + action + ':ok'};
    };
    return scope.inTransaction ? work(scope) : scope.transaction(work);
  }
  const database = {
    command,
    collection: collection => new Reference(name(collection, 'collection name')),
    runTransaction: callback => {
      if (scope.inTransaction) unsupported('nested transaction');
      if (typeof callback !== 'function') invalid('transaction callback required');
      return scope.transaction(txScope => callback(createDatabase(txScope, {throwOnNotFound})));
    },
    startTransaction() { unsupported('startTransaction; use runTransaction'); },
    serverDate() { unsupported('serverDate'); },
    createCollection() { unsupported('createCollection; collections are implicit'); },
  };
  return Object.freeze(database);
}

function validatePatch(data) {
  if (!record(data) || !Object.keys(data).length) invalid('update requires nonempty data');
  const paths = Object.keys(data).map(fieldPath);
  for (let i = 0; i < paths.length; i++) {
    if (paths[i][0] === '_id') invalid('_id is immutable');
    for (let j = 0; j < i; j++) if (paths[i].slice(0, paths[j].length).join('.') === paths[j].join('.')
      || paths[j].slice(0, paths[i].length).join('.') === paths[i].join('.')) invalid('overlapping update paths');
  }
  for (const value of Object.values(data)) {
    const op = value && typeof value === 'object' ? operations.get(value) : undefined;
    if (!op) jsonValue(value);
    else if (['inc', 'mul'].includes(op.kind)) {
      if (typeof op.value !== 'number' || !Number.isFinite(op.value)) invalid('arithmetic command requires finite number');
    } else if (op.kind === 'set') jsonValue(op.value);
    else if (op.kind !== 'remove') invalid('query command used in update');
  }
}
function applyPatch(document, data) {
  for (const [key, value] of Object.entries(data)) {
    const parts = fieldPath(key), op = value && typeof value === 'object' ? operations.get(value) : undefined;
    let node = document, absent = false;
    for (const part of parts.slice(0, -1)) {
      if (!Object.prototype.hasOwnProperty.call(node, part)) {
        if (op?.kind === 'remove') { absent = true; break; }
        node[part] = {};
      }
      if (!record(node[part])) invalid('update parent must be an object');
      node = node[part];
    }
    if (absent) continue;
    const leaf = parts[parts.length - 1];
    if (op?.kind === 'remove') delete node[leaf];
    else if (op && ['inc', 'mul'].includes(op.kind)) {
      const previous = Object.prototype.hasOwnProperty.call(node, leaf) ? node[leaf] : 0;
      if (typeof previous !== 'number') invalid('arithmetic target must be a number');
      node[leaf] = jsonValue(op.kind === 'inc' ? previous + op.value : previous * op.value);
    } else node[leaf] = jsonValue(op ? op.value : value);
  }
  return document;
}
