module host

import encoding.base64
import runtime_plan

fn test_probe_basic_and_api_key_refs_are_routed_and_validated() ! {
	for options in [
		{'probe_auth_kind': 'basic', 'probe_basic_username': 'probe-user', 'probe_basic_password': 'private-password'},
		{'probe_auth_kind': 'api_key', 'probe_api_key': 'private-api-key'},
	] {
		plan := runtime_plan.RuntimePlan{
			listeners: {'web': runtime_plan.ListenerPlan{id: 'web', protocol: 'http', host: '::1', port: 8080}}
			adapters: {'auth': runtime_plan.AdapterPlan{id: 'auth', options: runtime_plan.PlanOptions{strings: options}}}
			pipelines: [runtime_plan.PipelinePlan{ingress: runtime_plan.ResourceRef{domain: .listener, id: 'web'}, egress: runtime_plan.ResourceRef{domain: .adapter, id: 'auth'}}]
		}
		e := protocol_probe_endpoint(plan, ProtocolProbeArgs{listener: 'web', protocol: 'stream', path: '/', auth_ref: 'auth'})!
		assert e.host == '::1'
		if options['probe_auth_kind'] == 'basic' {
			assert e.authorization == 'Authorization: Basic ' + base64.encode('probe-user:private-password'.bytes()) + '\r\n'
			secrets := protocol_probe_header_secrets(e.authorization)
			assert 'private-password' in secrets
			assert 'probe-user' in secrets
		} else { assert e.authorization == 'X-API-Key: private-api-key\r\n' }
		inventory := protocol_probe_options(plan, ['web'])
		assert inventory.contains(options['probe_auth_kind'])
		assert !inventory.contains('private-password')
		assert !inventory.contains('private-api-key')
		if _ := protocol_probe_endpoint(runtime_plan.RuntimePlan{...plan, pipelines: []runtime_plan.PipelinePlan{}}, ProtocolProbeArgs{listener: 'web', protocol: 'stream', path: '/', auth_ref: 'auth'}) { return error('unrouted authentication accepted') }
	}
	for options in [
		{'probe_auth_kind': 'basic', 'probe_basic_username': 'bad:user', 'probe_basic_password': 'private'},
		{'probe_auth_kind': 'basic', 'probe_basic_username': 'user', 'probe_basic_password': 'private\r\nInjected: header'},
		{'probe_auth_kind': 'api_key', 'probe_api_key': 'private\nheader'},
		{'probe_auth_kind': 'digest', 'probe_bearer_token': 'private'},
	] { if _ := protocol_probe_auth_header(options) { return error('invalid credential accepted') } }
}
