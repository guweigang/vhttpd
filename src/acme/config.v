module acme

import config
import net.urllib
import os

pub const staging_directory = 'https://acme-staging-v02.api.letsencrypt.org/directory'

pub struct Settings {
pub:
	domain       string
	directory    string
	email        string
	state_dir    string
	http_port    int
	renew_before int
	ca_file      string
}

pub fn Settings.resolve(args []string) !Settings {
	domain_flag := config.CliArgs.has(args, '--acme-domain')
	for flag in ['--acme-state-dir', '--acme-directory', '--acme-email', '--acme-http-port',
		'--acme-renew-before-seconds', '--acme-ca-file'] {
		if !domain_flag && config.CliArgs.has(args, flag) {
			return error('${flag} requires --acme-domain')
		}
	}
	if !domain_flag { return Settings{} }
	$if windows {
		return error('ACME state storage is currently supported on Unix')
	}
	domain := config.CliArgs.get(args, '--acme-domain', '').trim_space().to_lower()
	if !valid_domain(domain) { return error('--acme-domain requires a single DNS hostname') }
	directory := config.CliArgs.get(args, '--acme-directory', staging_directory)
	parse_endpoint(directory)!
	ca_file := config.CliArgs.get(args, '--acme-ca-file', '')
	if ca_file != '' && !os.is_file(ca_file) { return error('ACME CA file does not exist') }
	dir := config.CliArgs.get(args, '--acme-state-dir', '').trim_space()
	if dir == '' || dir.starts_with('--') { return error('--acme-state-dir is required') }
	port := config.CliArgs.int_or(args, '--acme-http-port', 80)
	if port < 1 || port > 65535 { return error('invalid --acme-http-port') }
	window := config.CliArgs.int_or(args, '--acme-renew-before-seconds', 30 * 86400)
	if window < 1 || window > 365 * 86400 { return error('invalid --acme-renew-before-seconds') }
	email := config.CliArgs.get(args, '--acme-email', '').trim_space()
	if email != '' && (!email.contains('@') || email.contains_any(' \r\n\t')) {
		return error('invalid --acme-email')
	}
	return Settings{
		domain:       domain
		directory:    directory
		email:        email
		state_dir:    os.abs_path(dir)
		http_port:    port
		renew_before: window
		ca_file:      if ca_file == '' { '' } else { os.abs_path(ca_file) }
	}
}

fn valid_domain(domain string) bool {
	labels := domain.split('.')
	if domain.len > 253 || labels.len < 2 || labels.last().len < 2 { return false }
	for label in labels {
		if label.len < 1 || label.len > 63 || label.starts_with('-') || label.ends_with('-') {
			return false
		}
		for byte in label.bytes() {
			if !((byte >= `a` && byte <= `z`) || (byte >= `0` && byte <= `9`) || byte == `-`) {
				return false
			}
		}
	}
	return labels.last().bytes().any(it >= `a` && it <= `z`)
}

fn parse_endpoint(raw string) !urllib.URL {
	url := urllib.parse(raw)!
	if credentials := url.user {
		if credentials.username != '' || credentials.password_set {
			return error('ACME endpoint must not include credentials')
		}
	}
	if url.host == '' || url.fragment != ''
		|| (url.scheme != 'https' && !(url.scheme == 'http' && url.hostname() in [
			'127.0.0.1',
			'::1',
		])) {
		return error('ACME endpoint requires HTTPS or a local test endpoint')
	}
	return url
}
