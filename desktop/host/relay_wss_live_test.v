module host

import os

// Opt-in network acceptance using the same implementation as Desktop.
fn test_live_application_wss_probe() ! {
	url := os.getenv('VHTTPD_TEST_APPLICATION_WSS')
	if url == '' {return}
	result := probe_shared_relay(SharedRelay{protocol:'websocket',id:'ab'.repeat(12),name:'WSS acceptance',url:url})
	assert result.ok && result.stage == 'WebSocket', result.message
}
