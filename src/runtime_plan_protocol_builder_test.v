module main

import config
import os
import runtime_plan

fn test_plugin_configs_from_plan_includes_provider_runtime_engine() {
	plan := runtime_plan.RuntimePlan{
		engines:   {
			'feishu_runtime': runtime_plan.EnginePlan{
				id:      'feishu_runtime'
				kind:    'vjsx'
				options: runtime_plan.PlanOptions{
					strings: {
						'entry':           'providers/feishu.mts'
						'module_root':     'providers'
						'build_root':      '.vhttpd/providers'
						'runtime_profile': 'node'
					}
					ints:    {
						'thread_count': 2
						'max_requests': 100
					}
					bools:   {
						'enable_network': true
					}
				}
			}
		}
		providers: {
			'feishu': runtime_plan.ProviderPlan{
				id:     'feishu'
				driver: 'vjsx'
				plugin: 'feishu_runtime'
				engine: runtime_plan.ResourceRef{
					domain: .engine
					id:     'feishu_runtime'
				}
			}
		}
	}

	configs := plugin_configs_from_plan(plan)
	assert 'feishu_runtime' in configs
	assert configs['feishu_runtime'].kind == 'vjsx'
	assert configs['feishu_runtime'].app_entry == 'providers/feishu.mts'
	assert configs['feishu_runtime'].module_root == 'providers'
	assert configs['feishu_runtime'].build_root == '.vhttpd/providers'
	assert configs['feishu_runtime'].runtime_profile == 'node'
	assert configs['feishu_runtime'].thread_count == 2
	assert configs['feishu_runtime'].max_requests == 100
	assert configs['feishu_runtime'].enable_network
}

fn test_protocol_runtime_hub_from_plan_builds_provider_plugin_config() {
	plan := runtime_plan.RuntimePlan{
		engines:   {
			'provider_runtime': runtime_plan.EnginePlan{
				id:      'provider_runtime'
				kind:    'vjsx'
				options: runtime_plan.PlanOptions{
					strings: {
						'entry': 'providers/runtime.mts'
					}
				}
			}
		}
		providers: {
			'custom': runtime_plan.ProviderPlan{
				id:     'custom'
				driver: 'vjsx'
				plugin: 'custom_runtime'
				engine: runtime_plan.ResourceRef{
					domain: .engine
					id:     'provider_runtime'
				}
			}
		}
	}
	hub := ProtocolRuntimeHub.from_plan(config.VhttpdConfig{}, plan, 'web')

	assert 'custom_runtime' in hub.plugins.configs
	assert hub.plugins.configs['custom_runtime'].kind == 'vjsx'
	assert hub.plugins.configs['custom_runtime'].app_entry == 'providers/runtime.mts'
}

fn test_protocol_runtime_plan_update_rebuilds_provider_plugin_runtime() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_provider_plugin_update_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	plugin_file := os.join_path(temp_dir, 'provider-runtime.mts')
	os.write_file(plugin_file, 'export default {}') or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	mut hub := ProtocolRuntimeHub.from_plan(config.VhttpdConfig{}, runtime_plan.RuntimePlan{},
		'web')
	plan := runtime_plan.RuntimePlan{
		engines:   {
			'provider_runtime': runtime_plan.EnginePlan{
				id:      'provider_runtime'
				kind:    'vjsx'
				options: runtime_plan.PlanOptions{
					strings: {
						'entry': plugin_file
					}
				}
			}
		}
		providers: {
			'custom': runtime_plan.ProviderPlan{
				id:     'custom'
				driver: 'vjsx'
				plugin: 'custom_runtime'
				engine: runtime_plan.ResourceRef{
					domain: .engine
					id:     'provider_runtime'
				}
			}
		}
	}

	hub.apply_plan_update(protocol_runtime_plan_update_from_plan(plan, 'web'))

	assert 'custom_runtime' in hub.plugins.configs
	assert 'custom_runtime' in hub.plugins.vjsx
	runtime := hub.plugins.vjsx['custom_runtime'] or { panic('missing provider plugin runtime') }
	runtime.close()
}

fn test_protocol_runtime_plan_update_switches_provider_plugin_runtime() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_provider_plugin_switch_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	old_plugin_file := os.join_path(temp_dir, 'provider-runtime-old.mts')
	new_plugin_file := os.join_path(temp_dir, 'provider-runtime-new.mts')
	os.write_file(old_plugin_file, 'export default {}') or { panic(err) }
	os.write_file(new_plugin_file, 'export default {}') or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	old_plan := runtime_plan.RuntimePlan{
		engines:   {
			'old_provider_runtime': runtime_plan.EnginePlan{
				id:      'old_provider_runtime'
				kind:    'vjsx'
				options: runtime_plan.PlanOptions{
					strings: {
						'entry': old_plugin_file
					}
				}
			}
		}
		providers: {
			'custom': runtime_plan.ProviderPlan{
				id:     'custom'
				driver: 'vjsx'
				plugin: 'old_custom_runtime'
				engine: runtime_plan.ResourceRef{
					domain: .engine
					id:     'old_provider_runtime'
				}
			}
		}
	}
	new_plan := runtime_plan.RuntimePlan{
		engines:   {
			'new_provider_runtime': runtime_plan.EnginePlan{
				id:      'new_provider_runtime'
				kind:    'vjsx'
				options: runtime_plan.PlanOptions{
					strings: {
						'entry': new_plugin_file
					}
				}
			}
		}
		providers: {
			'custom': runtime_plan.ProviderPlan{
				id:     'custom'
				driver: 'vjsx'
				plugin: 'new_custom_runtime'
				engine: runtime_plan.ResourceRef{
					domain: .engine
					id:     'new_provider_runtime'
				}
			}
		}
	}
	mut hub := ProtocolRuntimeHub.from_plan(config.VhttpdConfig{}, old_plan, 'web')
	defer {
		for _, runtime in hub.plugins.vjsx {
			runtime.close()
		}
	}

	assert 'old_custom_runtime' in hub.plugins.configs
	assert 'old_custom_runtime' in hub.plugins.vjsx

	hub.apply_plan_update(protocol_runtime_plan_update_from_plan(new_plan, 'web'))

	assert 'old_custom_runtime' !in hub.plugins.configs
	assert 'old_custom_runtime' !in hub.plugins.vjsx
	assert 'new_custom_runtime' in hub.plugins.configs
	assert 'new_custom_runtime' in hub.plugins.vjsx
	assert hub.plugins.configs['new_custom_runtime'].app_entry == new_plugin_file
}

fn test_plugin_configs_from_plan_includes_provider_action_adapter_runtime_engine() {
	plan := runtime_plan.RuntimePlan{
		engines:  {
			'adapter-runtime': runtime_plan.EnginePlan{
				id:      'adapter-runtime'
				kind:    'vjsx'
				options: runtime_plan.PlanOptions{
					strings: {
						'entry': 'providers/adapter.mts'
					}
				}
			}
		}
		adapters: {
			'provider-send': runtime_plan.AdapterPlan{
				id:      'provider-send'
				kind:    'provider-action'
				options: runtime_plan.PlanOptions{
					strings: {
						'runtime_plugin': 'adapter-provider-runtime'
						'runtime_engine': 'engine:adapter-runtime'
					}
				}
			}
		}
	}

	configs := plugin_configs_from_plan(plan)

	assert 'adapter-provider-runtime' in configs
	assert configs['adapter-provider-runtime'].kind == 'vjsx'
	assert configs['adapter-provider-runtime'].app_entry == 'providers/adapter.mts'
}
