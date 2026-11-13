module host

fn test_digest_rfc_vector_and_refusals() ! {
    challenge := 'Digest realm="http-auth@example.org", qop="auth, auth-int", algorithm=MD5, nonce="7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v", opaque="FQhe/qaU925kfnzjCev0ciny7QMwst+1tdOD8EhJIHpV"'
    header := probe_digest_header(challenge, 'Mufasa', 'Circle of Life', '/dir/index.html', 'f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ')!
    assert header.contains('response="8ca523f5e9506fed4657c9700eebdbec"')
    sha_header := probe_digest_header(challenge.replace('algorithm=MD5', 'algorithm=SHA-256'), 'Mufasa', 'Circle of Life', '/dir/index.html', 'f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ')!
    assert sha_header.contains('753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1')
    for invalid in ['Basic realm="test"', 'Digest realm="x", nonce="n", qop="auth-int"', 'Digest realm="x", nonce="n", qop=auth, algorithm=SHA-512-256', 'Digest realm="x", realm="y", nonce="n", qop=auth', 'Digest realm="unterminated', 'Digest realm="x", nonce="n", qop=auth,'] {
        if _ := probe_digest_header(invalid, 'user', 'password', '/', 'random') { return error('unsupported digest accepted') }
    }
    f := probe_digest_fields('Digest realm="escaped\\"quote", nonce="n", qop=auth')!
    assert f['realm'] == 'escaped"quote'
}
