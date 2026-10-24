module host

import config
import crypto.hmac
import crypto.sha256
import json2
import net.urllib
import runtime_plan

struct SafeConfigValue {
	text string
	fingerprint string
	redacted bool
}

struct ConfigComponentFields {
	kind string
	id string
	source string
	values map[string]SafeConfigValue
}

pub struct ConfigFieldDiff {
pub:
	kind string
	component string
	field string
	before string
	after string
	change string
	source_before string
	source_after string
	redacted bool
}

fn sensitive_config_key(key string) bool {
	name := key.to_lower().replace('-', '').replace('_', '').replace('.', '')
	return ['token', 'secret', 'password', 'passwd', 'credential', 'authorization', 'apikey', 'accesskey', 'privatekey', 'cookie', 'sessionkey', 'passphrase'].any(name.contains(it))
}

fn collect_config_secrets(value json2.Any, protected bool, mut secrets []string) {
	match value {
		map[string]json2.Any {
			for key, child in value { collect_config_secrets(child, protected || sensitive_config_key(key), mut secrets) }
		}
		[]json2.Any { for child in value { collect_config_secrets(child, protected, mut secrets) } }
		else { if protected && value.str() != '' { secrets << value.str() } }
	}
}

fn scrub_config_value(text string, secrets []string) string {
	mut safe := text
	for secret in secrets {
		if secret == '' { continue }
		for form in [secret, urllib.query_escape(secret), urllib.path_escape(secret)] {
			if form != '' { safe = safe.replace(form, '[已脱敏]') }
		}
	}
	return safe
}

fn config_field_value(raw json2.Any, sensitive bool, salt string, secrets []string) SafeConfigValue {
	encoded := json2.encode(raw)
	mut safe := encoded
	mut redacted := sensitive
	if sensitive {
		safe = if raw.str() == '' { '空值（敏感字段）' } else { '[已脱敏]' }
	} else if raw is string {
		if raw.contains('://') {
			url := urllib.parse(raw) or {
				return SafeConfigValue{text: '[地址已脱敏]', fingerprint: hmac.new(salt.bytes(), encoded.bytes(), sha256.sum, 64).hex(), redacted: true}
			}
			mut address := '${url.scheme}://${url.host}${url.escaped_path()}'
			if url.raw_query != '' || url.force_query { address += '?[已脱敏]'; redacted = true }
			if url.fragment != '' { address += '#[已脱敏]'; redacted = true }
			if _ := url.user { redacted = true }
			safe = json2.encode(address)
		} else if raw.contains('?') || raw.contains('#') {
			safe = json2.encode(raw.all_before('?').all_before('#') + '[参数已脱敏]')
			redacted = true
		}
	}
	if !sensitive {
		if raw is []json2.Any {
			mut parts := []string{}
			for child in raw {
				value := config_field_value(child, false, salt, secrets)
				parts << value.text
				redacted = redacted || value.redacted
			}
			safe = '[' + parts.join(', ') + ']'
		}
	}
	clean := scrub_config_value(safe, secrets)
	return SafeConfigValue{text: clean, fingerprint: hmac.new(salt.bytes(), encoded.bytes(), sha256.sum, 64).hex(), redacted: redacted || clean != safe}
}

fn add_config_option_fields(mut values map[string]SafeConfigValue, prefix string, options runtime_plan.PlanOptions, salt string, secrets []string) {
	for key, value in options.strings {
		// Unknown string options may be credentials. Show only known routing/identity values.
		sensitive := sensitive_config_key(key) || key !in ['node_id', 'url', 'path', 'route', 'target', 'status']
		values['${prefix}.${key}'] = config_field_value(json2.Any(value), sensitive, salt, secrets)
	}
	for key, value in options.ints { values['${prefix}.${key}'] = config_field_value(json2.Any(value), sensitive_config_key(key), salt, secrets) }
	for key, value in options.bools { values['${prefix}.${key}'] = config_field_value(json2.Any(value), sensitive_config_key(key), salt, secrets) }
	for key, value in options.string_lists { values['${prefix}.${key}'] = config_field_value(json2.decode[json2.Any](json2.encode(value)) or { json2.Any('') }, true, salt, secrets) }
	for key, value in options.string_maps { values['${prefix}.${key}'] = config_field_value(json2.decode[json2.Any](json2.encode(value)) or { json2.Any('') }, true, salt, secrets) }
	for key, value in options.record_lists { values['${prefix}.${key}'] = config_field_value(json2.decode[json2.Any](json2.encode(value)) or { json2.Any('') }, true, salt, secrets) }
}

fn config_component_fields(path string, sources []ConfigRevision, salt string) ![]ConfigComponentFields {
	plan := config.load_runtime_plan_file(path)!
	return config_component_fields_for_plan(plan, sources, salt)
}

