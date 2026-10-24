module main

import os
import time

fn admin_state_runtime_test_root(name string) string {
	return os.join_path(os.temp_dir(), '${name}_${time.now().unix_micro()}')
}

fn admin_state_runtime_plan_text(body string) string {
	return admin_state_named_runtime_plan_text('web', 18080, body)
}

fn admin_state_named_runtime_plan_text(id string, port int, body string) string {
	return '
version = 2

[listeners.${id}]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = ${port}

[adapters.${id}]
kind = "fixed-response"

[adapters.${id}.options]
status = "200"
body = "${body}"

[[pipelines]]
id = "${id}"
ingress = "listener:${id}"
egress = "adapter:${id}"

[pipelines.match]
paths = ["*"]
'
}

