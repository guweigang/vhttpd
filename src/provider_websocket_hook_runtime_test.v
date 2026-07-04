module main

import config
import feishu
import net
import net.websocket
import os
import plugin
import provider
import runtime_plan
import time
import ws

@[heap]
struct ProviderWebSocketE2EServerRef {
	handshake_ch chan string
	ack_ch       chan string
	push_frame   []u8
}

fn provider_websocket_e2e_free_port() int {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or {
		panic('provider websocket e2e could not reserve TCP port: ${err}')
	}
	addr := listener.addr() or {
		listener.close() or {}
		panic('provider websocket e2e could not inspect TCP port: ${err}')
	}
	port := addr.port() or {
		listener.close() or {}
		panic('provider websocket e2e could not parse TCP port: ${err}')
	}
	listener.close() or {}
	return port
}

fn provider_websocket_e2e_start_server(port int, push_frame []u8, handshake_ch chan string, ack_ch chan string) {
	mut server := websocket.new_server(.ip, port, '')
	server.set_ping_interval(60)
	mut state := &ProviderWebSocketE2EServerRef{
		handshake_ch: handshake_ch
		ack_ch:       ack_ch
		push_frame:   push_frame
	}
	server.on_connect(fn (mut client websocket.ServerClient) !bool {
		return client.resource_name == '/'
	}) or { panic(err) }
	server.on_message_ref(provider_websocket_e2e_server_message_cb, state)
	spawn fn [mut server] () {
		server.listen() or { panic('provider websocket e2e server could not listen: ${err}') }
	}()
	for server.get_state() != .open {
		time.sleep(10 * time.millisecond)
	}
}

fn provider_websocket_e2e_server_message_cb(mut client websocket.Client, msg &websocket.Message, ref voidptr) ! {
	mut state := unsafe { &ProviderWebSocketE2EServerRef(ref) }
	if msg.opcode == .text_frame {
		state.handshake_ch <- msg.payload.bytestr()
		client.write(state.push_frame, .binary_frame)!
		return
	}
	if msg.opcode == .binary_frame {
		state.ack_ch <- 'ack'
	}
}

fn provider_websocket_e2e_feishu_push_frame(payload string) []u8 {
	return feishu.RuntimeProtoFrame{
		seq_id:           701
		method:           feishu.frame_type_data
		headers:          [
			feishu.RuntimeProtoHeader{
				key:   feishu_runtime_header_type
				value: feishu_runtime_message_event
			},
			feishu.RuntimeProtoHeader{
				key:   feishu_runtime_header_trace
				value: 'trace-provider-ws-e2e'
			},
			feishu.RuntimeProtoHeader{
				key:   feishu_runtime_header_seq
				value: '701'
			},
		]
		payload_encoding: 'json'
		payload_type:     'application/json'
		payload:          payload.bytes()
		log_id_str:       'provider-ws-e2e'
	}.encode()
}

fn provider_websocket_e2e_wait_for_event_log(path string, needle string) bool {
	for _ in 0 .. 120 {
		text := os.read_file(path) or {
			time.sleep(25 * time.millisecond)
			continue
		}
		if text.contains(needle) {
			return true
		}
		time.sleep(25 * time.millisecond)
	}
	return false
}

