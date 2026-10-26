// Isolated acceptance fixture: supports preflight/helper, but cannot start a service.
module main

import json2 as json
import os
import runtime_upgrade

fn main() {
	if '--version' in os.args {
		println('0.0.0-failure-fixture')
		return
	}
	if os.args.len == 3 && os.args[1] == '--workbench-upgrade-check' {
		checked := runtime_upgrade.check(os.args[2], '0.0.0-failure-fixture') or { exit(2) }
		println(json.encode(checked))
		return
	}
	if os.args.len == 3 && os.args[1] == '--workbench-upgrade-helper' {
		runtime_upgrade.run(os.args[2]) or { exit(3) }
		return
	}
	exit(78)
}
