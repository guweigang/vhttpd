module main

import v.vmod

// @VMOD_FILE is embedded at compile time; installed runtimes do not read the
// developer checkout or require v.mod to be present beside the executable.
const vhttpd_version = module_version()

fn module_version() string {
	manifest := vmod.decode(@VMOD_FILE) or { panic('Invalid embedded v.mod: ${err}') }
	if manifest.version == '' { panic('Missing version in embedded v.mod') }
	return manifest.version
}
