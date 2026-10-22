module relay

fn session_owner_endpoint(id string, session_id string) RelayEndpoint {
	return RelayEndpoint{
		id:         id
		channel_id: 'channel-${id}'
		session_id: session_id
		link_id:    'link'
		role:       'producer'
		trace_id:   'trace'
	}
}

fn append_session_owner_frames(mut registry SessionRegistry, start chan bool, worker int, limit int, results chan int) {
	_ := <-start
	mut accepted := 0
	for i in 0 .. 200 {
		registry.buffer_pending('session', 'link', new_frame(.data, '${worker}-${i}', 'trace'), limit) or { continue }
		accepted++
	}
	results <- accepted
}

fn test_concurrent_session_producers_preserve_every_accepted_frame() {
	mut registry := &SessionRegistry{}
	// Keep the session alive while workers update the same pending queue.
	registry.open_endpoint(session_owner_endpoint('endpoint', 'session')) or { panic(err) }
	start := chan bool{cap: 4}
	results := chan int{cap: 4}
	for worker in 0 .. 4 {
		spawn append_session_owner_frames(mut registry, start, worker, 1000, results)
	}
	for _ in 0 .. 4 { start <- true }
	mut accepted := 0
	for _ in 0 .. 4 { accepted += <-results }
	frames := registry.drain_pending('session', 'link')
	assert accepted == 800
	assert frames.len == accepted
	mut ids := map[string]bool{}
	for frame in frames { ids[frame.id] = true }
	assert ids.len == accepted
	assert registry.close_endpoint('session', 'endpoint')
	assert build_session_snapshots(registry).len == 0
}

fn test_concurrent_session_admission_respects_shared_capacity() {
	mut registry := &SessionRegistry{}
	registry.open_endpoint(session_owner_endpoint('endpoint', 'session')) or { panic(err) }
	start := chan bool{cap: 4}
	results := chan int{cap: 4}
	for worker in 0 .. 4 {
		spawn append_session_owner_frames(mut registry, start, worker, 17, results)
	}
	for _ in 0 .. 4 { start <- true }
	mut accepted := 0
	for _ in 0 .. 4 { accepted += <-results }
	assert accepted == 17
	assert registry.drain_pending('session', 'link').len == 17
}

fn route_session_owner_races(mut registry SessionRegistry, start chan bool, outcomes chan SessionRouteOutcome) {
	for i in 0 .. 500 {
		_ := <-start
		outcomes <- route_session_frame(mut registry, 'session-${i}', 'link', 'source', 'producer', new_frame(.data, 'frame-${i}', 'trace'), 1)
	}
}

fn open_session_owner_races(mut registry SessionRegistry, start chan bool, drained chan int) {
	for i in 0 .. 500 {
		_ := <-start
		frames := open_session_endpoint_and_drain(mut registry, session_owner_endpoint('endpoint', 'session-${i}')) or { panic(err) }
		drained <- frames.len
	}
}

fn test_session_open_and_route_handoff_never_strands_buffered_frames() {
	mut registry := &SessionRegistry{}
	start_route := chan bool{cap: 1}
	start_open := chan bool{cap: 1}
	outcomes := chan SessionRouteOutcome{cap: 1}
	drained := chan int{cap: 1}
	spawn route_session_owner_races(mut registry, start_route, outcomes)
	spawn open_session_owner_races(mut registry, start_open, drained)
	mut stranded := 0
	for i in 0 .. 500 {
		start_route <- true
		start_open <- true
		outcome := <-outcomes
		count := <-drained
		assert outcome.action in [.deliver, .buffered]
		assert count == if outcome.action == .buffered { 1 } else { 0 }
		stranded += registry.drain_pending('session-${i}', 'link').len
		assert registry.targets('session-${i}', 'link', 'producer', '').len == 1
	}
	assert stranded == 0
}

fn test_session_snapshot_and_targets_follow_concurrent_endpoint_rebinding() {
	mut registry := &SessionRegistry{}
	registry.open_endpoint(session_owner_endpoint('endpoint', 'session')) or { panic(err) }
	writer := spawn fn [mut registry] () {
		for i in 0 .. 500 {
			registry.open_endpoint(RelayEndpoint{
				...session_owner_endpoint('endpoint', 'session')
				link_id: 'link-${i % 2}'
			}) or { panic(err) }
			registry.buffer_pending('session', 'pending', new_frame(.data, 'frame-${i}', 'trace'), 1) or { panic(err) }
			assert registry.drain_pending('session', 'pending').len == 1
		}
	}()
	reader := spawn fn [registry] () {
		for _ in 0 .. 500 {
			items := build_session_snapshots(registry)
			assert items.len == 1
			assert items[0].endpoint_count == 1
			assert items[0].link_count == 1
			assert items[0].pending_frames in [0, 1]
			for link in ['link', 'link-0', 'link-1'] {
				for endpoint in registry.targets('session', link, '', '') {
					assert endpoint.link_id == link
				}
			}
		}
	}()
	writer.wait()
	reader.wait()
	assert registry.close_endpoint('session', 'endpoint')
	assert build_session_snapshots(registry).len == 0
}

fn test_session_rejected_operations_release_admission_and_preserve_pending_owner() {
	mut registry := new_session_registry()
	registry.buffer_pending('session', 'link', new_frame(.data, 'original', 'trace'), 1) or { panic(err) }
	if _ := open_session_endpoint_and_drain(mut registry, RelayEndpoint{
		...session_owner_endpoint('endpoint', 'session')
		trace_id: ''
	}) {
		assert false
	}
	assert route_session_frame(mut registry, '', 'link', '', '', new_frame(.data, 'invalid', 'trace'), 1).action == .rejected
	assert route_session_frame(mut registry, 'session', 'link', '', '', new_frame(.data, 'overflow', 'trace'), 1).action == .rejected
	assert !registry.close_endpoint('session', 'missing')
	frames := open_session_endpoint_and_drain(mut registry, session_owner_endpoint('endpoint', 'session')) or { panic(err) }
	assert frames.map(it.id) == ['original']
	assert registry.close_endpoint('session', 'endpoint')
	assert build_session_snapshots(registry).len == 0
}
