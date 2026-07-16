module executor

import sync
import upstream.transport

struct InProcVjsxWebSocketFrameBundle {
	raw     transport.WorkerWebSocketFrame
	runtime InProcVjsxRuntimeMeta
}

struct InProcVjsxWebSocketTaskResult {
	ok            bool
	response_json string
	error         string
}

struct InProcVjsxWebSocketTaskSlot {
mut:
	mu     sync.Mutex
	result InProcVjsxWebSocketTaskResult
	ready  bool
}

struct InProcVjsxWebSocketTask {
	app               AppFacade = NoOpAppFacade{}
	frame             transport.WorkerWebSocketFrame
	done              chan bool
	started           chan bool
	affinity_key      string
	affinity_priority int
	actor_key         string
	actor_class       string
	actor_priority    int
	actor_persist     bool
	actor_serialized  bool
mut:
	slot &InProcVjsxWebSocketTaskSlot = unsafe { nil }
}
