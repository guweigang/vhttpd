module main

import hash.fnv1a
import os

const vjsx_default_signature_excludes = [
	'.git/**',
	'.hg/**',
	'.svn/**',
	'node_modules/**',
	'dist/**',
	'build/**',
	'coverage/**',
	'.next/**',
	'.nuxt/**',
	'.turbo/**',
	'tmp/**',
	'temp/**',
	'vendor/**',
]

const vjsx_signature_source_exts = ['.js', '.mjs', '.cjs', '.ts', '.mts', '.cts', '.json']

fn vjsx_signature_file_hash(path string) string {
	bytes := os.read_bytes(path) or { return 'read_error' }
	return fnv1a.sum64_string(bytes.bytestr()).hex()
}

fn normalize_vjsx_signature_glob(raw string) string {
	return raw.trim_space().replace('\\', '/').trim_left('/')
}

fn normalize_vjsx_signature_rel_path(raw string) string {
	mut rel := raw.trim_space().replace('\\', '/')
	if rel == '.' {
		return ''
	}
	rel = rel.trim_left('/')
	for rel.starts_with('./') {
		rel = rel[2..]
	}
	return rel
}

fn vjsx_signature_root_for_config(config VjsxRuntimeFacadeConfig) string {
	if config.signature_root.trim_space() != '' {
		return os.abs_path(config.signature_root)
	}
	if config.module_root.trim_space() != '' {
		return os.abs_path(config.module_root)
	}
	if config.app_entry.trim_space() != '' {
		return os.dir(os.abs_path(config.app_entry))
	}
	return ''
}

fn vjsx_signature_include_globs(config VjsxRuntimeFacadeConfig) []string {
	return config.signature_include.map(normalize_vjsx_signature_glob).filter(it != '')
}

fn vjsx_signature_exclude_globs(config VjsxRuntimeFacadeConfig) []string {
	mut out := []string{}
	for pattern in vjsx_default_signature_excludes {
		normalized := normalize_vjsx_signature_glob(pattern)
		if normalized != '' {
			out << normalized
		}
	}
	for pattern in config.signature_exclude {
		normalized := normalize_vjsx_signature_glob(pattern)
		if normalized != '' {
			out << normalized
		}
	}
	return out
}

fn vjsx_signature_glob_patterns(include_globs []string) []string {
	if include_globs.len > 0 {
		return include_globs
	}
	mut patterns := []string{}
	for ext in vjsx_signature_source_exts {
		patterns << '*${ext}'
		patterns << '**/*${ext}'
	}
	return patterns
}

fn vjsx_signature_match_segment(path_segment string, pattern_segment string) bool {
	mut pi := 0
	mut si := 0
	mut star := -1
	mut matched_idx := 0
	for si < path_segment.len {
		if pi < pattern_segment.len && (pattern_segment[pi] == `?` || pattern_segment[pi] == path_segment[si]) {
			pi++
			si++
			continue
		}
		if pi < pattern_segment.len && pattern_segment[pi] == `*` {
			star = pi
			matched_idx = si
			pi++
			continue
		}
		if star >= 0 {
			pi = star + 1
			matched_idx++
			si = matched_idx
			continue
		}
		return false
	}
	for pi < pattern_segment.len && pattern_segment[pi] == `*` {
		pi++
	}
	return pi == pattern_segment.len
}

fn vjsx_signature_match_segments(path_segments []string, pattern_segments []string) bool {
	if pattern_segments.len == 0 {
		return path_segments.len == 0
	}
	if pattern_segments[0] == '**' {
		if vjsx_signature_match_segments(path_segments, pattern_segments[1..]) {
			return true
		}
		for i := 0; i < path_segments.len; i++ {
			if vjsx_signature_match_segments(path_segments[i + 1..], pattern_segments[1..]) {
				return true
			}
		}
		return false
	}
	if path_segments.len == 0 {
		return false
	}
	if !vjsx_signature_match_segment(path_segments[0], pattern_segments[0]) {
		return false
	}
	return vjsx_signature_match_segments(path_segments[1..], pattern_segments[1..])
}

fn vjsx_signature_path_matches(rel_path string, pattern string) bool {
	normalized_path := normalize_vjsx_signature_rel_path(rel_path)
	normalized_pattern := normalize_vjsx_signature_glob(pattern)
	if normalized_path == '' || normalized_pattern == '' {
		return false
	}
	path_segments := normalized_path.split('/')
	pattern_segments := normalized_pattern.split('/')
	return vjsx_signature_match_segments(path_segments, pattern_segments)
}

fn vjsx_signature_collect_files(root string, current string, mut out []string) {
	entries := os.ls(current) or { return }
	for entry in entries {
		path := os.join_path(current, entry)
		if os.is_dir(path) && !os.is_link(path) {
			vjsx_signature_collect_files(root, path, mut out)
			continue
		}
		if os.is_dir(path) {
			continue
		}
		out << os.abs_path(path)
	}
}