fn test_provider_websocket_normalize_hook_dispatches_provider_ingress_event() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_provider_ws_hook_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	plugin_file := os.join_path(temp_dir, 'provider-ws-hooks.mts')
	os.write_file(plugin_file, "
export function normalize(req) {
  const payload = JSON.parse(req.payload);
  const event = JSON.parse(payload.payload);
  return {
    topic: 'provider.feishu',
    name: event.type,
    data: JSON.stringify({ text: event.text }),
    metadata: {
      event_type: event.type,
      instance: payload.instance,
      source: 'vjsx-normalize'
    },
    request_id: req.request_id,
    trace_id: req.trace_id
  };
}
") or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	plugins := {
		'feishu-ws-hooks': config.PluginConfig{
			kind:            'vjsx'
			app_entry:       plugin_file
			runtime_profile: 'node'
			thread_count:    1
		}
	}
	mut app := App{
		plan:      runtime_plan.RuntimePlan{
			providers: {
				'feishu': runtime_plan.ProviderPlan{
					id: 'feishu'
				}
			}
			pipelines: [
				runtime_plan.PipelinePlan{
					id:      'provider/feishu-normalized'
					ingress: runtime_plan.ResourceRef{
						domain: .provider
						id:     'feishu'
					}
					match:   runtime_plan.MatchPlan{
						metadata: {
							'event':    'im.message.receive_v1'
							'instance': 'main'
							'source':   'vjsx-normalize'
						}
					}
					egress:  runtime_plan.ResourceRef{
						domain: .terminal
						id:     'ack'
					}
				},
			]
		}
		providers: ProviderRuntimeHub.new(provider.ProviderRuntimeSettings{
			runtime_protocols: {
				'feishu': 'websocket'
			}
			runtime_plugins:   {
				'feishu': 'feishu-ws-hooks'
			}
			runtime_hooks:     {
				'feishu': {
					'normalize': 'normalize'
				}
			}
		})
		protocols: ProtocolRuntimeHub{
			plugins: plugin.PluginState{
				configs: plugins
				vjsx:    build_vjsx_plugin_runtimes(plugins)
			}
		}
	}
	defer {
		app.close_all_plugins()
	}

	resp := app.call_provider_websocket_hook('feishu', 'main', 'normalize',
		'wss://provider.test/ws', '{"type":"im.message.receive_v1","text":"hello"}', {
		'transport': 'websocket'
	}, 'req-normalize-probe', 'trace-normalize-probe') or { panic(err) }
	assert resp.result.contains('im.message.receive_v1')
	assert resp.result.contains('vjsx-normalize')

	ok := app.dispatch_provider_websocket_normalized_event('feishu', 'main',
		'wss://provider.test/ws', '{"type":"im.message.receive_v1","text":"hello"}', {
		'transport': 'websocket'
	}, 'req-normalize', 'trace-normalize')

	assert ok
}

