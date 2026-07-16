module executor

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

struct VjsxHostSignature {}

fn VjsxHostSignature.file_hash(path string) string {
	bytes := os.read_bytes(path) or { return 'read_error' }
	return fnv1a.sum64_string(bytes.bytestr()).hex()
}

fn VjsxHostSignature.normalize_glob(raw string) string {
	return raw.trim_space().replace('\\', '/').trim_left('/')
}

fn VjsxHostSignature.normalize_rel_path(raw string) string {
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

fn (config VjsxRuntimeFacadeConfig) signature_root_path() string {
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

fn (config VjsxRuntimeFacadeConfig) signature_include_globs() []string {
	return config.signature_include.map(VjsxHostSignature.normalize_glob).filter(it != '')
}

fn (config VjsxRuntimeFacadeConfig) signature_exclude_globs() []string {
	mut out := []string{}
	for pattern in vjsx_default_signature_excludes {
		normalized := VjsxHostSignature.normalize_glob(pattern)
		if normalized != '' {
			out << normalized
		}
	}
	for pattern in config.signature_exclude {
		normalized := VjsxHostSignature.normalize_glob(pattern)
		if normalized != '' {
			out << normalized
		}
	}
	return out
}

fn VjsxHostSignature.glob_patterns(include_globs []string) []string {
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

fn VjsxHostSignature.match_segment(path_segment string, pattern_segment string) bool {
	mut pi := 0
	mut si := 0
	mut star := -1
	mut matched_idx := 0
	for si < path_segment.len {
		if pi < pattern_segment.len
			&& (pattern_segment[pi] == `?` || pattern_segment[pi] == path_segment[si]) {
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

fn VjsxHostSignature.match_segments(path_segments []string, pattern_segments []string) bool {
	if pattern_segments.len == 0 {
		return path_segments.len == 0
	}
	if pattern_segments[0] == '**' {
		if VjsxHostSignature.match_segments(path_segments, pattern_segments[1..]) {
			return true
		}
		for i := 0; i < path_segments.len; i++ {
			if VjsxHostSignature.match_segments(path_segments[i + 1..], pattern_segments[1..]) {
				return true
			}
		}
		return false
	}
	if path_segments.len == 0 {
		return false
	}
	if !VjsxHostSignature.match_segment(path_segments[0], pattern_segments[0]) {
		return false
	}
	return VjsxHostSignature.match_segments(path_segments[1..], pattern_segments[1..])
}

fn VjsxHostSignature.path_matches(rel_path string, pattern string) bool {
	normalized_path := VjsxHostSignature.normalize_rel_path(rel_path)
	normalized_pattern := VjsxHostSignature.normalize_glob(pattern)
	if normalized_path == '' || normalized_pattern == '' {
		return false
	}
	path_segments := normalized_path.split('/')
	pattern_segments := normalized_pattern.split('/')
	return VjsxHostSignature.match_segments(path_segments, pattern_segments)
}

fn VjsxHostSignature.collect_files(_root string, current string, mut out []string) {
	entries := os.ls(current) or { return }
	for entry in entries {
		path := os.join_path(current, entry)
		if os.is_dir(path) && !os.is_link(path) {
			VjsxHostSignature.collect_files(_root, path, mut out)
			continue
		}
		if os.is_dir(path) {
			continue
		}
		out << os.abs_path(path)
	}
}

fn VjsxHostSignature.expand_globs(root string, globs []string) []string {
	if root.trim_space() == '' || !os.exists(root) {
		return []string{}
	}
	mut files := []string{}
	VjsxHostSignature.collect_files(root, root, mut files)
	mut matches := map[string]bool{}
	for raw_path in files {
		path := os.abs_path(raw_path)
		if !os.exists(path) || os.is_dir(path) {
			continue
		}
		rel := VjsxHostSignature.normalize_rel_path(VjsxHostPath.relative(root, path))
		if rel == '' {
			continue
		}
		for pattern in globs {
			normalized := VjsxHostSignature.normalize_glob(pattern)
			if normalized == '' {
				continue
			}
			if VjsxHostSignature.path_matches(rel, normalized) {
				matches[path] = true
				break
			}
		}
	}
	mut out := matches.keys()
	out.sort()
	return out
}

fn VjsxHostSignature.collect_source_signature(root string, include_globs []string, exclude_globs []string, mut rows []string) {
	if root.trim_space() == '' || !os.exists(root) {
		return
	}
	include_matches := VjsxHostSignature.expand_globs(root,
		VjsxHostSignature.glob_patterns(include_globs))
	exclude_matches := VjsxHostSignature.expand_globs(root, exclude_globs)
	mut exclude_set := map[string]bool{}
	for path in exclude_matches {
		exclude_set[path] = true
	}
	for path in include_matches {
		if path in exclude_set {
			continue
		}
		rel := VjsxHostSignature.normalize_rel_path(VjsxHostPath.relative(root, path))
		if rel == '' {
			continue
		}
		st := os.stat(path) or { continue }
		rows << '${rel}:${st.mtime}:${st.size}:${VjsxHostSignature.file_hash(path)}'
	}
}

fn VjsxHostSignature.collect_source_probe(root string, include_globs []string, exclude_globs []string, mut rows []string) {
	if root.trim_space() == '' || !os.exists(root) {
		return
	}
	include_matches := VjsxHostSignature.expand_globs(root,
		VjsxHostSignature.glob_patterns(include_globs))
	exclude_matches := VjsxHostSignature.expand_globs(root, exclude_globs)
	mut exclude_set := map[string]bool{}
	for path in exclude_matches {
		exclude_set[path] = true
	}
	for path in include_matches {
		if path in exclude_set {
			continue
		}
		rel := VjsxHostSignature.normalize_rel_path(VjsxHostPath.relative(root, path))
		if rel == '' {
			continue
		}
		st := os.stat(path) or { continue }
		rows << '${rel}:${st.mtime}:${st.size}'
	}
}

fn (config VjsxRuntimeFacadeConfig) source_probe() string {
	entry_abs := os.abs_path(config.app_entry)
	mut probe_rows := ['entry:${entry_abs}']
	mut entry_meta := 'entry_meta:missing'
	if entry_stat := os.stat(entry_abs) {
		entry_meta = 'entry_meta:${entry_stat.mtime}:${entry_stat.size}'
	}
	probe_rows << entry_meta
	signature_root := config.signature_root_path()
	include_globs := config.signature_include_globs()
	exclude_globs := config.signature_exclude_globs()
	probe_rows << 'signature_root:${signature_root}'
	probe_rows << 'signature_include:${include_globs.join(',')}'
	probe_rows << 'signature_exclude:${exclude_globs.join(',')}'
	if signature_root != '' {
		VjsxHostSignature.collect_source_probe(signature_root, include_globs, exclude_globs, mut
			probe_rows)
	}
	return fnv1a.sum64_string(probe_rows.join('|')).hex()
}

pub fn (config VjsxRuntimeFacadeConfig) source_signature() string {
	entry_abs := os.abs_path(config.app_entry)
	mut signature_rows := ['entry:${entry_abs}']
	mut entry_meta := 'entry_meta:missing'
	if entry_stat := os.stat(entry_abs) {
		entry_meta = 'entry_meta:${entry_stat.mtime}:${entry_stat.size}'
	}
	signature_rows << entry_meta
	signature_root := config.signature_root_path()
	include_globs := config.signature_include_globs()
	exclude_globs := config.signature_exclude_globs()
	signature_rows << 'signature_root:${signature_root}'
	signature_rows << 'signature_include:${include_globs.join(',')}'
	signature_rows << 'signature_exclude:${exclude_globs.join(',')}'
	if signature_root != '' {
		VjsxHostSignature.collect_source_signature(signature_root, include_globs, exclude_globs, mut
			signature_rows)
	}
	return fnv1a.sum64_string(signature_rows.join('|')).hex()
}
