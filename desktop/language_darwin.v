module main

import macos

fn system_language() string {
	languages := macos.msg_id(macos.get_class('NSLocale'), 'preferredLanguages')
	if macos.msg_u64(languages, 'count') == 0 { return 'en' }
	return macos.utf8_string(macos.msg_id_u64(languages, 'objectAtIndex:', 0))
}
