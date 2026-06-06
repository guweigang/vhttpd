module command

// ProviderRouteKind classifies upstream routing targets for the command executor.
pub enum ProviderRouteKind {
	codex
	feishu
	openai
	ollama
	generic
}

pub fn (route_kind ProviderRouteKind) snapshot_value() string {
	return match route_kind {
		.codex { 'codex' }
		.feishu { 'feishu' }
		.openai { 'openai' }
		.ollama { 'ollama' }
		.generic { 'generic' }
	}
}

// CommandMatcherKind describes how a command matcher compares against a command type.
pub enum CommandMatcherKind {
	prefix
	exact
}

pub struct CommandMatcher {
pub:
	kind  CommandMatcherKind
	value string
}

pub fn (m CommandMatcher) matches(command_type string) bool {
	if m.value.trim_space() == '' {
		return false
	}
	return match m.kind {
		.prefix { command_type.starts_with(m.value) }
		.exact { command_type == m.value }
	}
}