fn config_component_fields_for_plan(plan runtime_plan.RuntimePlan, sources []ConfigRevision, salt string) ![]ConfigComponentFields {
	path := plan.source.config_path
	mut secrets := []string{}
	collect_config_secrets(json2.decode[json2.Any](json2.encode(plan))!, false, mut secrets)
	mut result := []ConfigComponentFields{}
	mut relay_ids := plan.relays.keys()
	relay_ids.sort()
	for id in relay_ids {
		r := plan.relays[id]
		mut values := map[string]SafeConfigValue{}
		for key, value in {'mode': r.mode, 'carrier': r.carrier, 'ingress': if v := r.ingress { v.str() } else { '' }, 'auth': if v := r.auth { v.str() } else { '' }} {
			values[key] = config_field_value(json2.Any(value), false, salt, secrets)
		}
		add_config_option_fields(mut values, 'options', r.options, salt, secrets)
		owners := sources.filter(id in it.source.relay_ids)
		result << ConfigComponentFields{kind: 'Relay', id: id, source: if owners.len > 0 { owners[0].source.path } else { path }, values: values}
	}
	for p in plan.pipelines {
		mut values := map[string]SafeConfigValue{}
		for key, value in {'group': p.group, 'ingress': p.ingress.str(), 'egress': p.egress.str(), 'match.path_regexp': p.match.path_regexp} {
			values[key] = config_field_value(json2.Any(value), false, salt, secrets)
		}
		for key, value in {'match.methods': p.match.methods, 'match.hosts': p.match.hosts, 'match.paths': p.match.paths, 'match.path_regexps': p.match.path_regexps, 'transforms': p.transforms.map(it.str()), 'policies': p.policies.map(it.str())} {
			values[key] = config_field_value(json2.decode[json2.Any](json2.encode(value))!, false, salt, secrets)
		}
		for key, value in p.match.headers { values['match.headers.${key}'] = config_field_value(json2.Any(value), key.to_lower() !in ['content-type', 'accept', 'host'], salt, secrets) }
		for key, value in p.match.query { values['match.query.${key}'] = config_field_value(json2.decode[json2.Any](json2.encode(value))!, true, salt, secrets) }
		for key, value in p.match.metadata { values['match.metadata.${key}'] = config_field_value(json2.Any(value), true, salt, secrets) }
		if p.egress.domain == .adapter {
			if adapter := plan.adapters[p.egress.id] {
				values['egress.kind'] = config_field_value(json2.Any(adapter.kind), false, salt, secrets)
				add_config_option_fields(mut values, 'egress.options', adapter.options, salt, secrets)
			}
		}
		owners := sources.filter(p.id in it.source.pipeline_ids)
		result << ConfigComponentFields{kind: 'Pipeline', id: p.id, source: if owners.len > 0 { owners[0].source.path } else { path }, values: values}
	}
	return result
}

fn config_field_diffs(before []ConfigComponentFields, after []ConfigComponentFields) []ConfigFieldDiff {
	mut result := []ConfigFieldDiff{}
	mut components := before.clone()
	for next in after { if !before.any(it.kind == next.kind && it.id == next.id) { components << next } }
	for component in components {
		old := before.filter(it.kind == component.kind && it.id == component.id)
		next := after.filter(it.kind == component.kind && it.id == component.id)
		old_values := if old.len > 0 { old[0].values } else { map[string]SafeConfigValue{} }
		next_values := if next.len > 0 { next[0].values } else { map[string]SafeConfigValue{} }
		mut fields := old_values.keys()
		for key in next_values.keys() { if key !in fields { fields << key } }
		fields.sort()
		for field in fields {
			left := old_values[field] or { SafeConfigValue{} }
			right := next_values[field] or { SafeConfigValue{} }
			if left.fingerprint == right.fingerprint { continue }
			result << ConfigFieldDiff{kind: component.kind, component: component.id, field: field,
				before: if field in old_values { left.text } else { '未定义' }, after: if field in next_values { right.text } else { '未定义' },
				change: if field !in old_values { '新增' } else if field !in next_values { '移除' } else { '修改' },
				source_before: if old.len > 0 { old[0].source } else { '' }, source_after: if next.len > 0 { next[0].source } else { '' }, redacted: left.redacted || right.redacted}
		}
		if old.len > 0 && next.len > 0 && old[0].source != next[0].source {
			result << ConfigFieldDiff{kind: component.kind, component: component.id, field: '配置来源', before: old[0].source, after: next[0].source, change: '移动', source_before: old[0].source, source_after: next[0].source}
		}
	}
	return result
}
