module command

import executor

@[heap]
struct InjectedCommandCalls {
mut:
	calls []string
	fail  bool
}

fn test_required_command_callbacks_preserve_arguments_mutation_and_errors() {
	mut calls := &InjectedCommandCalls{}
	ctx := RuntimeContext{
		route_resolver:        fn [mut calls] (cmd NormalizedCommand) ProviderRouteKind {
			calls.calls << cmd.provider
			return .generic
		}
		route_handler:         fn (_route ProviderRouteKind) ?Handler { return none }
		instance_upsert_apply: fn [mut calls] (provider string, instance string, config string, state string) !InstanceOutcome {
			calls.calls << '${provider}/${instance}/${config}/${state}'
			if calls.fail { return error('injected_apply_failure') }
			return InstanceOutcome{ provider: provider, instance: instance }
		}
		instance_ensure:       fn [mut calls] (provider string, instance string) !InstanceOutcome {
			calls.calls << '${provider}/${instance}'
			return InstanceOutcome{ provider: provider, instance: instance }
		}
	}
	mut exec := CommandExecutor.new(ctx)
	assert ctx.route_resolver(NormalizedCommand{ provider: 'custom' }) == .generic
	assert ctx.route_handler(.generic) == none
	mut snapshot := executor.WebSocketUpstreamCommandActivity{}
	cmd := NormalizedCommand{ kind: 'provider.instance.upsert', provider: 'custom', instance: 'one', config_raw: '{}', desired_state: 'connected' }
	handled, err := exec.execute_instance_command(cmd, mut snapshot)
	assert handled && err == ''
	assert snapshot.status == 'upserted'
	assert calls.calls == ['custom', 'custom/one/{}/connected']
	calls.fail = true
	failed, message := exec.execute_instance_command(cmd, mut snapshot)
	assert failed && message == 'injected_apply_failure'
	assert snapshot.status == 'error'
	assert snapshot.error == message
	result := ctx.instance_ensure('custom', 'two') or { panic(err) }
	assert result.instance == 'two'
	assert calls.calls.last() == 'custom/two'
}