fn vjsx_signature_expand_globs(root string, globs []string) []string {
	if root.trim_space() == '' || !os.exists(root) {
		return []string{}
	}
	mut files := []string{}
	vjsx_signature_collect_files(root, root, mut files)
	mut matches := map[string]bool{}
	for raw_path in files {
		path := os.abs_path(raw_path)
		if !os.exists(path) || os.is_dir(path) {
			continue
		}
		rel := normalize_vjsx_signature_rel_path(runtime_relative_path(root, path))
		if rel == '' {
			continue
		}
		for pattern in globs {
			normalized := normalize_vjsx_signature_glob(pattern)
			if normalized == '' {
				continue
			}
			if vjsx_signature_path_matches(rel, normalized) {
				matches[path] = true
				break
			}
		}
	}
	mut out := matches.keys()
	out.sort()
	return out
}

fn vjsx_source_signature_collect(root string, include_globs []string, exclude_globs []string, mut rows []string) {
	if root.trim_space() == '' || !os.exists(root) {
		return
	}
	include_matches := vjsx_signature_expand_globs(root, vjsx_signature_glob_patterns(include_globs))
	exclude_matches := vjsx_signature_expand_globs(root, exclude_globs)
	mut exclude_set := map[string]bool{}
	for path in exclude_matches {
		exclude_set[path] = true
	}
	for path in include_matches {
		if path in exclude_set {
			continue
		}
		rel := normalize_vjsx_signature_rel_path(runtime_relative_path(root, path))
		if rel == '' {
			continue
		}
		st := os.stat(path) or { continue }
		rows << '${rel}:${st.mtime}:${st.size}:${vjsx_signature_file_hash(path)}'
	}
}

fn vjsx_source_probe_collect(root string, include_globs []string, exclude_globs []string, mut rows []string) {
	if root.trim_space() == '' || !os.exists(root) {
		return
	}
	include_matches := vjsx_signature_expand_globs(root, vjsx_signature_glob_patterns(include_globs))
	exclude_matches := vjsx_signature_expand_globs(root, exclude_globs)
	mut exclude_set := map[string]bool{}
	for path in exclude_matches {
		exclude_set[path] = true
	}
	for path in include_matches {
		if path in exclude_set {
			continue
		}
		rel := normalize_vjsx_signature_rel_path(runtime_relative_path(root, path))
		if rel == '' {
			continue
		}
		st := os.stat(path) or { continue }
		rows << '${rel}:${st.mtime}:${st.size}'
	}
}

fn vjsx_source_probe_for_config(config VjsxRuntimeFacadeConfig) string {
	entry_abs := os.abs_path(config.app_entry)
	mut probe_rows := ['entry:${entry_abs}']
	mut entry_meta := 'entry_meta:missing'
	if entry_stat := os.stat(entry_abs) {
		entry_meta = 'entry_meta:${entry_stat.mtime}:${entry_stat.size}'
	}
	probe_rows << entry_meta
	signature_root := vjsx_signature_root_for_config(config)
	include_globs := vjsx_signature_include_globs(config)
	exclude_globs := vjsx_signature_exclude_globs(config)
	probe_rows << 'signature_root:${signature_root}'
	probe_rows << 'signature_include:${include_globs.join(',')}'
	probe_rows << 'signature_exclude:${exclude_globs.join(',')}'
	if signature_root != '' {
		vjsx_source_probe_collect(signature_root, include_globs, exclude_globs, mut probe_rows)
	}
	return fnv1a.sum64_string(probe_rows.join('|')).hex()
}

fn vjsx_source_signature_for_config(config VjsxRuntimeFacadeConfig) string {
	entry_abs := os.abs_path(config.app_entry)
	mut signature_rows := ['entry:${entry_abs}']
	mut entry_meta := 'entry_meta:missing'
	if entry_stat := os.stat(entry_abs) {
		entry_meta = 'entry_meta:${entry_stat.mtime}:${entry_stat.size}'
	}
	signature_rows << entry_meta
	signature_root := vjsx_signature_root_for_config(config)
	include_globs := vjsx_signature_include_globs(config)
	exclude_globs := vjsx_signature_exclude_globs(config)
	signature_rows << 'signature_root:${signature_root}'
	signature_rows << 'signature_include:${include_globs.join(',')}'
	signature_rows << 'signature_exclude:${exclude_globs.join(',')}'
	if signature_root != '' {
		vjsx_source_signature_collect(signature_root, include_globs, exclude_globs, mut
			signature_rows)
	}
	return fnv1a.sum64_string(signature_rows.join('|')).hex()
}
