module main

import time

// The default is embedded; packages override it at compile time with the exact
// tag/development version, never with the bundled or remote vhttpd version.
const desktop_base_version = $embed_file('version.txt').to_string().trim_space()
const desktop_version = compiled_desktop_version()

fn compiled_desktop_version() string {
	override := $d('vhttpd_desktop_version', '')
	return if override != '' { override } else { desktop_base_version }
}

// Freeze the release date into the binary; opening About never uses today's date.
fn desktop_release_date() string {
	date := $d('vhttpd_desktop_release_date', @BUILD_DATE)
	parsed := time.parse_iso8601(date + 'T00:00:00Z') or { return date }
	return parsed.custom_format('MMM D, YYYY')
}

fn (app &Workshop) workbench_about_text() string {
	return 'vhttpd desktop ' + desktop_version + '\n' +
		ui_text('发布于 {0}').replace('{0}', desktop_release_date()) +
		'\nPowered by vlang & ui2\n© Bullsoft.org'
}
