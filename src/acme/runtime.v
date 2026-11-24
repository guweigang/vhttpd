module acme

import admin_state_store
import http_runtime
import json2 as json
import log
import net
import net.http
import os
import sync
import time
import veb
import vjsx

const client_source = $embed_file('@VMODROOT/src/acme/client.js')

struct AccountMetadata {
	directory string
}

struct CertificateValidity {
	not_before i64
	not_after  i64
}

struct Issuance {
	pem        string
	not_before i64
	not_after  i64
}

struct AcmeResponse {
	status      int
	nonce       string
	location    string
	retry_after string
	body        string
}

@[heap]
pub struct Runtime {
pub:
	settings Settings
mut:
	http_owner &http_runtime.Owner = &http_runtime.Owner{}
	challenge  &ChallengeState     = &ChallengeState{}
	mu         sync.Mutex
	stopped    bool
	stop_ch    chan bool
	store      admin_state_store.FileStore
	validity   CertificateValidity
}

@[heap]
struct ChallengeState {
mut:
	mu    sync.Mutex
	token string
	value string
}

pub struct ChallengeContext {
	veb.Context
}

@[heap]
struct ChallengeApp {
	owner  &http_runtime.Owner
	state  &ChallengeState
	domain string
	ready  chan string
}

fn (mut app ChallengeApp) init_server(server &veb.Server) {
	mut owner := app.owner
	owner.publish(server)
}

fn (mut app ChallengeApp) before_accept_loop() {
	mut owner := app.owner
	owner.ready()
	app.ready <- ''
}

@['/.well-known/acme-challenge/:token'; get]
pub fn (app &ChallengeApp) challenge_response(mut ctx ChallengeContext, token string) veb.Result {
	host := (ctx.req.header.get(.host) or { '' }).all_before(':').to_lower()
	if host != app.domain { return ctx.not_found() }
	mut state := app.state
	state.mu.@lock()
	value := if token != '' && token == state.token { state.value } else { '' }
	state.mu.unlock()
	if value == '' { return ctx.not_found() }
	ctx.set_header(.cache_control, 'no-store')
	return ctx.text(value)
}

pub fn Runtime.new(settings Settings) !&Runtime {
	path := settings.state_dir
	if !os.exists(path) {
		os.mkdir_all(path)!
		os.chmod(path, 0o700)!
	}
	if os.is_link(path) || !os.is_dir(path) || (os.stat(path)!.mode & 0o077) != 0 {
		return error('ACME state directory must be private (mode 0700) and must not be a symlink')
	}
	return &Runtime{
		settings: settings
		store:    admin_state_store.FileStore.new(path)!
	}
}

pub fn (runtime &Runtime) instance_pid_path() string {
	return os.join_path(runtime.settings.state_dir, 'instance.pid')
}

pub fn (runtime &Runtime) certificate_path() string {
	return os.join_path(runtime.settings.state_dir, 'acme', 'tls.json')
}

pub fn (mut runtime Runtime) start(host string) ! {
	addr := if host.contains(':') {
		'[${host}]:${runtime.settings.http_port}'
	} else {
		'${host}:${runtime.settings.http_port}'
	}
	mut owner := runtime.http_owner
	mut run := owner.reserve(addr) or { return error('ACME challenge listener unavailable') }
	ready := chan string{cap: 1}
	mut app := &ChallengeApp{
		owner:  owner
		state:  runtime.challenge
		domain: runtime.settings.domain
		ready:  ready
	}
	family := if host.contains(':') { net.AddrFamily.ip6 } else { net.AddrFamily.ip }
	spawn serve_challenges(mut owner, mut run, mut app, host, runtime.settings.http_port, family)
	select {
		failure := <-ready {
			if failure != '' { return error('ACME HTTP-01 listener: ' + failure) }
		}
		5 * time.second {
			return error('ACME HTTP-01 listener did not become ready')
		}
	}
	runtime.prepare_certificate()!
}

fn serve_challenges(mut owner http_runtime.Owner, mut run http_runtime.Run, mut app ChallengeApp, host string, port int, family net.AddrFamily) {
	ready := app.ready
	owner.serve(mut run, fn [mut app, host, port, family, ready] () {
		veb.run_at[ChallengeApp, ChallengeContext](mut app,
			host:                 host
			port:                 port
			family:               family
			show_startup_message: false
		) or { ready <- err.msg() }
	})
}

pub fn (mut runtime Runtime) stop() {
	runtime.mu.@lock()
	if runtime.stopped {
		runtime.mu.unlock()
		return
	}
	runtime.stopped = true
	runtime.stop_ch.close()
	runtime.mu.unlock()
	runtime.http_owner.request_stop()
}

fn (mut runtime Runtime) cancelled() bool {
	runtime.mu.@lock()
	defer { runtime.mu.unlock() }
	return runtime.stopped
}

fn (mut runtime Runtime) wait(delay time.Duration) bool {
	select {
		_ := <-runtime.stop_ch {
			return false
		}
		delay {
		}
	}
	return !runtime.cancelled()
}

fn (mut runtime Runtime) prepare_certificate() ! {
	if os.is_file(runtime.certificate_path()) {
		account := runtime.store.get('acme', 'account')!
		if json.decode[AccountMetadata](account.value)!.directory != runtime.settings.directory {
			return error('ACME state belongs to a different directory')
		}
		entry := runtime.store.get('acme', 'tls')!
		mut session := runtime.open_session()!
		defer { session.close() }
		info := session.call_global_resolved('acmeCertificateInfo', entry.value, runtime.settings.domain, '')!
		defer { info.free() }
		runtime.validity = json.decode[CertificateValidity](info.json_stringify())!
		if runtime.validity.not_after > time.now().unix() { return }
	}
	runtime.issue(none)!
}

