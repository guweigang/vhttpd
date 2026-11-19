module l10n

import i18n

const catalog = i18n.load_tr_map_from_files({
	'en.json': $embed_file('../locales/en.json').to_string()
})
const message_patterns = build_patterns()
const message_fragments = build_fragments()

struct MessagePattern {
	parts       []string
	translation string
	weight      int
}

struct MessageFragment {
	source      string
	translation string
	prefix      bool
	suffix      bool
}

fn build_patterns() []MessagePattern {
	mut result := []MessagePattern{}
	for source, translated in catalog['en'] {
		if !source.contains('{0}') { continue }
		mut parts := []string{}
		mut remaining := source
		mut slot := 0
		mut weight := 0
		for {
			token := '{${slot}}'
			if at := remaining.index(token) {
				parts << remaining[..at]
				weight += at
				remaining = remaining[at + token.len..]
				slot++
			} else {
				break
			}
		}
		parts << remaining
		weight += remaining.len
		if parts.len > 1 && weight > 3 { result << MessagePattern{parts, translated, weight} }
	}
	result.sort(a.weight > b.weight)
	return result
}

fn build_fragments() []MessageFragment {
	mut result := []MessageFragment{}
	for source, translated in catalog['en'] {
		if source.contains('{0}') || source.len < 5 || source.contains('\n') { continue }
		prefix := source.ends_with('：') || source.ends_with(': ') || source.ends_with(' · ') || source.ends_with(' / ') || source.ends_with(' ')
		suffix := source.starts_with(' · ') || source.starts_with(' / ') || source.starts_with('  / ')
		if prefix || suffix { result << MessageFragment{source, translated, prefix, suffix} }
	}
	result.sort(a.source.len > b.source.len)
	return result
}

// Placeholders are copied verbatim; names, paths and error payloads are never
// recursively translated. Entire templates are matched, not arbitrary substrings.
fn match_pattern(pattern MessagePattern, source string) ?string {
	if !source.starts_with(pattern.parts[0]) { return none }
	mut at := pattern.parts[0].len
	mut captures := []string{}
	for i in 1 .. pattern.parts.len {
		delimiter := pattern.parts[i]
		last := i == pattern.parts.len - 1
		end := if last {
			if !source.ends_with(delimiter) { return none }
			source.len - delimiter.len
		} else {
			if delimiter == '' { return none }
			source.index_after(delimiter, at) or { return none }
		}
		if end < at { return none }
		captures << source[at..end]
		at = end + delimiter.len
	}
	if at != source.len { return none }
	// Replace tokens in the template, rather than replacing in substituted data:
	// a captured user value may itself contain text such as "{1}".
	mut output := ''
	mut remaining := pattern.translation
	for remaining != '' {
		start := remaining.index('{') or {
			output += remaining
			break
		}
		output += remaining[..start]
		end := remaining.index_after('}', start + 1) or {
			output += remaining[start..]
			break
		}
		number := remaining[start + 1..end]
		if number != '' && number.bytes().all(it.is_digit()) && number.int() < captures.len {
			output += captures[number.int()]
		} else {
			output += remaining[start..end + 1]
		}
		remaining = remaining[end + 1..]
	}
	return output
}

fn translate_line(source string) string {
	if value := i18n.tr_from_map_opt(catalog, 'en', source, i18n.LookupConfig{}) { return value }
	for pattern in message_patterns { if value := match_pattern(pattern, source) { return value } }
	for fragment in message_fragments {
		if fragment.prefix && source.starts_with(fragment.source) {
			return fragment.translation + source[fragment.source.len..]
		}
		if fragment.suffix && source.ends_with(fragment.source) {
			return source[..source.len - fragment.source.len] + fragment.translation
		}
	}
	return source
}

// The model always holds original messages. Translation runs only on the UI
// thread at the presentation boundary, preserving state across language changes.
pub fn text(language string, source string) string {
	if language != 'en' || source == '' { return source }
	if value := i18n.tr_from_map_opt(catalog, 'en', source, i18n.LookupConfig{}) { return value }
	if source.contains('\n') { return source.split('\n').map(translate_line(it)).join('\n') }
	return translate_line(source)
}

// Context distinguishes a compact tab from a collection/menu heading without
// changing the source-language label or maintaining two independent UI trees.
pub fn text_in(language string, context string, source string) string {
	if language != 'en' {return source}
	if value:=i18n.tr_from_map_opt(catalog,'en',context+'\x04'+source,i18n.LookupConfig{}) {return value}
	return text(language,source)
}
