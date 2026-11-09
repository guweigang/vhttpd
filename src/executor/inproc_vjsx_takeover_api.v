module executor

import vjsx
import app_bundle

// Only trusted application code calls this after authenticating an account.
// No client header or event property is treated as an authenticated identity.
pub interface TakeoverFacade {
	EmbeddedHost
mut:
	vjsx_takeover_request(string) !string
}

// Ownership is a separate host argument, never a field supplied by JS. The
// inactive path does not parse an envelope or read metadata from disk.
pub interface OwnedTakeoverFacade {
 TakeoverFacade
mut:
 vjsx_takeover_identity_required() bool
 vjsx_takeover_request_owned(string,string,string) !string
}

fn InProcVjsxHostApi.takeover_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
 return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
  return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
   if args.len != 1 {return ctx.js_throw(ctx.js_error(message:'takeover_invalid_request'))}
   access := state.request_host(idx,.request_only) or {return ctx.js_throw(ctx.js_error(message:'takeover_request_unavailable'))}
   mut host := access.host
   if mut host is OwnedTakeoverFacade {
    mut identity := app_bundle.ApplicationIdentity{}
    if host.vjsx_takeover_identity_required() {
     state.mu.@lock()
     entry := state.facade.config.app_entry
     state.mu.unlock()
     identity = app_bundle.entry_identity(entry) or {app_bundle.ApplicationIdentity{}}
    }
    result := host.vjsx_takeover_request_owned(args[0].to_string(),identity.app_id,identity.installation_id) or {return ctx.js_throw(ctx.js_error(message:'takeover_result_unknown'))}
    return ctx.js_string(result)
   }
   if mut host is TakeoverFacade {
    result := host.vjsx_takeover_request(args[0].to_string()) or {return ctx.js_throw(ctx.js_error(message:'takeover_result_unknown'))}
    return ctx.js_string(result)
   }
   return ctx.js_string('{"handled":false}')
  })
 }
}
