module main

import feishu
import json
import provider

interface ProviderRuntimePluginCaller {
mut:
	provider_runtime_plugin_call(req PluginCallRequest) !PluginCallResponse
}

struct ProviderRuntimeInvocation {
pub:
	provider   string
	action     string
	payload    string
	request_id string
	trace_id   string
	metadata   map[string]string
}

struct ProviderRuntimeActionRequest {
pub:
	provider   string
	action     string
	payload    string
	request_id string
	trace_id   string
	metadata   map[string]string
}

struct ProviderRuntimeActionResponse {
pub:
	ok       bool = true
	provider string
	action   string
	result   string
	error    string
}

struct ProviderRuntimeOverride {
pub:
	driver     string
	plugin     string
	capability string
}

fn (mut hub ProviderRuntimeHub) dispatch_provider_runtime_action(req ProviderRuntimeActionRequest, mut caller ProviderRuntimePluginCaller) ProviderRuntimeActionResponse {
	return hub.dispatch_provider_runtime_action_with_override(req, ProviderRuntimeOverride{}, mut caller)
}

fn (mut hub ProviderRuntimeHub) dispatch_provider_runtime_action_with_override(req ProviderRuntimeActionRequest, override ProviderRuntimeOverride, mut caller ProviderRuntimePluginCaller) ProviderRuntimeActionResponse {
	provider_name := req.provider.trim_space()
	action := req.action.trim_space()
	if provider_name == '' {
		return ProviderRuntimeActionResponse{
			ok:    false
			error: 'provider_runtime_missing_provider'
		}
	}
	if action == '' {
		return ProviderRuntimeActionResponse{
			ok:       false
			provider: provider_name
			error:    'provider_runtime_missing_action:${provider_name}'
		}
	}
	result := hub.provider_runtime_call_with_override(ProviderRuntimeInvocation{
		provider:   provider_name
		action:     action
		payload:    req.payload
		request_id: req.request_id
		trace_id:   req.trace_id
			metadata:   req.metadata.clone()
	}, override, mut caller) or {
		return ProviderRuntimeActionResponse{
			ok:       false
			provider: provider_name
			action:   action
			error:    err.msg()
		}
	}
	return ProviderRuntimeActionResponse{
		ok:       true
		provider: provider_name
		action:   action
		result:   result
	}
}

fn (mut hub ProviderRuntimeHub) provider_runtime_call(inv ProviderRuntimeInvocation, mut caller ProviderRuntimePluginCaller) !string {
	return hub.provider_runtime_call_with_override(inv, ProviderRuntimeOverride{}, mut caller)
}

fn (mut hub ProviderRuntimeHub) provider_runtime_call_with_override(inv ProviderRuntimeInvocation, override ProviderRuntimeOverride, mut caller ProviderRuntimePluginCaller) !string {
	provider_name := inv.provider.trim_space()
	if provider_name == '' {
		return error('provider_runtime_missing_provider')
	}
	driver := provider_runtime_override_driver(provider_name, hub.provider_runtime_driver(provider_name),
		override)
	return match driver {
		'native' { hub.provider_runtime_native_call(inv) }
		'vjsx' { hub.provider_runtime_vjsx_call_with_override(inv, override, mut caller) }
		else { error('provider_runtime_unknown_driver:${provider_name}:${driver}') }
	}
}

fn provider_runtime_override_driver(provider_name string, fallback string, override ProviderRuntimeOverride) string {
	driver := override.driver.trim_space()
	if driver == '' {
		return provider.normalize_runtime_driver(fallback)
	}
	normalized := provider.normalize_runtime_driver(driver)
	if normalized == 'vjsx' && override.plugin.trim_space() == '' {
		return provider.normalize_runtime_driver(fallback)
	}
	if normalized == 'native' && provider_name.trim_space() == '' {
		return provider.normalize_runtime_driver(fallback)
	}
	return normalized
}

fn (mut hub ProviderRuntimeHub) provider_runtime_native_call(inv ProviderRuntimeInvocation) !string {
	return match inv.provider {
		'feishu' { hub.provider_runtime_native_feishu_call(inv) }
		else { error('provider_runtime_native_driver_unavailable:${inv.provider}:${inv.action}') }
	}
}

fn (mut hub ProviderRuntimeHub) provider_runtime_native_feishu_call(inv ProviderRuntimeInvocation) !string {
	return match inv.action {
		'send_message' {
			req := json.decode(feishu.SendMessageRequest, inv.payload)!
			json.encode(hub.feishu_native_send_message(req)!)
		}
		'update_message' {
			req := json.decode(feishu.UpdateMessageRequest, inv.payload)!
			json.encode(hub.feishu_native_update_message(req)!)
		}
		'upload_image' {
			req := json.decode(feishu.UploadImageRequest, inv.payload)!
			json.encode(hub.feishu_native_upload_image(req)!)
		}
		else {
			error('provider_runtime_native_action_unavailable:feishu:${inv.action}')
		}
	}
}

fn (mut hub ProviderRuntimeHub) provider_runtime_vjsx_call(inv ProviderRuntimeInvocation, mut caller ProviderRuntimePluginCaller) !string {
	return hub.provider_runtime_vjsx_call_with_override(inv, ProviderRuntimeOverride{}, mut caller)
}

fn (mut hub ProviderRuntimeHub) provider_runtime_vjsx_call_with_override(inv ProviderRuntimeInvocation, override ProviderRuntimeOverride, mut caller ProviderRuntimePluginCaller) !string {
	plugin_name := provider_runtime_override_plugin(hub.provider_runtime_plugin(inv.provider), override)
	if plugin_name == '' {
		return error('provider_runtime_vjsx_plugin_missing:${inv.provider}')
	}
	mut metadata := inv.metadata.clone()
	metadata['provider'] = inv.provider
	metadata['driver'] = 'vjsx'
	metadata['action'] = inv.action
	resp := caller.provider_runtime_plugin_call(PluginCallRequest{
		plugin:     plugin_name
		capability: provider_runtime_override_capability(hub.provider_runtime_capability(inv.provider,
			inv.action), override)
		op:         inv.action
		request_id: inv.request_id
		trace_id:   inv.trace_id
		payload:    inv.payload
		metadata:   metadata
	})!
	if !resp.ok && resp.error.trim_space() != '' {
		return error('provider_runtime_vjsx_driver_failed:${inv.provider}:${inv.action}:${resp.error}')
	}
	return resp.result
}

fn provider_runtime_override_plugin(fallback string, override ProviderRuntimeOverride) string {
	plugin := override.plugin.trim_space()
	if plugin != '' {
		return plugin
	}
	return fallback.trim_space()
}

fn provider_runtime_override_capability(fallback string, override ProviderRuntimeOverride) string {
	capability := override.capability.trim_space()
	if capability != '' {
		return capability
	}
	return fallback
}
