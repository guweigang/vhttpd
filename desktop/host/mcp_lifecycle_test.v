module host

import time

fn test_lifecycle_rejects_expired_and_revoked_binding() {
	req := McpLifecycleRequest{ deadline: time.now().unix() - 1 }
	req.check() or {
		assert err.msg().contains('stale_binding_revision')
		return
	}
	assert false
}

fn test_lifecycle_apply_requires_prepared_identity_and_action() {
	mut s := ServerSession{}
	r := McpLifecycleRequest{ tool: 'instance_stop_apply', deadline: time.now().unix() + 30 }
	s.lifecycle_validate_apply(r) or {
		assert err.msg().contains('stale_binding_revision') || err.msg().contains('invalid_lifecycle_plan')
		return
	}
	assert false
}

fn test_lifecycle_operation_updates_only_exact_operation() {
	mut s := ServerSession{
		mcp_host_operations: [
			McpHostOperation{ operation_id: 'one', phase: 'running' },
			McpHostOperation{ operation_id: 'two', phase: 'running' },
		]
	}
	s.lifecycle_set_operation('one', 'completed', 'target', '')
	assert s.state.mcp_host_operations[0].phase == 'completed'
	assert s.state.mcp_host_operations[0].target_id == 'target'
	assert s.state.mcp_host_operations[1].phase == 'running'
}
