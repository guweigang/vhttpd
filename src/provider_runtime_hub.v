module main

import provider
import codex
import feishu

struct ProviderRuntimeHub {
mut:
	registry  ProviderHost
	instances provider.ProviderInstanceRegistry = provider.ProviderInstanceRegistry{
		specs: map[string]provider.ProviderInstanceSpec{}
	}
	codex     codex.CodexState
	feishu    feishu.FeishuState
}
