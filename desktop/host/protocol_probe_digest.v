module host

import crypto.md5
import crypto.sha256

// A deliberately bounded RFC 7616 subset: one challenge, ASCII, qop=auth,
// MD5/SHA-256, GET only. No silent fallback to Basic or unauthenticated success.
fn probe_digest_fields(challenge string) !map[string]string {
    if challenge.len > 8192 || !challenge.starts_with('Digest ') { return error('probe_digest_challenge_unsupported') }
    mut rest := challenge[7..].trim_space()
    mut fields := map[string]string{}
    for rest != '' {
        key := rest.all_before('=').trim_space().to_lower()
        if !rest.contains('=') || key == '' || key in fields || key.bytes().any(!(it.is_alnum() || it in [`_`, `-`])) { return error('probe_digest_challenge_unsupported') }
        rest = rest.all_after('=').trim_left(' \t')
        mut value := ''
        if rest.starts_with('"') {
            mut i := 1
            mut closed := false
            for i < rest.len {
                if rest[i] == `"` { i++; closed = true; break }
                if rest[i] == `\\` { i++; if i >= rest.len { break } }
                value += rest[i].ascii_str()
                i++
            }
            if !closed { return error('probe_digest_challenge_unsupported') }
            rest = rest[i..].trim_left(' \t')
        } else {
            value = rest.all_before(',').trim_space()
            if value == '' || value.bytes().any(!(it.is_alnum() || it in [`_`, `-`])) { return error('probe_digest_challenge_unsupported') }
            rest = rest[value.len..].trim_left(' \t')
        }
        if value.bytes().any(it < 32 || it > 126) { return error('probe_digest_challenge_unsupported') }
        fields[key] = value
        if rest != '' {
            if !rest.starts_with(',') { return error('probe_digest_challenge_unsupported') }
            rest = rest[1..].trim_left(' \t')
            if rest == '' { return error('probe_digest_challenge_unsupported') }
        }
    }
    return fields
}

fn probe_digest_quote(value string) string {
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'
}

fn probe_digest_hash(value string, algorithm string) string {
    return if algorithm == 'MD5' { md5.hexhash(value) } else { sha256.hexhash(value) }
}

fn probe_digest_header(challenge string, user string, password string, path string, cnonce string) !string {
    f := probe_digest_fields(challenge)!
    algorithm := (f['algorithm'] or { 'MD5' }).to_upper()
    if algorithm !in ['MD5', 'SHA-256'] || !f['qop'].split(',').any(it.trim_space() == 'auth') || f['nonce'] == '' || 'realm' !in f || (f['userhash'] or { 'false' }) != 'false' || (f['charset'] or { 'UTF-8' }).to_upper() != 'UTF-8' { return error('probe_digest_challenge_unsupported') }
    ha1 := probe_digest_hash(user + ':' + f['realm'] + ':' + password, algorithm)
    ha2 := probe_digest_hash('GET:' + path, algorithm)
    response := probe_digest_hash(ha1 + ':' + f['nonce'] + ':00000001:' + cnonce + ':auth:' + ha2, algorithm)
    mut header := 'Authorization: Digest username=' + probe_digest_quote(user) + ', realm=' + probe_digest_quote(f['realm']) + ', nonce=' + probe_digest_quote(f['nonce']) + ', uri=' + probe_digest_quote(path) + ', response=' + probe_digest_quote(response) + ', cnonce=' + probe_digest_quote(cnonce) + ', algorithm=' + algorithm + ', qop=auth, nc=00000001'
    if 'opaque' in f { header += ', opaque=' + probe_digest_quote(f['opaque']) }
    return header + '\r\n'
}
