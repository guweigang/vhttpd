module main

import provider
import codex
import feishu

struct ProviderRuntimeHub {
mut:
	registry        ProviderHost
	runtime_drivers map[string]string
	runtime_plugins map[string]string
	runtime_capabilities map[string]map[string]string
	instances       provider.ProviderInstanceRegistry = provider.ProviderInstanceRegistry{
		specs: map[string]provider.ProviderInstanceSpec{}
	}
	codex           codex.CodexState
	feishu          feishu.FeishuState
}
