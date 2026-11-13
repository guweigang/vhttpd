module app_bundle

import config
import encoding.base64
import crypto.sha256
import os
import toml

// Adoption is an explicit transaction for a selected legacy engine set. It
// does not infer ownership from names and never deletes legacy code or data.
pub fn collect_component_adoption(root string, entry string, operation string, component string, engines []string) !Payload {
 p := collect_component(root,entry,operation,component)!
 if engines.len == 0 || engines.len > 16 || engines.any(it == '') {return error('invalid_adoption_target')}
 meta := component_manifest(p)!
 if meta.id == '' {return error('app_meta_required')}
 return Payload{...p,adopt_engines:engines.clone()}
}

fn adoption_definitions(p Payload) !map[string][]string {
 mut out := map[string][]string{}
 for file in p.files {
  if file.path !in p.configs {continue}
  doc := toml.parse_text(base64.decode_str(file.data))!
  fields := doc.to_any().as_map()
  for domain in ['listeners','engines','adapters','transforms'] {
   if domain !in fields {continue}
   for id,_ in (fields[domain] or {toml.Any(map[string]toml.Any{})}).as_map() {
    mut ids := out[domain] or {[]string{}}
    if id in ids {return error('invalid_adoption_target')}
    ids << id;out[domain]=ids
   }
  }
  for category, policies in (fields['policies'] or {toml.Any(map[string]toml.Any{})}).as_map() {
   for id,_ in policies.as_map() {
    mut ids := out['policies'] or {[]string{}}
    key := category+'/'+id
    if key in ids {return error('invalid_adoption_target')}
    ids << key;out['policies']=ids
   }
  }
  for pipe in (fields['pipelines'] or {toml.Any([]toml.Any{})}).array() {
   mut ids := out['pipelines'] or {[]string{}}
   id := pipe.value('id').string()
   if id == '' || id in ids {return error('invalid_adoption_target')}
   ids << id;out['pipelines']=ids
  }
 }
 return out
}

fn validate_adoption(p Payload, config_path string) ! {
 if p.target_installation_id != '' {return error('invalid_adoption_target')}
 defs := adoption_definitions(p)!
 declared := defs['engines'] or {[]string{}}
 if declared.len != p.adopt_engines.len || declared.any(it !in p.adopt_engines) {return error('adoption_engine_mismatch')}
 if (defs['transforms'] or {[]string{}}).len > 0 {return error('adoption_shared_policy_forbidden')}
 plan := config.load_runtime_plan_file(config_path)!
 for id in p.adopt_engines {if id !in plan.engines {return error('adoption_engine_mismatch')}}
 for file in p.files {
  if file.path !in p.configs {continue}
  doc := toml.parse_text(base64.decode_str(file.data))!
  fields := doc.to_any().as_map()
  for id,value in (fields['engines'] or {toml.Any(map[string]toml.Any{})}).as_map() {
   if value.value('kind').string() != plan.engines[id].kind {return error('adoption_engine_mismatch')}
  }
  for id,value in (fields['listeners'] or {toml.Any(map[string]toml.Any{})}).as_map() {
   old := plan.listeners[id] or {return error('adoption_listener_mismatch')}
   if value.value('protocol').string() != old.protocol {return error('adoption_listener_mismatch')}
  }
  for id,value in (fields['adapters'] or {toml.Any(map[string]toml.Any{})}).as_map() {
   old := plan.adapters[id] or {return error('adoption_adapter_mismatch')}
   if value.value('kind').string() != old.kind || value.value('engine').string().all_after('engine:') !in p.adopt_engines {return error('adoption_adapter_mismatch')}
  }
 }
 for id in defs['listeners'] or {[]string{}} {
  if id !in plan.listeners {return error('adoption_listener_mismatch')}
  if control := plan.control.listener {if control.id == id {return error('adoption_control_forbidden')}}
 }
 for id in defs['adapters'] or {[]string{}} {
  adapter := plan.adapters[id] or {return error('adoption_adapter_mismatch')}
  engine := adapter.engine or {return error('adoption_adapter_mismatch')}
  if engine.id !in p.adopt_engines {return error('adoption_adapter_mismatch')}
 }
 ids := defs['pipelines'] or {[]string{}}
 for id in ids {
  matches := plan.pipelines.filter(it.id == id)
  if matches.len != 1 || matches[0].egress.domain != .adapter || matches[0].egress.id !in (defs['adapters'] or {[]string{}}) {return error('adoption_pipeline_mismatch')}
 }
 for pipeline in plan.pipelines {
  if pipeline.ingress.domain != .listener || pipeline.egress.domain != .adapter {continue}
  adapter := plan.adapters[pipeline.egress.id] or {continue}
  if engine := adapter.engine {
   if engine.id in p.adopt_engines && pipeline.id !in ids {return error('adoption_incomplete_application')}
  }
 }
 prefix := os.join_path(os.dir(config_path),'apps',p.component_id) + '/'
 for id in defs['policies'] or {[]string{}} {
  if id !in plan.policies {return error('adoption_policy_mismatch')}
  mut used := false
  for pipeline in plan.pipelines {
   if pipeline.policies.any(it.id == id) {
    if pipeline.id !in ids {return error('adoption_shared_policy_forbidden')}
    used=true
   }
  }
  if !used {return error('adoption_shared_policy_forbidden')}
 }
 for source in config.runtime_config_sources(config_path)! {
  if !source.path.starts_with(prefix) {
   fields := toml.parse_text(os.read_file(source.path)!)!.to_any().as_map()
   for category,policies in (fields['policies'] or {toml.Any(map[string]toml.Any{})}).as_map() {
    for id,_ in policies.as_map() {
     if category+'/'+id in (defs['policies'] or {[]string{}}) {return error('adoption_shared_policy_forbidden')}
    }
   }
   continue
  }
  doc := toml.parse_text(os.read_file(source.path)!)!
  fields := doc.to_any().as_map()
  for id,_ in (fields['engines'] or {toml.Any(map[string]toml.Any{})}).as_map() {if id !in p.adopt_engines {return error('adoption_shared_directory_forbidden')}}
 }
}

