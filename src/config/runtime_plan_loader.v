module config

import os
import runtime_plan
import toml

const legacy_config_version = 1
const v2_config_version = 2

pub fn detect_config_version(text string) !int {
	doc := toml.parse_text(text)!
	if version_any := doc.value_opt('version') {
		return version_any.int()
	}
	return legacy_config_version
}

pub fn load_runtime_plan(args []string) !runtime_plan.RuntimePlan {
	config_path := config_path_from_args(args)
	if config_path == '' {
		return compile_v1_runtime_plan(default_vhttpd_config())
	}
	return load_runtime_plan_file(config_path)
}

pub fn load_runtime_plan_or_compile_config(args []string, cfg VhttpdConfig) !runtime_plan.RuntimePlan {
	config_path := config_path_from_args(args)
	if config_path == '' {
		return compile_v1_runtime_plan(cfg)
	}
	return load_runtime_plan_file(config_path)
}

pub fn load_runtime_plan_file(config_path string) !runtime_plan.RuntimePlan {
	text := os.read_file(config_path)!
	version := detect_config_version(text)!
	if version == v2_config_version {
		cfg := toml.decode[V2Config](text)!
		return compile_v2_runtime_plan(cfg, os.abs_path(config_path), false)
	}
	if version == legacy_config_version {
		cfg := load_vhttpd_config(['--config', config_path])!
		return compile_v1_runtime_plan(cfg)
	}
	return error('runtime_plan_unsupported_version:${version}')
}
