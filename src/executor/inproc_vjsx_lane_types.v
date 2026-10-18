module executor

import sync
import upstream.transport

struct InProcVjsxLaneSnapshotTaskResult {
	ok    bool
	raw   string
	error string
}

struct InProcVjsxLaneSnapshotTaskSlot {
mut:
	control &ExecutorTaskControl = &ExecutorTaskControl{}
	mu      sync.Mutex
	result  InProcVjsxLaneSnapshotTaskResult
	ready   bool
}

struct InProcVjsxLaneSnapshotTask {
	app  EmbeddedHost @[required]
	done chan bool    @[required]
mut:
	slot &InProcVjsxLaneSnapshotTaskSlot @[required]
}

struct InProcVjsxLaneWarmupTaskResult {
	ok    bool
	error string
}

struct InProcVjsxLaneWarmupTaskSlot {
mut:
	bootstrapped chan u64 = chan u64{cap: 1}
	control &ExecutorTaskControl = &ExecutorTaskControl{}
	mu      sync.Mutex
	result  InProcVjsxLaneWarmupTaskResult
	ready   bool
}

struct InProcVjsxLaneWarmupTask {
	app  EmbeddedHost @[required]
	done chan bool    @[required]
mut:
	slot &InProcVjsxLaneWarmupTaskSlot @[required]
}

struct InProcVjsxLanePumpTaskResult {
	ok    bool
	error string
}

struct InProcVjsxLanePumpTaskSlot {
mut:
	control &ExecutorTaskControl = &ExecutorTaskControl{}
	mu      sync.Mutex
	result  InProcVjsxLanePumpTaskResult
	ready   bool
}

struct InProcVjsxLanePumpTask {
	wakeup_owner ?&VjsxLaneWakeupOwner
	done chan bool @[required]
mut:
	slot &InProcVjsxLanePumpTaskSlot @[required]
}

struct InProcVjsxLaneAffinityTaskResult {
	ok    bool
	value WebSocketAffinityDecision
	actor WebSocketActorDecision
	error string
}

struct InProcVjsxLaneAffinityTaskSlot {
mut:
	control &ExecutorTaskControl = &ExecutorTaskControl{}
	mu      sync.Mutex
	result  InProcVjsxLaneAffinityTaskResult
	ready   bool
}

struct InProcVjsxLaneAffinityTask {
	app   EmbeddedHost @[required]
	frame transport.WorkerWebSocketFrame
	done  chan bool @[required]
	kind  string
mut:
	slot &InProcVjsxLaneAffinityTaskSlot @[required]
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
