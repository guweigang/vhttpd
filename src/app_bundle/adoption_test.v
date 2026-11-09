module app_bundle

import app_meta
import config
import crypto.rand
import os

fn test_legacy_adoption_preserves_environment_data_and_then_supports_bound_updates() ! {
 root := os.join_path(os.real_path(os.temp_dir()),'adopt-'+rand.bytes(8)!.hex())
 os.mkdir(root)!
 defer {os.rmdir_all(root) or {}}
 for existing in [false,true] {
  env := root + if existing {'/component'} else {'/legacy'}
  source := root + if existing {'/source-two'} else {'/source-one'}
  os.mkdir(env)!;os.mkdir(source)!
  code := 'export default c => c.json({ok:true})'
  business := '[listeners.alpha]\nprotocol="http"\nhost="127.0.0.1"\nport=39871\n[engines.alpha]\nkind="vjsx"\nentry="main.mjs"\n[adapters.alpha]\nkind="http-handler"\nengine="engine:alpha"\n[[pipelines]]\nid="alpha.http"\ngroup="alpha"\ningress="listener:alpha"\negress="adapter:alpha"\n'
  policy := '[policies.concurrency.alpha_queue]\nmax_queue_per_key=9\n'
  scoped := if existing { business.replace('egress="adapter:alpha"','policies=["policy:concurrency/alpha_queue"]\negress="adapter:alpha"')+policy } else {business}
  environment := 'version=2\n[listeners.admin]\nprotocol="http"\nhost="127.0.0.1"\nport=39872\n[control]\nlistener="listener:admin"\ntoken="private-fixture"\n[resources.db.shared]\nkind="sqlite"\ndatabase="retained.sqlite"\n'
  if existing {
   os.mkdir_all(env+'/apps/alpha')!
   os.write_file(env+'/apps/alpha/component.toml',scoped)!
   os.write_file(env+'/apps/alpha/main.mjs',code)!
   os.write_file(env+'/vhttpd.toml','include=["apps/alpha/component.toml"]\n'+environment)!
  } else {
   os.write_file(env+'/main.mjs',code)!
   os.write_file(env+'/vhttpd.toml',environment+business)!
  }
  other := business.replace('alpha','beta').replace('39871','39873').replace('main.mjs','beta.mjs')
  os.write_file(env+'/vhttpd.toml',os.read_file(env+'/vhttpd.toml')!+other)!
  os.write_file(env+'/beta.mjs','export default c => c.json({other:true})')!
  os.write_file(env+'/credentials.json','PRIVATE')!
  os.write_file(env+'/retained.sqlite','DATA')!
  os.write_file(source+'/component.toml',scoped.replace('39871','39999').replace('max_queue_per_key=9','max_queue_per_key=999'))!
  os.write_file(source+'/main.mjs',code)!
  meta := app_meta.initialize(source,'alpha','component.toml')!
  before := os.read_file(env+'/vhttpd.toml')!
  wrong := collect_component_adoption(source,source+'/component.toml','c'.repeat(24),'alpha',['beta'])!
  mut wrong_rejected := false
  compose_component(wrong,env+'/vhttpd.toml') or {wrong_rejected=true}
  assert wrong_rejected
  if existing {
   os.write_file(env+'/vhttpd.toml',before.replace('egress="adapter:beta"','policies=["policy:concurrency/alpha_queue"]\negress="adapter:beta"'))!
   shared := collect_component_adoption(source,source+'/component.toml','d'.repeat(24),'alpha',['alpha'])!
   mut rejected := false
   compose_component(shared,env+'/vhttpd.toml') or {rejected=true}
   assert rejected
   os.write_file(env+'/vhttpd.toml',before)!
  }
  payload := collect_component_adoption(source,source+'/component.toml','a'.repeat(24),'alpha',['alpha'])!
  composed := compose_component(payload,env+'/vhttpd.toml')!
  assert os.read_file(env+'/vhttpd.toml')! == before
  assert !composed.files.any(it.path in ['credentials.json','retained.sqlite'])
  materialize(composed,env)!
  plan := config.load_runtime_plan_file(env+'/vhttpd.toml')!
  if existing {assert os.read_file(env+'/apps/alpha/component.toml')!.contains('max_queue_per_key = 9')}
  assert plan.engines.len == 2
  assert plan.listeners['beta'].port == 39873
  assert os.read_file(env+'/beta.mjs')! == 'export default c => c.json({other:true})'
  assert plan.listeners['alpha'].port == 39871
  assert plan.control.token == 'private-fixture'
  assert os.read_file(env+'/credentials.json')! == 'PRIVATE'
  assert os.read_file(env+'/retained.sqlite')! == 'DATA'
  if !existing {assert os.read_file(env+'/main.mjs')! == code}
  record := read_installation(env,'alpha')!
  assert record.app_id == meta.id
  assert engine_identity(env+'/vhttpd.toml','alpha')!.installation_id == record.id
  update := collect_component_update(source,source+'/component.toml','b'.repeat(24),'alpha',record.id)!
  compose_component(update,env+'/vhttpd.toml')!
  mut repeated := false
  compose_component(payload,env+'/vhttpd.toml') or {repeated=true}
  assert repeated
 }
}
