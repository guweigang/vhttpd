module main

import executor
import json2 as json
import time
import veb

@['/admin/workbench/log-focus'; get]
pub fn (mut app AdminApp) workbench_log_focus_poll(mut ctx Context) veb.Result {
	browser_auth_headers(mut ctx)
	// Host-only polling. Browser sessions cannot establish a host heartbeat.
	if app.admin_host !in ['127.0.0.1','localhost','::1'] || app.admin_token == '' || ctx.req.header.get(.origin) or { '' } != '' || ctx.req.header.get_custom('x-vhttpd-admin-token') or { '' } != app.admin_token {
		ctx.res.set_status(.forbidden)
		return ctx.text('Forbidden')
	}
	mut store := app.workbench_focus
	return ctx.json(store.poll(time.now().unix()))
}

@['/admin/workbench/log-focus'; post]
pub fn (mut app AdminApp) workbench_log_focus_request(mut ctx Context) veb.Result {
	browser_auth_headers(mut ctx)
	if !app.admin_authorized(ctx) { ctx.res.set_status(.forbidden); return ctx.text('Forbidden') }
	body := json.decode[map[string]string](ctx.req.data) or { ctx.res.set_status(.bad_request); return ctx.text('Invalid request') }
	id := body['observation_id']
	listener := body['listener']
	pipeline := body['pipeline']
	mut found := false
	unsafe {
		r := &g_active_runtime_registry
		r.mu.@lock()
		apps := r.apps.clone()
		cfgs := r.cfgs.clone()
		r.mu.unlock()
		for i, runtime in apps {
			cfg := cfgs[i] or { continue }
			if !cfg.serve_data_plane || cfg.plan_listener_id != listener { continue }
			runtime.control_plane.mu.@lock()
			samples := runtime.control_plane.http_observations.requests[pipeline] or { []executor.AdminHttpObservationError{} }
			found = samples.any(it.observation_id == id) || runtime.control_plane.http_observations.errors.any(it.pipeline_id == pipeline && it.observation_id == id)
			runtime.control_plane.mu.unlock()
			break
		}
	}
	if !found { ctx.res.set_status(.not_found); return ctx.text('请求记录已过期，请刷新明细。') }
	mut store := app.workbench_focus
	store.request(id,time.now().unix()) or { ctx.res.set_status(.conflict); return ctx.text(err.msg()) }
	return ctx.json({'accepted':true})
}
