module jsonutils

// Lightweight top-level JSON key detector.
// Single-pass scanner that only parses the top-level object keys and skips values.
// This avoids allocating a full JSON parse while correctly handling strings and escapes.
pub fn has_any_top_level_key(raw string, keys []string) bool {
    if raw.len == 0 || keys.len == 0 {
        return false
    }

    mut keyset := map[string]bool{}
    for k in keys {
        keyset[k] = true
    }

    mut i := 0
    // skip leading whitespace
    for i < raw.len && (raw[i] == ` ` || raw[i] == `\n` || raw[i] == `\r` || raw[i] == `\t`) {
        i++
    }
    if i >= raw.len || raw[i] != `{` {
        return false
    }
    i++ // skip '{'

    for {
        // skip whitespace
        for i < raw.len && (raw[i] == ` ` || raw[i] == `\n` || raw[i] == `\r` || raw[i] == `\t`) {
            i++
        }
        if i >= raw.len {
            return false
        }
        // end of object
        if raw[i] == `}` {
            return false
        }
        // expect a string key
        if raw[i] != `"` {
            // malformed — try to recover by skipping to next comma or closing brace
            for i < raw.len && raw[i] != `,` && raw[i] != `}` {
                i++
            }
            if i < raw.len && raw[i] == `,` {
                i++
                continue
            }
            return false
        }

        // parse key string
        i++ // skip opening quote
        start := i
        for i < raw.len {
            if raw[i] == `"` {
                // count backslashes preceding this quote
                mut bs := 0
                mut j := i - 1
                for j >= start && raw[j] == `\\` {
                    bs++
                    j--
                }
                if bs % 2 == 0 {
                    break
                }
            }
            i++
        }
        if i >= raw.len {
            return false
        }
        key := raw[start..i]
        i++ // skip closing quote

        // skip whitespace then expect ':'
        for i < raw.len && (raw[i] == ` ` || raw[i] == `\n` || raw[i] == `\r` || raw[i] == `\t`) {
            i++
        }
        if i >= raw.len || raw[i] != `:` {
            return false
        }
        i++ // skip ':'

        // if key matches, return true
        // keys in JSON may contain escape sequences (e.g. \"), so compare both
        // the raw substring and the unescaped form against the lookup set.
        if keyset[key] || keyset[unescape_json_string(key)] {
            return true
        }

        // skip value (string, object, array, number, literal)
        for i < raw.len && (raw[i] == ` ` || raw[i] == `\n` || raw[i] == `\r` || raw[i] == `\t`) {
            i++
        }
        if i >= raw.len {
            return false
        }

        c := raw[i]
        if c == `"` {
            // string value
            i++
            mut startv := i
            for i < raw.len {
                if raw[i] == `"` {
                    mut bs := 0
                    mut j := i - 1
                    for j >= startv && raw[j] == `\\` {
                        bs++
                        j--
                    }
                    if bs % 2 == 0 {
                        i++
                        break
                    }
                }
                i++
            }
        } else if c == `{` {
            // object — skip balanced braces (simple stack). start with depth=1
            i++ // skip initial '{'
            mut depth := 1
            for i < raw.len {
                if raw[i] == `"` {
                    // skip string inside object
                    i++
                    mut startv := i
                    for i < raw.len {
                        if raw[i] == `"` {
                            mut bs := 0
                            mut j := i - 1
                            for j >= startv && raw[j] == `\\` {
                                bs++
                                j--
                            }
                            if bs % 2 == 0 {
                                i++
                                break
                            }
                        }
                        i++
                    }
                    continue
                }
                if raw[i] == `{` {
                    depth++
                } else if raw[i] == `}` {
                    depth--
                    if depth == 0 {
                        i++
                        break
                    }
                }
                i++
            }
        } else if c == `[` {
            // array — skip balanced brackets. start with depth=1
            i++
            mut depth := 1
            for i < raw.len {
                if raw[i] == `"` {
                    i++
                    mut startv := i
                    for i < raw.len {
                        if raw[i] == `"` {
                            mut bs := 0
                            mut j := i - 1
                            for j >= startv && raw[j] == `\\` {
                                bs++
                                j--
                            }
                            if bs % 2 == 0 {
                                i++
                                break
                            }
                        }
                        i++
                    }
                    continue
                }
                if raw[i] == `[` {
                    depth++
                } else if raw[i] == `]` {
                    depth--
                    if depth == 0 {
                        i++
                        break
                    }
                }
                i++
            }
        } else {
            // number or literal (true,false,null) — skip until comma or closing brace
            for i < raw.len && raw[i] != `,` && raw[i] != `}` {
                // allow nested strings to be skipped harmlessly
                if raw[i] == `"` {
                    i++
                    mut startv := i
                    for i < raw.len {
                        if raw[i] == `"` {
                            mut bs := 0
                            mut j := i - 1
                            for j >= startv && raw[j] == `\\` {
                                bs++
                                j--
                            }
                            if bs % 2 == 0 {
                                i++
                                break
                            }
                        }
                        i++
                    }
                    continue
                }
                i++
            }
        }

        // after skipping value, skip whitespace and handle next separator
        for i < raw.len && (raw[i] == ` ` || raw[i] == `\n` || raw[i] == `\r` || raw[i] == `\t`) {
            i++
        }
        if i < raw.len && raw[i] == `,` {
            i++
            continue
        }
        if i < raw.len && raw[i] == `}` {
            return false
        }
    }
    // should not reach here, but return false defensively
    return false
}

pub fn has_top_level_key(raw string, key string) bool {
    return has_any_top_level_key(raw, [key])
}

// Minimal JSON string unescape for keys/values we inspect. Supports common escapes: \", \\, \/, \b, \f, \n, \r, \t.
fn unescape_json_string(s string) string {
    mut out := []rune{cap: s.len}
    mut i := 0
    for i < s.len {
        c := s[i]
        if c != `\\` {
            out << rune(c)
            i++
            continue
        }
        i++
        if i >= s.len {
            break
        }
        esc := s[i]
        match esc {
            `"` { out << rune(`"`) }
            `\\` { out << rune(`\\`) }
            `/` { out << rune(`/`) }
            `b` { out << rune(`\b`) }
            `f` { out << rune(`\f`) }
            `n` { out << rune(`\n`) }
            `r` { out << rune(`\r`) }
            `t` { out << rune(`\t`) }
            `u` {
                if i + 4 < s.len {
                    if decoded := decode_json_hex4(s[i + 1..i + 5]) {
                        out << decoded
                        i += 5
                        continue
                    }
                }
                out << rune(`u`)
            }
            else { out << rune(esc) }
        }
        i++
    }
    return out.string()
}

fn decode_json_hex4(raw string) ?rune {
    if raw.len != 4 {
        return none
    }
    mut value := rune(0)
    for ch in raw {
        digit := json_hex_nibble(ch) or { return none }
        value = (value << 4) | rune(digit)
    }
    return value
}

fn json_hex_nibble(ch u8) ?int {
    if ch >= `0` && ch <= `9` {
        return int(ch - `0`)
    }
    if ch >= `a` && ch <= `f` {
        return 10 + int(ch - `a`)
    }
    if ch >= `A` && ch <= `F` {
        return 10 + int(ch - `A`)
    }
    return none
}
