module main

import codex
import command

fn codex_owner_seed() codex.ProviderRuntime {
	return codex.ProviderRuntime{
		connected:         true
		initialized:       true
		thread_id:         'thread'
		active_stream_id:  'stream'
		stream_map:        {
			'stream': [codex.CodexTarget{ platform: 'feishu', message_id: 'original' }]
		}
		pending_rpcs:      {
			7: codex.PendingRpc{ method: 'read', stream_id: 'stream' }
		}
		thread_stream_map: {
			'thread': 'stream'
		}
		read_fallbacks:    {
			'stream': codex.ReadFallback{ token: 1, stream_id: 'stream', thread_id: 'thread' }
		}
	}
}

fn test_codex_snapshots_and_published_inputs_own_their_mutable_containers() {
	mut state := codex.CodexState{}
	for instance in ['main', 'secondary'] {
		mut supplied := codex_owner_seed()
		state.update(instance, supplied)
		// Publication cannot retain containers that the caller can still mutate.
		supplied.clear_stream_targets('stream')
		assert state.snapshot(instance).stream_targets('stream').len == 1
		mut held := state.snapshot(instance)
		mut changed := state.snapshot(instance)
		changed.stream_map['stream'][0] = codex.CodexTarget{ platform: 'feishu', message_id: 'changed' }
		changed.pending_rpcs.delete(7)
		changed.thread_stream_map.delete('thread')
		changed.read_fallbacks.delete('stream')
		assert state.snapshot(instance).stream_targets('stream')[0].message_id == 'original'
		assert state.snapshot(instance).pending_rpcs.len == 1
		state.update(instance, changed)
		assert held.stream_targets('stream')[0].message_id == 'original'
		assert held.pending_rpcs.len == 1
		assert held.thread_stream_map['thread'] == 'stream'
		assert held.read_fallbacks['stream'].token == 1
		held.clear_stream_targets('stream')
		assert state.snapshot(instance).stream_targets('stream')[0].message_id == 'changed'
	}
}

fn test_codex_ensure_instance_returns_a_detached_observation() {
	mut app := &App{}
	for instance in ['main', 'secondary'] {
		app.providers.codex.update(instance, codex_owner_seed())
		mut snapshot := app.codex_runtime_ensure_instance(instance)
		snapshot.clear_stream_targets('stream')
		snapshot.pending_rpcs.clear()
		snapshot.thread_stream_map.clear()
		snapshot.read_fallbacks.clear()
		live := app.providers.codex.snapshot(instance)
		assert live.current_stream_id() == 'stream'
		assert live.stream_targets('stream').len == 1
		assert live.pending_rpcs.len == 1
		assert live.thread_stream_map.len == 1
		assert live.read_fallbacks.len == 1
	}
}

fn test_codex_concurrent_rpc_routing_and_frame_mutations_do_not_overwrite_each_other() {
	mut app := &App{}
	ids := chan int{cap: 512}
	mut workers := []thread{}
	for worker in 0 .. 32 {
		workers << spawn fn [mut app, worker, ids] () {
			for index in 0 .. 16 {
				id := app.codex_next_rpc_id('secondary')
				stream := 'stream-${worker}-${index}'
				app.codex_remember_pending_rpc('secondary', id, codex.PendingRpc{ stream_id: stream })
				app.codex_bind_stream_to_thread('secondary', stream, stream)
				app.codex_add_stream_target('secondary', stream, codex.CodexTarget{ platform: 'feishu', message_id: stream })
				app.codex_schedule_read_fallback('secondary', stream, stream)
				app.codex_note_frame_received('secondary')
				ids <- id
			}
		}()
	}
	workers.wait()
	mut seen := map[int]bool{}
	for _ in 0 .. 512 {
		id := <-ids
		assert id !in seen
		seen[id] = true
	}
	held := app.providers.codex.snapshot('secondary')
	assert held.rpc_id_counter == 512
	assert held.received_frames == 512
	assert held.pending_rpcs.len == 512
	assert held.thread_stream_map.len == 512
	assert held.stream_map.len == 512
	assert held.read_fallback_seq == 512
	assert held.read_fallbacks.len == 512
	mut tokens := map[int]bool{}
	for _, fallback in held.read_fallbacks {
		assert fallback.token !in tokens
		tokens[fallback.token] = true
	}
	mut cleaners := []thread{}
	for worker in 0 .. 32 {
		cleaners << spawn fn [mut app, worker] () {
			for index in 0 .. 16 {
				id := worker * 16 + index + 1
				pending, found := app.codex_take_pending_rpc('secondary', id)
				assert found
				app.codex_clear_stream_targets('secondary', pending.stream_id)
				app.codex_clear_thread_binding('secondary', pending.stream_id)
				app.codex_clear_read_fallback('secondary', pending.stream_id)
			}
		}()
	}
	cleaners.wait()
	live := app.providers.codex.snapshot('secondary')
	assert live.pending_rpcs.len == 0
	assert live.stream_map.len == 0
	assert live.thread_stream_map.len == 0
	assert live.read_fallbacks.len == 0
	assert held.pending_rpcs.len == 512
	assert held.stream_map.len == 512
	assert held.thread_stream_map.len == 512
	assert held.read_fallbacks.len == 512
	assert app.providers.codex.snapshot('main').rpc_id_counter == 0
}

