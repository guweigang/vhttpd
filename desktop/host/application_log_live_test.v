module host

import json2 as json
import os

struct ApplicationLogProbeResult {
 ports map[string]int
}

// Opt-in against the real same-process Bodytest/Paseo fixture, not a mocked API.
fn test_live_two_application_logs_are_separate_through_desktop_http_reader() ! {
 path := os.getenv('VHTTPD_LOG_TEST_RESULT')
 if path == '' {return}
 probe := json.decode[ApplicationLogProbeResult](os.read_file(path)!)!
 data := fetch_workspace('http://127.0.0.1:${probe.ports['admin']}','application-log-fixture',RelayLiveStatus{},true)
 assert data.known && data.application_logs_errors.len == 0
 body := data.application_logs['wechat']
 paseo := data.application_logs['paseo']
 assert body.records.len > 0 && paseo.records.len > 0
 assert body.records.all(it.app_id == 'wechat' && !it.message.contains('[paseo-relay]'))
 assert paseo.records.all(it.app_id == 'paseo' && !it.message.contains('BODYTEST_'))
 assert body.records.any(it.message.contains('BODYTEST_SENTINEL'))
 assert paseo.dropped > 0
 assert data.applications.any(it.id == 'wechat') && data.applications.any(it.id == 'paseo')
}
