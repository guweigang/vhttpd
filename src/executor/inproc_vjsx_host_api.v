module executor

import vjsx

struct InProcVjsxHostApi {}

fn InProcVjsxHostApi.install_http_facade(mut ctx vjsx.Context) ! {
	facade_source := inproc_vjsx_http_facade_source.to_string()
	eval_res := ctx.eval(facade_source) or {
		eprintln('[vhttpd] ERROR: js_bootstrap eval failed: ${err.msg()}')
		return err
	}
	defer { eval_res.free() }

	ctx.end()
}

fn InProcVjsxHostApi.builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return vjsx.host_object(vjsx.HostObjectField{
		name:  'emit'
		value: InProcVjsxHostApi.emit_builder(mut state, idx)
	}, vjsx.HostObjectField{
		name:  'snapshot'
		value: InProcVjsxHostApi.snapshot_builder(state, idx)
	}, vjsx.HostObjectField{
		name:  'sessionStore'
		value: InProcVjsxHostApi.session_store_builder(mut state, idx)
	}, vjsx.HostObjectField{
		name:  'config'
		value: InProcVjsxHostApi.config_builder(mut state, idx)
	}, vjsx.HostObjectField{
		name:  'readTextFile'
		value: InProcVjsxHostApi.read_text_file_builder(mut state, idx)
	}, vjsx.HostObjectField{
		name:  'findCodexSessionPath'
		value: InProcVjsxHostApi.find_codex_session_builder(mut state, idx)
	}, vjsx.HostObjectField{
		name:  'httpFetch'
		value: InProcVjsxHostApi.http_fetch_builder(mut state, idx)
	}, vjsx.HostObjectField{
		name:  'bridgeDispatch'
		value: InProcVjsxHostApi.bridge_dispatch_builder(mut state, idx)
	}, vjsx.HostObjectField{
		name:  'websocketDispatch'
		value: InProcVjsxHostApi.websocket_dispatch_builder(mut state, idx)
	})
}

fn InProcVjsxHostApi.install(mut ctx vjsx.Context, mut state VjsxExecutorState, idx int) {
	ctx.install_host_api(vjsx.HostApiConfig{
		globals: [
			vjsx.HostGlobalBinding{
				name:  'vhttpdHost'
				value: InProcVjsxHostApi.builder(mut state, idx)
			},
		]
	})
}
