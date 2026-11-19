module executor

import vjsx
import json2 as json

// Original source locations, independent of the transpiler's temporary module
// URL. Available at module initialization; exposes no runtime credentials.
struct ApplicationSourceInfo {
 entry string
 root string
}

fn InProcVjsxHostApi.application_info_builder(mut state VjsxExecutorState) vjsx.HostValueBuilder {
 return fn [mut state] (ctx &vjsx.Context) vjsx.Value {
  return ctx.js_function(fn [ctx,mut state] (_args []vjsx.Value) vjsx.Value {
   state.mu.@lock()
   info := ApplicationSourceInfo{entry:state.facade.config.app_entry,root:state.facade.config.module_root}
   state.mu.unlock()
   return ctx.js_string(json.encode(info))
  })
 }
}
