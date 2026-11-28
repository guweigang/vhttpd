module main

import sync

@[heap]
struct TlsCertificateListener {
	address string
	reload  fn () ! @[required]
}

@[heap]
struct TlsCertificateRuntime {
mut:
	mu        sync.Mutex
	listeners map[string]&TlsCertificateListener
}

// Called by veb once the OpenSSL listener is bound. An App may own several
// listeners, so each callback belongs to its actual serving address.
pub fn (mut app App) register_tls_certificate_reload(address string, reload fn () !) fn () {
	mut runtime := app.lifecycle.tls_certificates
	listener := &TlsCertificateListener{
		address: address
		reload:  reload
	}
	runtime.mu.@lock()
	runtime.listeners[address] = listener
	runtime.mu.unlock()
	if mut manager := app.lifecycle.acme_runtime {
		spawn manager.renew(reload)
	}
	return fn [mut runtime, listener] () {
		runtime.remove_listener(listener)
	}
}

fn (mut runtime TlsCertificateRuntime) remove_listener(listener &TlsCertificateListener) {
	runtime.mu.@lock()
	defer { runtime.mu.unlock() }
	current := runtime.listeners[listener.address] or { return }
	if voidptr(current) == voidptr(listener) {
		runtime.listeners.delete(listener.address)
	}
}

fn (mut runtime TlsCertificateRuntime) listener(address string) !&TlsCertificateListener {
	runtime.mu.@lock()
	defer { runtime.mu.unlock() }
	if address != '' {
		return runtime.listeners[address] or {
			return error_with_code('tls_listener_not_found', 404)
		}
	}
	if runtime.listeners.len == 0 {
		return error_with_code('tls_reload_unavailable', 503)
	}
	if runtime.listeners.len > 1 {
		return error_with_code('tls_listener_required', 400)
	}
	return runtime.listeners.values()[0]
}
