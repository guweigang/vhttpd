module config

// CLI argument parsing helpers used across vhttpd.

pub struct CliArgs {}

pub fn CliArgs.get(args []string, key string, default_val string) string {
	for i, a in args {
		if a == key && i + 1 < args.len {
			return args[i + 1]
		}
		prefix := '${key}='
		if a.starts_with(prefix) {
			return a.all_after(prefix)
		}
	}
	return default_val
}

pub fn CliArgs.has(args []string, key string) bool {
	for a in args {
		if a == key || a.starts_with('${key}=') {
			return true
		}
	}
	return false
}

pub fn CliArgs.string_or(args []string, key string, default_val string) string {
	if !CliArgs.has(args, key) {
		return default_val
	}
	return CliArgs.get(args, key, default_val)
}

pub fn CliArgs.int_or(args []string, key string, default_val int) int {
	if !CliArgs.has(args, key) {
		return default_val
	}
	raw := CliArgs.get(args, key, '${default_val}')
	return raw.int()
}

pub fn CliArgs.parse_boolish(raw string) bool {
	return raw.trim_space().to_lower() in ['1', 'true', 'yes', 'on']
}

pub fn CliArgs.bool_or(args []string, key string, default_val bool) bool {
	for i, a in args {
		if a == key {
			if i + 1 < args.len && !args[i + 1].starts_with('--') {
				return CliArgs.parse_boolish(args[i + 1])
			}
			return true
		}
		prefix := '${key}='
		if a.starts_with(prefix) {
			return CliArgs.parse_boolish(a.all_after(prefix))
		}
	}
	return default_val
}

pub fn CliArgs.string_list_or(args []string, key string, default_val []string) []string {
	mut values := []string{}
	for i, a in args {
		if a == key {
			if i + 1 < args.len && !args[i + 1].starts_with('--') {
				for raw in args[i + 1].split(',') {
					value := raw.trim_space()
					if value != '' {
						values << value
					}
				}
			}
			continue
		}
		prefix := '${key}='
		if a.starts_with(prefix) {
			for raw in a.all_after(prefix).split(',') {
				value := raw.trim_space()
				if value != '' {
					values << value
				}
			}
		}
	}
	return if values.len == 0 { default_val } else { values }
}