fn remove_adopted_definitions(text string,p Payload) !string {
 defs := adoption_definitions(p)!
 mut data := toml.parse_text(text)!.to_any().as_map()
 mut changed := false
 for domain in ['listeners','engines','adapters'] {
  mut values := (data[domain] or {toml.Any(map[string]toml.Any{})}).as_map()
  for id in defs[domain] or {[]string{}} {
   if id in values {values.delete(id);changed=true}
  }
  if values.len == 0 {data.delete(domain)} else {data[domain]=toml.Any(values)}
 }
 if pipes := data['pipelines'] {
  original := pipes.array()
  keep := original.filter(it.value('id').string() !in (defs['pipelines'] or {[]string{}}))
  if keep.len != original.len {changed=true;data['pipelines']=toml.Any(keep)}
 }
 if !changed {return text}
 return encode_config(data)
}

fn adoption_files(p Payload,root string,installation Installation) ![]File {
 remote := merged_config(os.join_path(root,'vhttpd.toml'))!
 mut kept := []string{}
 mut files := p.files.clone()
 for i,file in files {
  if file.path !in p.configs {continue}
  mut doc := toml.parse_text(base64.decode_str(file.data))!.to_any().as_map()
  if declared := doc['policies'] {
   existing := (remote['policies'] or {toml.Any(map[string]toml.Any{})}).as_map()
   mut policies := declared.as_map().clone()
   for category,values in policies {
    old := (existing[category] or {toml.Any(map[string]toml.Any{})}).as_map()
    mut entries := values.as_map().clone()
    for id,_ in entries {entries[id]=old[id] or {return error('adoption_policy_mismatch')}}
    policies[category]=toml.Any(entries)
   }
   doc['policies']=toml.Any(policies)
  }
  text := encode_config(overlay(toml.Any(doc),toml.Any(remote),[],[],mut kept)!.as_map())!
  files[i]=File{...file,data:base64.encode_str(text),hash:sha256.hexhash(text)}
 }
 return component_update_files(Payload{...p,files:files},root,installation)
}
