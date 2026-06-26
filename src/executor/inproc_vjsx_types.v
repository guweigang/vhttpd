module executor

import sync
import config as app_config
import state_store

pub struct VjsxRuntimeFacadeConfig {
pub:
	app_entry                  string
	module_root                string
	build_root                 string
	signature_root             string
	signature_include          []string
	signature_exclude          []string
	runtime_profile            string
	thread_count               int
	max_requests               int
	enable_fs                  bool
	enable_process             bool
	enable_network             bool
	enable_item_render_streams bool = true
	websocket_affinity         app_config.WebSocketAffinityConfig
	websocket_actor            app_config.WebSocketActorConfig
}

pub struct VjsxRuntimeFacade {
pub mut:
	config       VjsxRuntimeFacadeConfig
	bootstrapped bool
	last_error   string
}

pub struct VjsxExecutionLane {
pub:
	id string
pub mut:
	served_requests i64
	healthy         bool = true
	dirty           bool
	inflight        int
	last_error      string
}

pub struct VjsxExecutorState {
pub mut:
	mu sync.Mutex
mut:
	app_ref                                 AppFacade = NoOpAppFacade{}
	facade                                  VjsxRuntimeFacade
	session_store                           state_store.MemoryStateStore[string]
	lanes                                   []VjsxExecutionLane
	hosts                                   []VjsxLaneHost
	lane_workers                            []VjsxLaneWorker
	rr_index                                int
	websocket_affinity_lane_by_key          map[string]string
	websocket_affinity_ref_count_by_key     map[string]int
	websocket_connection_lane_by_id         map[string]string
	websocket_connection_affinity_key_by_id map[string]string
	websocket_connection_actor_key_by_id    map[string]string
	websocket_connection_actor_class_by_id  map[string]string
	websocket_mailbox_by_key                map[string][]InProcVjsxWebSocketTask
	websocket_mailbox_pending_keys          []string
	websocket_mailbox_running_by_key        map[string]bool
	lane_wakeup_by_id                       map[string]VjsxLaneWakeup
	cached_source_probe                     string
	cached_source_signature                 string
	signature_refresh_started               bool
	signature_refresh_stop                  bool
	signature_last_checked_at               i64
	signature_last_probe_at                 i64
	signature_pending_since                 i64
	signature_last_error                    string
	warmup_source_signature                 string
	warmup_running                          bool
	warmup_completed                        bool
	warmup_last_error                       string
	app_startup_source_signature            string
	app_startup_running                     bool
	app_startup_completed                   bool
	app_startup_last_error                  string
}

pub struct InProcVjsxExecutor {
pub:
	provider_name string = 'vjsx'
	kind_name     string = 'vjsx'
pub mut:
	state &VjsxExecutorState = unsafe { nil }
}
