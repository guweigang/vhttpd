module main

import jsonutils

fn vhttpd_has_any_top_level_key(raw string, keys []string) bool {
	return jsonutils.has_any_top_level_key(raw, keys)
}

fn vhttpd_has_top_level_key(raw string, key string) bool {
	return jsonutils.has_top_level_key(raw, key)
}
