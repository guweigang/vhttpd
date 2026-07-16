module main

import log

struct AssetStartupRuntime {}

fn AssetStartupRuntime.mount(mut app App) {
	if app.assets.enabled && app.assets.root_real != '' {
		app.mount_static_folder_at(app.assets.root_real, app.assets.prefix) or {
			log.error('assets mount failed: ${err}')
		}
	}
}

fn AssetStartupRuntime.install_middleware(mut app App) {
	if app.assets.enabled && app.assets.cache_control.trim_space() != '' {
		assets_prefix_mw := app.assets.prefix
		cache_control := app.assets.cache_control
		app.use(
			handler: fn [assets_prefix_mw, cache_control] (mut ctx Context) bool {
				mut url := ctx.req.url
				if q := url.index('?') {
					url = url[..q]
				}
				if url == assets_prefix_mw || url.starts_with('${assets_prefix_mw}/') {
					ctx.set_custom_header('cache-control', cache_control) or {}
				}
				return true
			}
		)
	}
}

fn AssetStartupRuntime.log_endpoint(app &App) {
	if app.assets.enabled && app.assets.root_real != '' {
		log.info('[vhttpd] Assets: ${app.assets.prefix} -> ${app.assets.root_real}')
	} else {
		log.info('[vhttpd] Assets: disabled')
	}
}
