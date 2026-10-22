module main

import config
import os
import runtime_plan
import time

fn test_plugin_reload_releases_app_lock_before_waiting_for_active_lane() {
	mut app := &App{}
	app.protocols.plugins.publish({
		'test': config.PluginConfig{ app_entry: os.join_path(@VMODROOT, 'examples/vjsx/hello-handler.mts'), thread_count: 1 }
	})
	old := app.protocols.plugins.lookup('test') or { panic(err) }
	lane := old.select_next_lane() or { panic(err) }
	done := chan bool{cap: 1}
	spawn fn [mut app, done] () {
		app.apply_lightweight_runtime_plan(runtime_plan.RuntimePlan{}) or { panic(err) }
		done <- true
	}()
	// The old generation has been detached, while its active call still owns a lane.
	deadline := time.now().add(3 * time.second)
	for {
		_ := app.protocols.plugins.lookup('test') or { break }
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
	callback := chan bool{cap: 1}
	spawn fn [mut app, callback] () {
		app.mu.@lock()
		app.mu.unlock()
		callback <- true
	}()
	select {
		_ := <-callback {
		}
		3 * time.second {
			panic('plugin retirement held App.mu while waiting for its active lane')
		}
	}
	select {
		_ := <-done {
			panic('reload returned before draining its old executor')
		}
		else {
		}
	}
	old.release_lane(lane.id)
	select {
		_ := <-done {
		}
		3 * time.second {
			panic('reload did not finish after releasing the lane')
		}
	}
	if active := old.select_next_lane() {
		old.release_lane(active.id)
		panic('retired executor still accepts lanes')
	} else {
		assert err.msg() == 'inproc_vjsx_executor_closed'
	}
	app.close_all_plugins()
}
