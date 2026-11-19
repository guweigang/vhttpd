module executor

// quickjs-ng's full std loop waits for future timers. An idle maintenance turn
// must give the lane back immediately; long Paseo nudge timers otherwise block
// a one-lane application from accepting its next connection.
fn C.js_std_loop_once(voidptr) int
fn C.js_std_poll_io(voidptr, int) int

fn (host VjsxLaneHost) pump_ready_events() ! {
	mut session := host.session_handle() or { return }
	session.runtime().update_stack_top()
	session.deliver_wakeup(0)!
	ctx := session.context()
	C.js_std_poll_io(ctx.ref_ptr(),0)
	delay := C.js_std_loop_once(ctx.ref_ptr())
	if delay == -2 { return error(InProcVjsxError.context_message(ctx,'timer callback failed','inproc_vjsx_idle_pump_failed')) }
	session.deliver_wakeup(0)!
	if delay >= 0 { session.request_wakeup_after(if delay == 0 {1} else {delay},'vhttpd-idle') }
}
