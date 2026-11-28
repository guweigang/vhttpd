module host

import json2 as json
import os
import time

fn test_native_digest_and_mtls_real_peer_refusal_and_recovery() ! {
    root := os.join_path(os.temp_dir(), 'native-auth-peer-${os.getpid()}-${time.ticks()}')
    os.mkdir_all(root)!
    defer { os.rmdir_all(root) or {} }
    fixture := os.join_path(@VMODROOT, 'desktop', 'ci', 'protocol_probe_auth_fixture.py')
    mut child := os.new_process('python3')
    child.set_args([fixture, root])
    child.set_redirect_stdio()
    child.run()
    defer { child.signal_term(); child.wait(); child.close() }
    ready_path := root + '/ready.json'
    for _ in 0 .. 100 {
        if os.is_file(ready_path) { break }
        if !child.is_alive() { return error('protocol peer fixture exited') }
        time.sleep(100 * time.millisecond)
    }
    ready := json.decode[map[string]json.Any](os.read_file(ready_path)!)!
    digest := ProbeEndpoint{host: '127.0.0.1', port: ready['digest_port']!.int(), auth_kind: 'digest', digest_user: 'isolated-digest-user', digest_password: 'isolated-digest-password'}
    a := ProtocolProbeArgs{listener: 'peer', protocol: 'stream', path: '/digest', timeout_ms: 2500, max_items: 1}
    for i in 0 .. 5 {
        e := if i == 1 { ProbeEndpoint{...digest, digest_password: 'wrong'} } else { digest }
        args := if i == 2 { ProtocolProbeArgs{...a, path: '/unsupported'} } else if i == 3 { ProtocolProbeArgs{...a, path: '/md5'} } else { a }
        value := protocol_probe(e, args)
        result := json.decode[map[string]json.Any](value)!
        expected := if i == 1 { 'probe_authentication_rejected_401' } else if i == 2 { 'probe_digest_challenge_unsupported' } else { '' }
        assert result['failure']!.str() == expected, value
        assert !value.contains('isolated-digest-password')
        if expected == '' { assert result['result']!.as_map()['events']!.as_array()[0].str() == 'digest-peer-ok' }
    }
    mtls := ProbeEndpoint{host: '127.0.0.1', port: ready['mtls_port']!.int(), secure: true, tls_name: 'localhost', ca_file: root + '/server.pem', auth_kind: 'mtls', client_cert: root + '/client.pem', client_key: root + '/client.key'}
    for i in 0 .. 5 {
        e := match i {
            1 { ProbeEndpoint{...mtls, client_cert: '', client_key: ''} }
            2 { ProbeEndpoint{...mtls, client_cert: root + '/wrong.pem', client_key: root + '/wrong.key'} }
            3 { ProbeEndpoint{...mtls, tls_name: 'wrong.invalid'} }
            else { mtls }
        }
        value := protocol_probe(e, a)
        result := json.decode[map[string]json.Any](value)!
        assert result['failure']!.str() == if i in [1, 2, 3] { 'probe_tls_verification_failed' } else { '' }, value
        assert !value.contains(root)
        if i in [0, 4] { assert result['result']!.as_map()['events']!.as_array()[0].str() == 'mtls-peer-ok' }
    }
}