fn test_codex_concurrent_lifecycle_and_frame_updates_preserve_all_counters() {
	mut app := &App{}
	mut workers := []thread{}
	for _ in 0 .. 16 {
		workers << spawn fn [mut app] () {
			for _ in 0 .. 16 {
				app.codex_provider_on_connecting('main')
				app.codex_provider_on_connected('main', 'ws://example.invalid')
				app.codex_note_frame_received('main')
				app.codex_provider_on_disconnected('main', 'test')
			}
		}()
	}
	workers.wait()
	live := app.providers.codex.snapshot('main')
	assert live.connect_attempts == 256
	assert live.connect_successes == 256
	assert live.received_frames == 256
	assert !live.connected
	assert !live.initialized
}

fn test_codex_turn_preparation_rejects_before_allocating_routes_or_pending_rpc() {
	mut app := &App{}
	app.providers.codex.update('main', codex.ProviderRuntime{ connected: true, initialized: true })
	prepared := app.codex_prepare_turn(command.NormalizedCommand{ correlation: command.CommandCorrelation{ stream_id: 'rejected' }, response_message_id: 'message' })
	assert prepared.failure == 'no active codex thread available for turn'
	live := app.providers.codex.snapshot('main')
	assert live.rpc_id_counter == 0
	assert live.pending_rpcs.len == 0
	assert live.stream_map.len == 0
	assert live.current_stream_id() == ''
}

fn test_codex_turn_preparation_publishes_one_coherent_route_and_rpc() {
	mut app := &App{}
	app.providers.codex.update('main', codex_owner_seed())
	held := app.providers.codex.snapshot('main')
	prepared := app.codex_prepare_turn(command.NormalizedCommand{
		correlation:         command.CommandCorrelation{ stream_id: 'new-stream', thread_id: 'explicit-thread' }
		response_message_id: 'new-message'
	})
	assert prepared.failure == ''
	assert prepared.thread_id == 'explicit-thread'
	live := app.providers.codex.snapshot('main')
	assert live.current_stream_id() == 'new-stream'
	assert live.thread_stream_map['explicit-thread'] == 'new-stream'
	assert live.pending_rpcs[prepared.id].stream_id == 'new-stream'
	assert live.stream_targets('new-stream')[0].message_id == 'new-message'
	assert held.current_stream_id() == 'stream'
	assert 'new-stream' !in held.stream_map
}

fn test_codex_parallel_turns_expose_coherent_detached_route_and_rpc_snapshots() {
	mut app := &App{}
	app.providers.codex.update('main', codex.ProviderRuntime{ connected: true, initialized: true, thread_id: 'base' })
	mut workers := []thread{}
	for worker in 0 .. 16 {
		workers << spawn fn [mut app, worker] () {
			for index in 0 .. 16 {
				stream := 'turn-${worker}-${index}'
				prepared := app.codex_prepare_turn(command.NormalizedCommand{
					correlation:         command.CommandCorrelation{ stream_id: stream, thread_id: stream }
					response_message_id: stream
				})
				assert prepared.failure == ''
				held := app.providers.codex.snapshot('main')
				assert held.thread_stream_map[held.thread_id] == held.active_stream_id
				assert held.pending_rpcs[held.rpc_id_counter].stream_id == held.active_stream_id
				assert held.stream_targets(held.active_stream_id)[0].message_id == held.active_stream_id
			}
		}()
	}
	workers.wait()
	live := app.providers.codex.snapshot('main')
	assert live.rpc_id_counter == 256
	assert live.pending_rpcs.len == 256
	assert live.stream_map.len == 256
}
