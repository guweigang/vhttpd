module provider

@[heap]
struct InjectedProviderCalls {
mut:
	rows []string
}

fn test_provider_lifecycle_context_invokes_explicit_callbacks() {
	mut calls := &InjectedProviderCalls{}
	ctx := RuntimeContext{
		snapshot: fn [mut calls] () string { return '${calls.rows.len}' }
		start:    fn [mut calls] () ! { calls.rows << 'start' }
		stop:     fn [mut calls] () ! {
			calls.rows << 'stop'
			return error('injected_stop_failure')
		}
		emit:     fn [mut calls] (kind string, fields map[string]string) {
			calls.rows << '${kind}:${fields['id'] or { '' }}'
		}
	}
	ctx.start() or { panic(err) }
	ctx.emit('event', {
		'id': 'one'
	})
	assert ctx.snapshot() == '2'
	mut failed := false
	ctx.stop() or {
		assert err.msg() == 'injected_stop_failure'
		failed = true
	}
	assert failed
	assert calls.rows == ['start', 'event:one', 'stop']
	noop := RuntimeContext.noop()
	noop.start() or { panic(err) }
	noop.stop() or { panic(err) }
	noop.emit('ignored', {})
	assert noop.snapshot() == '{}'
}

fn test_provider_dispatch_uses_injected_configuration_and_url_errors() {
	ctx := RuntimeDispatchContext{
		instances_fn:         fn (name string) []string {
			return if name == 'codex' { ['one'] } else { []string{} }
		}
		upstream_enabled_fn:  fn (name string, instance string) bool {
			return name == 'codex' && instance == 'one'
		}
		bootstrap_enabled_fn: fn (_name string) bool { return false }
		ready_fn:             fn (name string) bool { return name == 'feishu' }
		pull_url_fn:          fn (_name string, _instance string) !string {
			return error('injected_url_failure')
		}
	}
	assert ctx.gateway_count() == 1
	assert ctx.upstream_provider_names() == ['codex']
	assert ctx.capabilities()['feishu_runtime']
	launches := ctx.upstream_launches()
	assert launches.len == 1
	assert launches[0].instance == 'one'
	assert launches[0].url == ''
}
