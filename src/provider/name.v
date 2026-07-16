module provider

pub struct ProviderName {}

pub fn ProviderName.feishu() string {
	return 'feishu'
}

pub fn ProviderName.codex() string {
	return 'codex'
}

pub fn ProviderName.ollama() string {
	return 'ollama'
}

pub fn ProviderName.db() string {
	return 'db'
}

pub fn ProviderName.cache() string {
	return 'cache'
}

pub fn ProviderName.default_instance(name string) string {
	return match name {
		'feishu', 'codex', 'ollama', 'db', 'cache' { 'main' }
		else { '' }
	}
}
