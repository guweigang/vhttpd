module executor

import os

// One background owner per executor. Configuration, glob segments and the file
// list survive probes; only a full refresh discovers new/deleted paths.
struct VjsxSourceScanner {
	entry       string
	root        string
	entry_row   string
	config_rows []string
	includes    [][]string
	excludes    [][]string
mut:
	files       []VjsxSignatureFile
	buffer      []u8
	directories map[string]VjsxSourceDirectory
	generation  u64
}

fn VjsxSourceScanner.new(config VjsxRuntimeFacadeConfig) VjsxSourceScanner {
	entry := os.abs_path(config.app_entry)
	root := config.signature_root_path()
	includes := config.signature_include_globs()
	excludes := config.signature_exclude_globs()
	mut scanner := VjsxSourceScanner{
		entry:       entry
		root:        root
		entry_row:   'entry:${entry}'
		config_rows: ['signature_root:${root}', 'signature_include:${includes.join(',')}',
			'signature_exclude:${excludes.join(',')}']
		includes:    VjsxHostSignature.glob_segments(VjsxHostSignature.glob_patterns(includes))
		excludes:    VjsxHostSignature.glob_segments(excludes)
	}
	scanner.refresh_files()
	return scanner
}

// Cache only path-derived data. Every refresh still reads each directory and
// checks entry types; content hashing remains unconditional once per second.
struct VjsxSourceEntry {
	name          string
	file          VjsxSignatureFile
	included      bool
	excluded_tree bool
}

struct VjsxSourceDirectory {
	entries    []VjsxSourceEntry
	generation u64
}

fn (mut scanner VjsxSourceScanner) directory_entries(current string, prefix string) []VjsxSourceEntry {
	mut names := os.ls(current) or { return []VjsxSourceEntry{} }
	names.sort()
	if cached := scanner.directories[current] {
		mut unchanged := names.len == cached.entries.len
		if unchanged {
			for i, name in names {
				if name != cached.entries[i].name {
					unchanged = false
					break
				}
			}
		}
		if unchanged {
			scanner.directories[current] = VjsxSourceDirectory{ entries: cached.entries, generation: scanner.generation }
			return cached.entries
		}
	}
	mut entries := []VjsxSourceEntry{cap: names.len}
	for name in names {
		path := os.join_path(current, name)
		rel := VjsxHostSignature.normalize_rel_path(path[prefix.len..])
		segments := rel.split('/')
		mut excluded_tree := false
		for pattern in scanner.excludes {
			if pattern.len > 0 && pattern.last() == '**'
				&& VjsxHostSignature.match_segments(segments, pattern[..pattern.len - 1]) {
				excluded_tree = true
				break
			}
		}
		entries << VjsxSourceEntry{
			name:          name
			file:          VjsxSignatureFile{ path: path, rel: rel }
			included:      rel != '' && VjsxHostSignature.matches_any(segments, scanner.includes)
				&& !VjsxHostSignature.matches_any(segments, scanner.excludes)
			excluded_tree: excluded_tree
		}
	}
	scanner.directories[current] = VjsxSourceDirectory{ entries: entries, generation: scanner.generation }
	return entries
}

fn (mut scanner VjsxSourceScanner) refresh_files() {
	// Clear references in unused capacity as well when a directory shrinks.
	for i in 0 .. scanner.files.len { scanner.files[i] = VjsxSignatureFile{} }
	scanner.files.clear()
	scanner.generation++
	if scanner.root != '' && os.exists(scanner.root) {
		prefix := scanner.root.trim_right(os.path_separator) + os.path_separator
		scanner.collect_files(scanner.root, prefix)
		scanner.files.sort(a.path < b.path)
	}
	// Deleted, renamed and newly excluded subtrees must not retain old paths.
	for path in scanner.directories.keys() {
		if scanner.directories[path].generation != scanner.generation {
			scanner.directories.delete(path)
		}
	}
}

fn (mut scanner VjsxSourceScanner) collect_files(current string, prefix string) {
	entries := scanner.directory_entries(current, prefix)
	for entry in entries {
		path := entry.file.path
		if os.is_dir(path) {
			if !entry.excluded_tree && !os.is_link(path) {
				scanner.collect_files(path, prefix)
			}
		} else if entry.included && os.exists(path) {
			scanner.files << entry.file
		}
	}
}

// Stream the exact legacy row representation into FNV without formatting a
// metadata string for every file or joining a temporary array of rows.
struct VjsxSignatureHash {
mut:
	value   u64 = 14695981039346656037
	started bool
}

fn (mut hash VjsxSignatureHash) text(value string) {
	for byte in value { hash.value = (hash.value ^ u64(byte)) * u64(1099511628211) }
}

fn (mut hash VjsxSignatureHash) row(value string) {
	if hash.started { hash.text('|') }
	hash.started = true
	hash.text(value)
}

fn (mut hash VjsxSignatureHash) integer(value i64) {
	mut digits := [20]u8{}
	mut at := digits.len
	mut magnitude := if value < 0 { u64(-(value + 1)) + 1 } else { u64(value) }
	for {
		at--
		digits[at] = u8(magnitude % 10) + `0`
		magnitude /= 10
		if magnitude == 0 { break }
	}
	if value < 0 { hash.text('-') }
	for i in at .. digits.len {
		hash.value = (hash.value ^ u64(digits[i])) * u64(1099511628211)
	}
}

fn (scanner &VjsxSourceScanner) initial_hash() VjsxSignatureHash {
	mut hash := VjsxSignatureHash{}
	hash.row(scanner.entry_row)
	if st := os.stat(scanner.entry) {
		hash.row('entry_meta:')
		hash.integer(st.mtime)
		hash.text(':')
		hash.integer(st.size)
	} else {
		hash.row('entry_meta:missing')
	}
	for row in scanner.config_rows { hash.row(row) }
	return hash
}

fn (scanner &VjsxSourceScanner) probe() string {
	mut hash := scanner.initial_hash()
	for file in scanner.files {
		st := os.stat(file.path) or { continue }
		hash.row(file.rel)
		hash.text(':')
		hash.integer(st.mtime)
		hash.text(':')
		hash.integer(st.size)
	}
	return hash.value.hex()
}

fn (mut scanner VjsxSourceScanner) signature() string {
	if scanner.buffer.len == 0 { scanner.buffer = []u8{len: 65536} }
	mut hash := scanner.initial_hash()
	for file in scanner.files {
		st := os.stat(file.path) or { continue }
		hash.row(file.rel)
		hash.text(':')
		hash.integer(st.mtime)
		hash.text(':')
		hash.integer(st.size)
		hash.text(':')
		hash.text(VjsxHostSignature.file_hash(file.path, mut scanner.buffer))
	}
	return hash.value.hex()
}
