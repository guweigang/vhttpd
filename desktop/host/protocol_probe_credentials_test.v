module host

import runtime_plan

fn test_remote_probe_uses_literal_remote_source_not_desktop_environment() ! {
	literal := '[adapters."business.id"]\noptions.probe_bearer_token="private-literal"\n'
	assert remote_probe_literal_credential({'/remote/a.toml': literal}, 'business.id')! == 'private-literal'
	for value in ['', '$' + '{env.HOME}', '$' + '{env.PROBE_TOKEN:-fallback}'] {
		text := '[adapters."business.id"]\noptions.probe_bearer_token="' + value + '"\n'
		if _ := remote_probe_literal_credential({'/remote/a.toml': text}, 'business.id') { return error('remote environment substitution accepted') }
	}
	if _ := remote_probe_literal_credential({'/remote/a.toml': literal}, 'missing') { return error('missing credential accepted') }
	if _ := remote_probe_literal_credential({'/remote/a.toml': literal, '/remote/b.toml': literal.replace('private-literal', 'different-private')}, 'business.id') { return error('ambiguous credential accepted') }
}

fn test_remote_discovery_hides_desktop_environment_substitutes_and_tls_paths() ! {
	placeholder := '$' + '{env.HOME}'
	source := '[adapters.business]\noptions.probe_bearer_token="' + placeholder + '"\n[listeners.web.tls]\ncert="/configured/public.pem"\n[[listeners.web.tls.certificates]]\nhosts=["' + placeholder + '","public.test"]\ncert="/configured/public.pem"\n'
	plan := runtime_plan.RuntimePlan{
		listeners: {'web': runtime_plan.ListenerPlan{id: 'web', protocol: 'http', host: '::1', port: 443, tls: runtime_plan.TlsPlan{enabled: true, cert: '/configured/public.pem', certificates: [runtime_plan.TlsCertificatePlan{cert: '/configured/public.pem', hosts: ['desktop-private-value', 'public.test']}]}}}
		adapters: {'business': runtime_plan.AdapterPlan{id: 'business', options: runtime_plan.PlanOptions{strings: {'probe_bearer_token': 'desktop-private-value'}}}}
		pipelines: [runtime_plan.PipelinePlan{ingress: runtime_plan.ResourceRef{domain: .listener, id: 'web'}, egress: runtime_plan.ResourceRef{domain: .adapter, id: 'business'}}]
	}
	value := remote_probe_options(plan, {'/remote/app.toml': source})!
	assert !value.contains('desktop-private-value')
	assert !value.contains('/configured/public.pem')
	assert value.contains('public.test')
	assert value.contains('"auth_refs":[]')
	remote_probe_literal_tls_trust({'/remote/app.toml': source}, 'web')!
	dynamic_path := source.replace('/configured/public.pem', '$' + '{env.CERTFILE}')
	if _ := remote_probe_literal_tls_trust({'/remote/app.toml': dynamic_path}, 'web') { return error('Desktop environment trust path accepted') }
	hidden := remote_probe_options(plan, {'/remote/app.toml': dynamic_path})!
	assert hidden.contains('"listener_certificate_available":false')
	assert !hidden.contains('desktop-private-value')
}
