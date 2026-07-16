module executor

import json
import vjsx

struct InProcVjsxRuntimeEvent {}

fn InProcVjsxRuntimeEvent.normalize_kind(raw string) string {
	mut kind := raw.trim_space().replace(' ', '_')
	if kind == '' {
		return ''
	}
	if !kind.starts_with('vjsx.') {
		kind = 'vjsx.' + kind
	}
	return kind
}

fn InProcVjsxRuntimeEvent.fields_from_js_value(val vjsx.Value) map[string]string {
	if val.is_undefined() || val.is_null() {
		return map[string]string{}
	}
	raw := val.json_stringify()
	if raw.trim_space() == '' || raw.trim_space() == 'undefined' || raw.trim_space() == 'null' {
		return map[string]string{}
	}
	return json.decode(map[string]string, raw) or {
		map[string]string{}
	}
}
