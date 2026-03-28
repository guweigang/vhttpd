module main

import os

pub struct EmbeddedHostRuntimeConfig {
pub:
	app_entry         string
	module_root       string
	signature_root    string
	signature_include []string
	signature_exclude []string
	runtime_profile   string
	lane_count        int
	max_requests      int
	enable_fs         bool
	enable_process    bool
	enable_network    bool
}

pub struct EmbeddedHostCliOverrides {
pub:
	app_entry_flag         string
	module_root_flag       string
	signature_root_flag    string
	signature_include_flag string
	signature_exclude_flag string
	runtime_profile_flag   string
	lane_count_flag        string
}

fn resolve_embedded_host_runtime_config(args []string, defaults EmbeddedHostRuntimeConfig, cli EmbeddedHostCliOverrides) !EmbeddedHostRuntimeConfig {
	mut app_entry := arg_string_or(args, cli.app_entry_flag, defaults.app_entry).trim_space()
	if app_entry == '' {
		return error('embedded_host_missing_app_entry')
	}
	app_entry = os.abs_path(app_entry)
	if !os.exists(app_entry) {
		return error('embedded_host_app_entry_not_found:${app_entry}')
	}
	mut module_root := arg_string_or(args, cli.module_root_flag, defaults.module_root).trim_space()
	if module_root == '' {
		module_root = os.dir(app_entry)
	} else {
		module_root = os.abs_path(module_root)
	}
	mut signature_root := arg_string_or(args, cli.signature_root_flag, defaults.signature_root).trim_space()
	if signature_root == '' {
		signature_root = module_root
	} else {
		signature_root = os.abs_path(signature_root)
	}
	mut runtime_profile := arg_string_or(args, cli.runtime_profile_flag, defaults.runtime_profile).trim_space()
	if runtime_profile == '' {
		runtime_profile = 'script'
	}
	lane_count_raw := arg_int_or(args, cli.lane_count_flag, defaults.lane_count)
	lane_count := if lane_count_raw > 0 { lane_count_raw } else { 1 }
	signature_include := arg_string_list_or(args, cli.signature_include_flag, defaults.signature_include)
	signature_exclude := arg_string_list_or(args, cli.signature_exclude_flag, defaults.signature_exclude)
	return EmbeddedHostRuntimeConfig{
		app_entry:         app_entry
		module_root:       module_root
		signature_root:    signature_root
		signature_include: signature_include
		signature_exclude: signature_exclude
		runtime_profile:   runtime_profile
		lane_count:        lane_count
		max_requests:      defaults.max_requests
		enable_fs:         defaults.enable_fs
		enable_process:    defaults.enable_process
		enable_network:    defaults.enable_network
	}
}
