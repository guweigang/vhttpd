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

struct VjsxSignatureFile {
	path string
	rel  string
}

fn VjsxHostSignature.file_hash(path string, mut buffer []u8) string {
	mut file := os.open(path) or { return 'read_error' }
	defer { file.close() }
	mut hash := u64(14695981039346656037)
	for {
		count := file.read(mut buffer) or {
			if err is os.Eof { break }
			return 'read_error'
		}
		if count == 0 { break }
		for byte in buffer[..count] {
			hash = (hash ^ u64(byte)) * u64(1099511628211)
		}
	}
	return hash.hex()
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

fn VjsxHostSignature.collect_files(current string, mut out []string) {
	entries := os.ls(current) or { return }
	for entry in entries {
		path := os.join_path(current, entry)
		if os.is_dir(path) && !os.is_link(path) {
			VjsxHostSignature.collect_files(path, mut out)
			continue
		}
		if os.is_dir(path) {
			continue
		}
		out << path
	}
}

fn VjsxHostSignature.glob_segments(globs []string) [][]string {
	mut patterns := [][]string{}
	for glob in globs {
		normalized := VjsxHostSignature.normalize_glob(glob)
		if normalized != '' { patterns << normalized.split('/') }
	}
	return patterns
}

fn VjsxHostSignature.matches_any(segments []string, patterns [][]string) bool {
	for pattern in patterns {
		if VjsxHostSignature.match_segments(segments, pattern) { return true }
	}
	return false
}

fn VjsxHostSignature.matching_files(root string, includes []string, excludes []string) []VjsxSignatureFile {
	if root.trim_space() == '' || !os.exists(root) {
		return []VjsxSignatureFile{}
	}
	root_abs := os.abs_path(root)
	prefix := root_abs.trim_right(os.path_separator) + os.path_separator
	include_patterns := VjsxHostSignature.glob_segments(includes)
	exclude_patterns := VjsxHostSignature.glob_segments(excludes)
	mut files := []string{}
	VjsxHostSignature.collect_files(root_abs, mut files)
	files.sort()
	mut matches := []VjsxSignatureFile{}
	for path in files {
		if !os.exists(path) || os.is_dir(path) {
			continue
		}
		// Traversal starts at the normalized absolute root, so each file already
		// has that prefix. Avoid resolving the working directory for every file.
		rel := VjsxHostSignature.normalize_rel_path(path[prefix.len..])
		if rel == '' {
			continue
		}
		segments := rel.split('/')
		if VjsxHostSignature.matches_any(segments, include_patterns)
			&& !VjsxHostSignature.matches_any(segments, exclude_patterns) {
			matches << VjsxSignatureFile{ path: path, rel: rel }
		}
	}
	return matches
}

fn VjsxHostSignature.expand_globs(root string, globs []string) []string {
	return VjsxHostSignature.matching_files(root, globs, []string{}).map(it.path)
}

fn VjsxHostSignature.collect_source_signature(root string, include_globs []string, exclude_globs []string, mut rows []string) {
	if root.trim_space() == '' || !os.exists(root) {
		return
	}
	files := VjsxHostSignature.matching_files(root,
		VjsxHostSignature.glob_patterns(include_globs), exclude_globs)
	mut buffer := []u8{len: 65536}
	for file in files {
		st := os.stat(file.path) or { continue }
		rows << '${file.rel}:${st.mtime}:${st.size}:${VjsxHostSignature.file_hash(file.path, mut buffer)}'
	}
}

fn VjsxHostSignature.collect_source_probe(root string, include_globs []string, exclude_globs []string, mut rows []string) {
	if root.trim_space() == '' || !os.exists(root) {
		return
	}
	files := VjsxHostSignature.matching_files(root,
		VjsxHostSignature.glob_patterns(include_globs), exclude_globs)
	for file in files {
		st := os.stat(file.path) or { continue }
		rows << '${file.rel}:${st.mtime}:${st.size}'
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
