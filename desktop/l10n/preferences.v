module l10n

import json2 as json
import os

pub struct Preferences {
pub:
	language string = 'auto'
}

pub fn valid_preference(value string) bool { return value in ['auto', 'zh-CN', 'en'] }

pub fn effective_language(preference string, system string) string {
	if preference == 'zh-CN' || preference == 'en' { return preference }
	return if system.to_lower().replace('_', '-').starts_with('zh') { 'zh-CN' } else { 'en' }
}

pub fn load_preferences(path string) !Preferences {
	if !os.exists(path) { return Preferences{} }
	pref := json.decode[Preferences](os.read_file(path)!)!
	if !valid_preference(pref.language) { return error('Invalid language preference') }
	return pref
}

pub fn save_preferences(path string, preference string) ! {
	if !valid_preference(preference) { return error('Invalid language preference') }
	os.mkdir_all(os.dir(path))!
	temporary := path + '.tmp-' + os.getpid().str()
	defer { os.rm(temporary) or {} }
	os.write_file(temporary, json.encode(Preferences{ language: preference }))!
	$if !windows {
		os.chmod(temporary, 0o600)!
	}
	os.mv(temporary, path)!
}
