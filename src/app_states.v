module main
import executor
import config
import stats
import assets
import plugins
import admin

import net.websocket
import state_store
import sync

pub struct WorkerState {
pub mut:
	mu                  sync.Mutex // 即原 pool_mu
	worker_backend      WorkerBackendRuntime
	worker_backend_mode executor.WorkerBackendMode = .required
	logic_executor      executor.LogicExecutor     = executor.SocketWorkerExecutor{}
	lifecycle           string
	stream_dispatch     bool
	// 统计指标
	stat_queue_waits_total    i64
	stat_queue_rejected_total i64
	stat_queue_timeouts_total i64
}

pub struct WebSocketHubState {
pub mut:
	mu                                  sync.Mutex
	send_mu                             sync.Mutex
	upstream_mu                         sync.Mutex
	conns                               map[string]HubConn
	room_members                        map[string]map[string]bool
	conn_rooms                          map[string]map[string]bool
	conn_meta                           map[string]map[string]string
	pending                             map[string][]HubPendingMessage
	dispatch_mode                       bool
	recent_dispatch_limit               int
	auto_start_dynamic_upstreams        bool
	upstream_started                    map[string]bool
	fixture_runtime                     map[string]FixtureWebSocketUpstreamRuntime
	recent_activities                   []WebSocketUpstreamActivitySnapshot
	upstream_sessions                   map[string]UpstreamRuntimeSession
	stat_upstream_plans_total           i64
	stat_upstream_plan_errors_total     i64
}

pub struct FeishuState {
pub mut:
	mu                               sync.Mutex
	enabled                          bool
	open_base_url                    string
	reconnect_delay_ms               int
	token_refresh_skew_seconds       int
	recent_event_limit               int
	static_apps                      map[string]config.FeishuAppConfig
	apps                             map[string]config.FeishuAppConfig
	runtime                          map[string]FeishuProviderRuntime
	buffers                          map[string]FeishuStreamBuffer
	http_lane                        shared FeishuHttpLane
	control_http_lane                shared FeishuControlHttpLane
	http_test_mu                     sync.Mutex
	http_test_stub                   bool
	http_test_delay_ms               int
	http_test_inflight               int
	http_test_calls                  int
	http_test_message_seq            int
	// 飞书卡片桥
	card_bridge_mu            sync.Mutex
	card_bridge_send_mu       sync.Mutex
	card_bridge_clients       map[string]&websocket.Client            = map[string]&websocket.Client{}
	card_bridge_pending       map[string]chan executor.FeishuCardBridgeResult  = map[string]chan executor.FeishuCardBridgeResult{}
	card_bridge_proxy_pending map[string]chan FeishuBridgeProxyResult = map[string]chan FeishuBridgeProxyResult{}
	card_bridge_client_conn   &websocket.Client                       = unsafe { nil }
	card_bridge_enabled_flag  bool
	card_bridge_ws_url        string
	card_bridge_client_id     string
	card_bridge_token         string
	card_bridge_target_id     string
}

pub struct CodexState {
pub mut:
	mu              sync.Mutex
	runtime         CodexProviderRuntime
	instances       map[string]CodexProviderRuntime = map[string]CodexProviderRuntime{}
	ollama_enabled  bool
	db_runtime      DbProviderRuntime
}

pub struct McpState {
pub mut:
	mu                                      sync.Mutex
	max_sessions                            int
	max_pending_messages                    int
	session_ttl_seconds                     int
	sampling_capability_policy              string
	allowed_origins                         []string
	sessions                                map[string]McpSession
	stat_sessions_expired_total             i64
	stat_sessions_evicted_total             i64
	stat_pending_dropped_total              i64
	stat_sampling_capability_warnings_total i64
	stat_sampling_capability_dropped_total  i64
	stat_sampling_capability_errors_total   i64
}

type AdminState = admin.AdminState

type AssetsState = assets.AssetsState

type PluginState = plugins.PluginState

pub struct HttpStats {
pub mut:
	requests_total       i64
	errors_total         i64
	timeouts_total       i64
	streams_total        i64
	admin_actions_total  i64
}

pub struct OpenaiState {
pub mut:
	enabled          bool
	base_path        string
	default_backend  string
	plugin           string
	endpoints        config.OpenAIEndpointsConfig
	backends         map[string]config.OpenAIBackendConfig
	routes           map[string]config.OpenAIRouteConfig
	responses        state_store.MemoryStateStore[OpenAIResponseRecord]
}
