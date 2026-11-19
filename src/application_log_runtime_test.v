module main

import runtime_plan

fn test_application_log_ownership_follows_pipeline_group_and_shared_engine_is_unassigned() {
 plan := runtime_plan.RuntimePlan{
  adapters:{'handler':runtime_plan.AdapterPlan{engine:runtime_plan.ResourceRef{domain:.engine,id:'shared'}}}
  pipelines:[
   runtime_plan.PipelinePlan{id:'a',group:'wechat',ingress:runtime_plan.ResourceRef{domain:.listener,id:'same'},egress:runtime_plan.ResourceRef{domain:.adapter,id:'handler'}},
   runtime_plan.PipelinePlan{id:'b',group:'paseo',ingress:runtime_plan.ResourceRef{domain:.listener,id:'same'},egress:runtime_plan.ResourceRef{domain:.adapter,id:'handler'}}
  ]
 }
 scopes := application_log_scopes(plan)
 assert scopes['pipeline:a'].app_id == 'wechat'
 assert scopes['pipeline:b'].app_id == 'paseo'
 assert scopes['engine:shared'].app_id == ''
 assert scopes['listener:same'].app_id == ''
}

fn test_relay_takeover_pipeline_belongs_to_existing_engine_application() {
 plan := runtime_plan.RuntimePlan{
  adapters:{'app':runtime_plan.AdapterPlan{engine:runtime_plan.ResourceRef{domain:.engine,id:'wechat'}}}
  pipelines:[
   runtime_plan.PipelinePlan{id:'wechat',ingress:runtime_plan.ResourceRef{domain:.listener,id:'web'},egress:runtime_plan.ResourceRef{domain:.adapter,id:'app'}},
   runtime_plan.PipelinePlan{id:'debug/http',ingress:runtime_plan.ResourceRef{domain:.relay,id:'database'},egress:runtime_plan.ResourceRef{domain:.adapter,id:'app'}}
  ]
 }
 scopes := application_log_scopes(plan)
 assert scopes['pipeline:debug/http'].app_id == 'wechat'
 assert scopes['engine:wechat'].app_id == 'wechat'
}
