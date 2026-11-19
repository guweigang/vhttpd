module l10n

import os
import time

fn test_language_resolution_and_persistence() ! {
	assert effective_language('auto', 'zh_Hans_CN.UTF-8') == 'zh-CN'
	assert effective_language('auto', 'en-GB') == 'en'
	assert effective_language('auto', 'fr-FR') == 'en'
	assert effective_language('en', 'zh-CN') == 'en'
	assert effective_language('zh-CN', 'en-US') == 'zh-CN'
	root := os.join_path(os.temp_dir(), 'vhttpd-language-' + os.getpid().str())
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'language.json')
	assert load_preferences(path)!.language == 'auto'
	for language in ['zh-CN', 'en', 'auto'] {
		save_preferences(path, language)!
		assert load_preferences(path)!.language == language
	}
	before := os.read_file(path)!
	save_preferences(path, '../../invalid') or {
		assert os.read_file(path)! == before
		return
	}
	assert false
}

fn test_static_dynamic_and_multiline_messages_preserve_user_values() {
	assert text_in('en','workspace-tab','运行环境') == 'Environment'
	assert text('en','运行环境') == 'Environments'
	assert text_in('zh-CN','workspace-tab','运行环境') == '运行环境'
	assert text_in('en','unknown-context','运行环境') == 'Environments'
	assert text('en', 'MCP 当前目标：bodytest / Bodytest') == 'MCP target: bodytest / Bodytest'
	assert text('en', '1 个房间') == '1 room'
	assert text('en', '2 个房间') == '2 rooms'
	assert text('en', '1 个连接') == '1 connection'
	assert text('en', '0 个连接') == '0 connections'
	assert text('en', '运行环境') == 'Environments'
	assert text('zh-CN', '运行环境') == '运行环境'
	assert text('en', '应用 {0} 已独立安装；环境配置、共享资源及其他应用保留。'.replace('{0}', '运行环境{1}')) == 'App 运行环境{1} installed independently. Environment config, shared resources and other apps are preserved.'
	assert text('en', '目标运行环境：运行环境') == 'Target environment: 运行环境'
	assert text('en', 'vhttpd 0.1.0 · SSH 已连接') == 'vhttpd 0.1.0 · SSH connected'
	assert text('en', '远端 · 运行环境  /  vhttpd 运行环境') == 'Remote · 运行环境 / vhttpd environment'
	assert text('en', '切换预览 · bodytest\n当前：old\n目标：new\n确认后，该环境内全部应用将短暂停机并重启。') == 'Switch preview · bodytest\nCurrent: old\nTarget: new\nAll apps in this environment will briefly stop and restart after confirmation.'
	assert text('en', '未登记的原始服务错误') == '未登记的原始服务错误'
}

fn test_every_pattern_retains_placeholder_positions_and_is_fast_enough_for_refresh() {
	for source, translated in catalog['en'] {
		for i in 0 .. 10 {
			token := '{${i}}'
			assert source.count(token) == translated.count(token), source
		}
	}
	started := time.sys_mono_now()
	for _ in 0 .. 1000 {
		assert text('en', 'vhttpd 0.1.0 · 未连接') == 'vhttpd 0.1.0 · Disconnected'
	}
	assert time.sys_mono_now() - started < 2_000_000_000
}

fn test_composed_lifecycle_states_and_short_navigation_labels() {
 assert text('en','vhttpd · 停止中')=='vhttpd · Stopping'
 assert text('en','vhttpd · 已停止')=='vhttpd · Stopped'
 assert text('en','版本待确认 · 未连接')=='Version unconfirmed · Disconnected'
 assert text('en','返回运行环境')=='Back'
}

fn test_composed_multiline_fingerprint_labels_preserve_fingerprint_value() {
 assert text('en','主机：example.test\n密钥类型：ED25519\n指纹：SHA256:original')=='Host: example.test\nKey type: ED25519\nFingerprint: SHA256:original'
}
