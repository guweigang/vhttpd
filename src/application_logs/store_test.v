module application_logs

fn test_application_buffers_are_independent_and_bounded() {
 mut store := &Store{}
 store.append(Scope{app_id:'wechat'},Record{message:'bodytest-only',source:'console'})
 for i in 0..1000 {store.append(Scope{app_id:'paseo'},Record{message:'paseo-${i}',source:'console'})}
 body := store.snapshot('wechat','',0,1000)
 paseo := store.snapshot('paseo','',0,1000)
 assert body.records.len == 1 && body.records[0].message == 'bodytest-only'
 assert body.dropped == 0
 assert paseo.records.len == records_per_application
 assert paseo.dropped == 1000-records_per_application
 assert paseo.records.all(it.app_id == 'paseo')
 assert store.snapshot('wechat','console',body.next_cursor,100).records.len == 0
}

fn test_identity_cannot_be_overridden_and_unknown_output_is_environment_only() {
 mut store := &Store{}
 store.append(Scope{app_id:'wechat',engine_id:'real'},Record{app_id:'paseo',engine_id:'forged',message:'actual-body'})
 store.append(Scope{},Record{app_id:'wechat',message:'unowned'})
 assert store.snapshot('wechat','',0,100).records.len == 1
 assert store.snapshot('wechat','',0,100).records[0].engine_id == 'real'
 assert store.snapshot('paseo','',0,100).records.len == 0
 assert store.snapshot('','',0,100).records[0].message == 'unowned'
 assert store.snapshot('*','',0,100).records.len == 2
}

fn test_large_multibyte_messages_and_application_cardinality_are_bounded() {
 mut store := &Store{}
 for i in 0..1000 {
  store.append(Scope{app_id:'app-${i}'},Record{message:'测试'.repeat(2000),source:'console'})
 }
 data := store.snapshot('*','',0,1000)
 assert store.buffers.len <= max_applications+1
 assert data.records.all(it.message.len <= max_message_bytes+32)
 assert data.records.all(it.message.ends_with('… [truncated]'))
 assert store.snapshot('app-999','',0,100).records.len == 0
}