fn (mut runtime Runtime) open_session() !vjsx.RuntimeSession {
	mut session := vjsx.try_new_node_runtime_session(vjsx.ContextConfig{}, vjsx.NodeRuntimeConfig{
		fetch:  false
		policy: vjsx.host_policy_safe()
	})!
	ctx := session.context()
	global := ctx.js_global()
	install_callback(global, 'acmeRequest', ctx.js_function(fn [mut runtime, ctx] (args []vjsx.Value) vjsx.Value {
		response := runtime.request(args[0].to_string(), args[1].to_string(),
			args[2].to_string()) or { return ctx.js_throw(err.msg()) }
		return ctx.js_string(json.encode(response))
	}))
	install_callback(global, 'acmeSaveAccount', ctx.js_function(fn [mut runtime, ctx] (args []vjsx.Value) vjsx.Value {
		if runtime.cancelled() { return ctx.js_throw('ACME runtime stopped') }
		runtime.store.put('acme', 'account', args[0].to_string()) or {
			return ctx.js_throw(err.msg())
		}
		return ctx.js_undefined()
	}))
	mut state := runtime.challenge
	install_callback(global, 'acmeChallenge', ctx.js_function(fn [mut state, ctx] (args []vjsx.Value) vjsx.Value {
		state.mu.@lock()
		state.token = args[0].to_string()
		state.value = args[1].to_string()
		state.mu.unlock()
		return ctx.js_undefined()
	}))
	install_callback(global, 'acmeSleep', ctx.js_function(fn [mut runtime, ctx] (args []vjsx.Value) vjsx.Value {
		delay := args[0].to_string().int() * time.millisecond
		if !runtime.wait(delay) { return ctx.js_throw('ACME runtime stopped') }
		return ctx.js_undefined()
	}))
	global.free()
	script := ctx.js_eval(client_source.to_string(), 'vhttpd-acme.js', vjsx.type_global) or {
		session.close()
		return err
	}
	script.free()
	return session
}

fn install_callback(global vjsx.Value, name string, callback vjsx.Value) {
	global.set(name, callback)
	callback.free()
}

fn (mut runtime Runtime) request(method string, url string, body string) !AcmeResponse {
	if runtime.cancelled() { return error('ACME runtime stopped') }
	configured := parse_endpoint(runtime.settings.directory)!
	target := parse_endpoint(url)!
	if target.scheme != configured.scheme || target.host != configured.host {
		return error('ACME request must stay on the configured directory origin')
	}
	http_method := match method {
		'GET' { http.Method.get }
		'HEAD' { http.Method.head }
		'POST' { http.Method.post }
		else { return error('unsupported ACME method') }
	}
	mut headers := http.new_header()
	if http_method == .post { headers.add(.content_type, 'application/jose+json') }
	response := http.fetch(
		url:                  url
		method:               http_method
		header:               headers
		data:                 body
		allow_redirect:       false
		validate:             true
		verify:               runtime.settings.ca_file
		max_retries:          1
		read_timeout:         12 * time.second
		write_timeout:        12 * time.second
		stop_copying_limit:   262144
		stop_receiving_limit: 262144
	)!
	return AcmeResponse{
		status:      response.status_code
		nonce:       response.header.get_custom('replay-nonce') or { '' }
		location:    response.header.get(.location) or { '' }
		retry_after: response.header.get_custom('retry-after') or { '' }
		body:        response.body
	}
}

fn (mut runtime Runtime) issue(reload ?fn () !) ! {
	mut session := runtime.open_session()!
	defer { session.close() }
	account_file := os.join_path(runtime.settings.state_dir, 'acme', 'account.json')
	mut account := ''
	if os.exists(account_file) { account = runtime.store.get('acme', 'account')!.value }
	options := session.context().json_parse(json.encode({
		'directory': runtime.settings.directory
		'domain':    runtime.settings.domain
		'email':     runtime.settings.email
	}))
	defer { options.free() }
	result := session.call_global_resolved('acmeIssue', options, account)!
	defer { result.free() }
	issued := json.decode[Issuance](result.json_stringify())!
	if runtime.cancelled() { return error('ACME runtime stopped') }
	mut previous := ''
	if reload != none { previous = runtime.store.get('acme', 'tls')!.value }
	runtime.store.put('acme', 'tls', issued.pem)!
	if publish := reload {
		publish() or {
			failure := err
			runtime.store.put('acme', 'tls', previous) or {
				return error('ACME TLS reload failed: ${failure}; certificate rollback failed: ${err}')
			}
			return failure
		}
	}
	runtime.validity = CertificateValidity{
		not_before: issued.not_before
		not_after:  issued.not_after
	}
	log.info('[acme] installed certificate for ${runtime.settings.domain}, expires at ${issued.not_after}')
}

pub fn (mut runtime Runtime) renew(reload fn () !) {
	mut retry := i64(0)
	for !runtime.cancelled() {
		lifetime := runtime.validity.not_after - runtime.validity.not_before
		window := if lifetime / 3 < runtime.settings.renew_before {
			lifetime / 3
		} else {
			i64(runtime.settings.renew_before)
		}
		due := runtime.validity.not_after - window - time.now().unix()
		delay := if retry > 0 {
			retry
		} else if due > 0 {
			due
		} else {
			i64(1)
		}
		if !runtime.wait(delay * time.second) { return }
		runtime.issue(reload) or {
			if runtime.cancelled() { return }
			log.warn('[acme] renewal failed for ${runtime.settings.domain}: ${err.msg()}')
			retry = if retry == 0 {
				i64(30)
			} else if retry < 1800 {
				retry * 2
			} else {
				i64(3600)
			}
			continue
		}
		retry = 0
	}
}