fn test_native_websocket_provider_runs_vjsx_handshake_and_normalize_pipeline() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_provider_ws_e2e_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	plugin_file := os.join_path(temp_dir, 'provider-ws-e2e-hooks.mts')
	event_log := os.join_path(temp_dir, 'events.ndjson')
	os.write_file(plugin_file, "
export function handshake(req) {
  const payload = JSON.parse(req.payload);
  return {
    send: [
      {
        text: JSON.stringify({
          type: 'hello',
          provider: payload.provider,
          instance: payload.instance
        })
      }
    ]
  };
}

export function normalize(req) {
  const payload = JSON.parse(req.payload);
  const event = JSON.parse(payload.payload);
  return {
    topic: 'provider.feishu',
    name: event.header.event_type,
    data: JSON.stringify({
      message_id: event.event.message.message_id,
      text: JSON.parse(event.event.message.content).text
    }),
    metadata: {
      event_type: event.header.event_type,
      instance: payload.instance,
      source: 'vjsx-websocket-e2e'
    },
    request_id: req.request_id,
    trace_id: req.trace_id
  };
}
") or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	port := provider_websocket_e2e_free_port()
	push_payload := '{"schema":"2.0","header":{"event_id":"evt-provider-ws-e2e","event_type":"im.message.receive_v1"},"event":{"sender":{"sender_id":{"open_id":"ou_provider_ws"},"tenant_key":"tenant_provider_ws"},"message":{"message_id":"om-provider-ws-e2e","message_type":"text","chat_id":"oc-provider-ws-e2e","chat_type":"group","create_time":"1710000000","content":"{\\"text\\":\\"hello from upstream\\"}"}}}'
	handshake_ch := chan string{cap: 1}
	ack_ch := chan string{cap: 1}
	provider_websocket_e2e_start_server(port,
		provider_websocket_e2e_feishu_push_frame(push_payload), handshake_ch, ack_ch)

	plugins := {
		'feishu-ws-e2e-hooks': config.PluginConfig{
			kind:            'vjsx'
			app_entry:       plugin_file
			runtime_profile: 'node'
			thread_count:    1
		}
	}
	mut app := App{
		plan:          runtime_plan.RuntimePlan{
			providers: {
				'feishu': runtime_plan.ProviderPlan{
					id:       'feishu'
					driver:   'native'
					protocol: 'websocket'
					plugin:   'feishu-ws-e2e-hooks'
				}
			}
			pipelines: [
				runtime_plan.PipelinePlan{
					id:      'provider/feishu-ws-e2e'
					ingress: runtime_plan.ResourceRef{
						domain: .provider
						id:     'feishu'
					}
					match:   runtime_plan.MatchPlan{
						metadata: {
							'event':    'im.message.receive_v1'
							'instance': 'main'
							'source':   'vjsx-websocket-e2e'
						}
					}
					egress:  runtime_plan.ResourceRef{
						domain: .terminal
						id:     'ack'
					}
				},
			]
		}
		providers:     ProviderRuntimeHub.new(provider.ProviderRuntimeSettings{
			runtime_protocols: {
				'feishu': 'websocket'
			}
			runtime_plugins:   {
				'feishu': 'feishu-ws-e2e-hooks'
			}
			runtime_hooks:     {
				'feishu': {
					'handshake': 'handshake'
					'normalize': 'normalize'
				}
			}
			feishu:            provider.FeishuRuntimeSettings{
				enabled: true
				apps:    {
					'main': config.FeishuAppConfig{
						app_id:     'cli_main'
						app_secret: 'sec_main'
					}
				}
			}
		})
		protocols:     ProtocolRuntimeHub{
			plugins: plugin.PluginState{
				configs: plugins
				vjsx:    build_vjsx_plugin_runtimes(plugins)
			}
		}
		control_plane: ControlPlaneRuntime{
			event_log: event_log
		}
	}
	defer {
		app.close_all_plugins()
	}

	ws_url := 'ws://127.0.0.1:${port}/'
	rt := ws.UpstreamRuntimeContext{
		enabled_fn:         fn (_provider string, _instance string) bool {
			return true
		}
		reconnect_delay_fn: fn (_provider string, _instance string) int {
			return 25
		}
		connecting_fn:      fn (_provider string, _instance string) {}
		pull_url_fn:        fn [ws_url] (_provider string, _instance string) !string {
			return ws_url
		}
		connected_fn:       fn [mut app] (provider_name string, instance string, url string) {
			app.provider_runtime_on_connected(provider_name, instance, url)
		}
		disconnected_fn:    fn (_provider string, _instance string, _reason string) {}
		handle_message_fn:  fn [mut app] (provider_name string, instance string, mut client websocket.Client, msg &websocket.Message) ! {
			app.websocket_upstream_provider_handle_message(provider_name, instance, mut client, msg)!
		}
		post_connect_fn:    fn [mut app] (provider_name string, instance string, url string, mut client websocket.Client) {
			app.dispatch_provider_websocket_handshake(provider_name, instance, url, mut client)
		}
	}
	spawn rt.run_provider(websocket_upstream_provider_feishu, 'main')

	mut handshake := ''
	select {
		value := <-handshake_ch {
			handshake = value
		}
		3 * time.second {}
	}
	assert handshake.contains('"type":"hello"')
	assert handshake.contains('"provider":"feishu"')
	assert handshake.contains('"instance":"main"')

	mut ack := ''
	select {
		value := <-ack_ch {
			ack = value
		}
		3 * time.second {}
	}
	assert ack == 'ack'
	assert provider_websocket_e2e_wait_for_event_log(event_log, '"type":"runtime.event.dispatch"')
	event_log_text := os.read_file(event_log) or { panic(err) }
	assert event_log_text.contains('"pipeline":"provider/feishu-ws-e2e"')
	assert event_log_text.contains('"source":"vjsx-websocket-e2e"')
	assert event_log_text.contains('"event":"im.message.receive_v1"')
}
