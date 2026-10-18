module plugin

import config
import executor
import os
import time

fn owner_config(entry string) map[string]config.PluginConfig {
	app_entry := if entry == '' {
		''
	} else {
		os.join_path(@VMODROOT, 'examples/vjsx/hello-handler.mts')
	}
	max_requests := if entry == 'second.mts' { 2 } else { 1 }
	return {
		'test': config.PluginConfig{ app_entry: app_entry, thread_count: 1, max_requests: max_requests }
	}
}

fn owner_assert_closed(runtime executor.InProcVjsxExecutor) {
	if lane := runtime.select_next_lane() {
		runtime.release_lane(lane.id)
		panic('retired executor still accepts lanes')
	} else {
		assert err.msg() == 'inproc_vjsx_executor_closed'
	}
}

fn owner_assert_error(mut owner PluginState, name string, expected string) {
	if _ := owner.lookup(name) {
		panic('lookup unexpectedly succeeded')
	} else {
		assert err.msg() == expected
	}
}

fn owner_await(done chan bool) {
	select {
		_ := <-done {
		}
		3 * time.second {
			panic('plugin drain did not finish')
		}
	}
}

fn test_unchanged_plugin_reuses_executor_and_changed_plugin_retires_it() {
	mut owner := PluginState{}
	assert owner.publish(owner_config('first.mts')) == 0
	first := owner.lookup('test') or { panic(err) }
	assert owner.publish(owner_config('first.mts')) == 0
	unchanged := owner.lookup('test') or { panic(err) }
	assert voidptr(unchanged.state) == voidptr(first.state)
	id := owner.publish(owner_config('second.mts'))
	assert id > 0
	replacement := owner.lookup('test') or { panic(err) }
	assert voidptr(replacement.state) != voidptr(first.state)
	owner.finish_retirement(id)
	assert owner.retiring.len == 0
	owner_assert_closed(first)
	owner.close()
}

fn test_shutdown_joins_retired_runtime_and_concurrent_closers() {
	mut owner := &PluginState{}
	owner.publish(owner_config('first.mts'))
	old := owner.lookup('test') or { panic(err) }
	lane := old.select_next_lane() or { panic(err) }
	id := owner.publish(owner_config('second.mts'))
	done := chan bool{cap: 3}
	spawn fn [mut owner, id, done] () {
		owner.finish_retirement(id)
		done <- true
	}()
	spawn fn [mut owner, done] () {
		owner.close()
		done <- true
	}()
	deadline := time.now().add(3 * time.second)
	for {
		owner.mu.@lock()
		closed := owner.closed
		owner.mu.unlock()
		if closed { break }
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
	spawn fn [mut owner, done] () {
		owner.close()
		done <- true
	}()
	assert owner.publish(owner_config('late.mts')) == 0
	owner_assert_error(mut owner, 'test', 'plugin_runtime_unavailable:test')
	select {
		_ := <-done {
			panic('shutdown skipped the retired busy runtime')
		}
		else {
		}
	}
	old.release_lane(lane.id)
	for _ in 0 .. 3 { owner_await(done) }
	assert owner.vjsx.len == 0
	assert owner.retiring.len == 0
	owner.close()
}

fn test_lookup_preserves_configuration_errors() {
	mut owner := PluginState{}
	owner_assert_error(mut owner, 'missing', 'plugin_not_configured:missing')
	owner.publish({
		'unsupported': config.PluginConfig{ kind: 'other' }
	})
	owner_assert_error(mut owner, 'unsupported', 'plugin_unsupported_kind:unsupported:other')
	owner.publish(owner_config(''))
	owner_assert_error(mut owner, 'test', 'plugin_runtime_unavailable:test')
	owner.close()
}
