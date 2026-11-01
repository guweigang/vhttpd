module executor

import time

fn test_idle_pump_never_waits_for_future_timers_and_delivers_due_timers() ! {
 mut session := InProcVjsxRuntimeSessionFactory.new(VjsxRuntimeFacadeConfig{runtime_profile:'node'})!
 defer {session.close()}
 ctx := session.context()
 setup := ctx.eval('globalThis.logTimerFired = false; globalThis.logTimer = setTimeout(() => globalThis.logTimerFired = true, 1500);')!
 setup.free()
 host := VjsxLaneHost{session:session}
 started := time.sys_mono_now()
 host.pump_ready_events()!
 assert (time.sys_mono_now()-started)/1000000 < 300
 state := ctx.eval('globalThis.logTimerFired')!
 assert !state.to_bool()
 state.free()
 replace := ctx.eval('clearTimeout(globalThis.logTimer); setTimeout(() => globalThis.logTimerFired = true, 5);')!
 replace.free()
 time.sleep(15*time.millisecond)
 host.pump_ready_events()!
 ready := ctx.eval('globalThis.logTimerFired')!
 defer {ready.free()}
 assert ready.to_bool()
}
