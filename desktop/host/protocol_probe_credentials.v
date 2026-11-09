module host

import runtime_plan
import toml

struct RemoteProbeCredentials {
mut:
	values map[string]string
	failures map[string]string
	certificate_hosts map[string][]string
	tls_path_failures map[string]bool
}

// Read remote declarations without applying Desktop environment expansion.
// No paths, values or expressions appear in errors or discovery results.
fn remote_probe_credentials(sources map[string]string) !RemoteProbeCredentials {
	mut result := RemoteProbeCredentials{}
	for _, text in sources {
		doc := toml.parse_text(text) or { return error('remote_probe_credential_configuration_unavailable') }
		root := doc.to_any().as_map()
		if entries := root['listeners'] {
			for id, listener in entries.as_map() {
				tls := listener.as_map()['tls'] or { continue }
				if cert := tls.as_map()['cert'] {
					if cert.string().contains('$' + '{') { result.tls_path_failures[id] = true }
				}
				if certificates := tls.as_map()['certificates'] {
					mut names := result.certificate_hosts[id] or { []string{} }
					for certificate in certificates.array() {
						if cert := certificate.as_map()['cert'] {
							if cert.string().contains('$' + '{') { result.tls_path_failures[id] = true }
						}
						if hosts := certificate.as_map()['hosts'] {
							for name in hosts.array() {
								if name is string && !name.contains('$' + '{') && name !in names { names << name }
							}
						}
					}
					result.certificate_hosts[id] = names
				}
			}
		}
		adapters := root['adapters'] or { continue }
		for id, adapter in adapters.as_map() {
			options := adapter.as_map()['options'] or { continue }
			value := options.as_map()['probe_bearer_token'] or { continue }
			if value !is string {
				result.failures[id] = 'remote_probe_credential_unavailable'
				continue
			}
			token := value.string()
			if token == '' || token.contains('$' + '{') {
				result.failures[id] = 'remote_probe_credential_requires_literal_value'
				continue
			}
			if previous := result.values[id] {
				if previous != token { result.failures[id] = 'remote_probe_credential_ambiguous' }
			}
			result.values[id] = token
		}
	}
	return result
}

// Until a remote-owned resolver exists, the dedicated credential must be literal
// in its actual remote source. Never transmit a Desktop environment substitute.
fn remote_probe_literal_credential(sources map[string]string, reference string) !string {
	credentials := remote_probe_credentials(sources)!
	if failure := credentials.failures[reference] { return error(failure) }
	return credentials.values[reference] or { return error('remote_probe_credential_unavailable') }
}

fn remote_probe_literal_tls_trust(sources map[string]string, listener string) ! {
	credentials := remote_probe_credentials(sources)!
	if credentials.tls_path_failures[listener] { return error('remote_probe_tls_trust_requires_literal_path') }
}

fn remote_probe_options(plan runtime_plan.RuntimePlan, sources map[string]string) !string {
	credentials := remote_probe_credentials(sources)!
	mut adapters := plan.adapters.clone()
	for id, adapter in plan.adapters {
		if id in credentials.values && id !in credentials.failures { continue }
		mut strings := adapter.options.strings.clone()
		strings.delete('probe_bearer_token')
		adapters[id] = runtime_plan.AdapterPlan{...adapter, options: runtime_plan.PlanOptions{...adapter.options, strings: strings}}
	}
	mut listeners := plan.listeners.clone()
	for id, listener in plan.listeners {
		mut certificates := []runtime_plan.TlsCertificatePlan{}
		for certificate in listener.tls.certificates {
			certificates << runtime_plan.TlsCertificatePlan{...certificate, cert: if credentials.tls_path_failures[id] { '' } else { certificate.cert }, hosts: certificate.hosts.filter(it in credentials.certificate_hosts[id])}
		}
		listeners[id] = runtime_plan.ListenerPlan{...listener, tls: runtime_plan.TlsPlan{...listener.tls, cert: if credentials.tls_path_failures[id] { '' } else { listener.tls.cert }, certificates: if credentials.tls_path_failures[id] { []runtime_plan.TlsCertificatePlan{} } else { certificates }}}
	}
	return protocol_probe_options(runtime_plan.RuntimePlan{...plan, adapters: adapters, listeners: listeners}, listeners.keys())
}
