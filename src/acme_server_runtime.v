module main

import acme
import server_lifecycle

fn new_acme_runtime(cfg server_lifecycle.ServerRuntimeConfig, settings acme.Settings) !&acme.Runtime {
	if !supports_acme_tls_reload() {
		return error('ACME requires an OpenSSL listener with certificate reload support')
	}
	if !cfg.serve_data_plane || cfg.ssl_cert != '' || cfg.ssl_cert_key != '' {
		return error('ACME requires a data listener without manual TLS certificate paths')
	}
	if cfg.port == settings.http_port || (cfg.admin_enabled && cfg.admin_port == settings.http_port) {
		return error('The ACME HTTP-01 port must differ from the HTTPS and admin ports')
	}
	return acme.Runtime.new(settings)
}

fn start_acme_runtime(mut runtime acme.Runtime, cfg server_lifecycle.ServerRuntimeConfig) !server_lifecycle.ServerRuntimeConfig {
	runtime.start(cfg.host)!
	path := runtime.certificate_path()
	return server_lifecycle.ServerRuntimeConfig{
		...cfg
		ssl_enabled:  true
		ssl_cert:     path
		ssl_cert_key: path
	}
}
