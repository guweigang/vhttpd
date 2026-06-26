module executor

import time

const inproc_vjsx_lane_wait_timeout_ms = 1000
const inproc_vjsx_lane_wait_poll_ms = 5
const inproc_vjsx_lane_task_timeout = 10 * time.second
const inproc_vjsx_websocket_queue_wait_timeout = 30 * time.second
const inproc_vjsx_dispatch_retry_attempts = 2
const inproc_vjsx_startup_wait_poll_ms = 5
const inproc_vjsx_signature_probe_poll_ms = 100
const inproc_vjsx_signature_refresh_debounce_ms = 200
const inproc_vjsx_signature_full_refresh_ms = 1000
const inproc_vjsx_http_facade_source = $embed_file('src/inproc_vjsx_http_facade.js')
