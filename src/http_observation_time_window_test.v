module main

import server_lifecycle
import executor

fn test_recent_window_expires_without_erasing_history_and_merges_routes() {
	mut one := &App{}
	mut two := &App{}
	one.lifecycle.started_at_unix = 1000
	two.lifecycle.started_at_unix = 1000
	one.control_plane.http_observations.record('fast', 'GET', 503, 20, 'old', 1001)
	one.control_plane.http_observations.record('slow', 'GET', 200, 1200, 'slow', 1061)
	two.control_plane.http_observations.record('fast', 'GET', 200, 10, 'ok', 1062)
	mut registry := ActiveRuntimeRegistry{}
	registry.register(one, timing_observation_registry_config('one'))
	registry.register(two, timing_observation_registry_config('two'))
	registry.register(two, timing_observation_registry_config('two'))
	window := registry.traffic_window('', '', false, 60, 1070)
	assert window.metrics.requests_total == 2
	assert window.metrics.errors_total == 0
	assert window.metrics.duration_max_ms == 1200
	assert window.listeners.len == 2
	assert window.series.len <= 7
	assert one.control_plane.http_observations.total.errors_total == 1
	longer := registry.traffic_window('', '', false, 300, 1070)
	assert longer.metrics.errors_total == 1
	assert longer.start_unix == 1000
	filtered := registry.traffic_window('one', 'slow', true, 60, 1070)
	assert filtered.metrics.requests_total == 1
	assert filtered.metrics.duration_sum_ms == 1200
	assert filtered.listeners[0].routes.len == 1
	empty := registry.traffic_window('one', 'fast', true, 60, 1070)
	assert empty.metrics.requests_total == 0
	assert empty.series.all(it.metrics.errors_total == 0)
}

fn test_time_buckets_are_bounded_and_clock_rollback_starts_a_fresh_window() {
	mut observations := HttpObservations{}
	for i in 0 .. 200 { observations.record('route', 'GET', 200, 1, 'id', 1000 + i * 10) }
	assert observations.buckets.len <= 91
	observations.record('route', 'GET', 500, 10, 'reset', 500)
	assert observations.buckets.len == 1
	assert observations.window_reset_unix == 500
	assert observations.total.requests_total == 201
}

fn test_request_details_filter_retention_and_safe_completion_logs() {
	mut app := &App{}
	for i in 0 .. 60 {
		app.control_plane.http_observations.record('slow', 'GET', 200, 100 + i, 'safe-${i}', 1000 + i)
	}
	app.control_plane.http_observations.record('other', 'POST', 500, 999, 'other', 1060)
	mut registry := ActiveRuntimeRegistry{}
	registry.register(app, timing_observation_registry_config('web'))
	result := registry.request_details('web', 'slow', 60, 150, 1060)
	assert result.retained == 50
	assert result.requests.len == 10
	assert result.requests[0].request.observation_id == 'safe-59'
	assert result.requests[0].request.duration_ms == 159
	assert result.requests[0].log_line.contains('safe-59')
	assert !result.requests[0].log_line.contains('url')
	assert registry.request_details('web', 'slow', 60, 1, 2000).requests.len == 0
	assert registry.request_details('missing', 'slow', 60, 1, 1060).requests.len == 0
	assert registry.request_details('web', 'slow', 60, 9999, 1060).requests.len == 0
}

fn timing_observation_registry_config(listener string) server_lifecycle.ServerRuntimeConfig {
	return server_lifecycle.ServerRuntimeConfig{
		plan_listener_id: listener
		serve_data_plane: true
		executor_plan:    executor.LogicExecutorRuntimePlan{
			executor:  executor.DisabledLogicExecutor{}
			lifecycle: executor.disabled_executor_lifecycle()
		}
	}
}
