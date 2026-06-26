module executor

import sync
import upstream.transport

struct VjsxLaneWakeup {
	wake_at_ms i64
	generation u64
}

struct InProcVjsxLaneSnapshotTaskResult {
	ok    bool
	raw   string
	error string
}

struct InProcVjsxLaneSnapshotTaskSlot {
mut:
	mu     sync.Mutex
	result InProcVjsxLaneSnapshotTaskResult
	ready  bool
}

struct InProcVjsxLaneSnapshotTask {
	app  AppFacade = NoOpAppFacade{}
	done chan bool
mut:
	slot &InProcVjsxLaneSnapshotTaskSlot = unsafe { nil }
}

struct InProcVjsxLaneWarmupTaskResult {
	ok    bool
	error string
}

struct InProcVjsxLaneWarmupTaskSlot {
mut:
	mu     sync.Mutex
	result InProcVjsxLaneWarmupTaskResult
	ready  bool
}

struct InProcVjsxLaneWarmupTask {
	app  AppFacade = NoOpAppFacade{}
	done chan bool
mut:
	slot &InProcVjsxLaneWarmupTaskSlot = unsafe { nil }
}

struct InProcVjsxLanePumpTaskResult {
	ok    bool
	error string
}

struct InProcVjsxLanePumpTaskSlot {
mut:
	mu     sync.Mutex
	result InProcVjsxLanePumpTaskResult
	ready  bool
}

struct InProcVjsxLanePumpTask {
	done chan bool
mut:
	slot &InProcVjsxLanePumpTaskSlot = unsafe { nil }
}

struct InProcVjsxLaneAffinityTaskResult {
	ok    bool
	value WebSocketAffinityDecision
	actor WebSocketActorDecision
	error string
}

struct InProcVjsxLaneAffinityTaskSlot {
mut:
	mu     sync.Mutex
	result InProcVjsxLaneAffinityTaskResult
	ready  bool
}

struct InProcVjsxLaneAffinityTask {
	app   AppFacade = NoOpAppFacade{}
	frame transport.WorkerWebSocketFrame
	done  chan bool
	kind  string
mut:
	slot &InProcVjsxLaneAffinityTaskSlot = unsafe { nil }
}

struct VjsxLaneWorker {
mut:
	lane_id         string
	websocket_tasks chan InProcVjsxWebSocketTask
	snapshot_tasks  chan InProcVjsxLaneSnapshotTask
	warmup_tasks    chan InProcVjsxLaneWarmupTask
	pump_tasks      chan InProcVjsxLanePumpTask
	affinity_tasks  chan InProcVjsxLaneAffinityTask
	stop_ch         chan bool
	thread          thread
	started         bool
}
