module main

import runtime_plan
import app_bundle
import application_catalog

fn (app &App) admin_apps_snapshot() application_catalog.Snapshot {
	plan := app.admin_plan_view().plan
 snapshot := admin_apps_from_plan(plan)
 mut groups := snapshot.apps.clone()
 for i, group in snapshot.apps {
  mut identity := app_bundle.ApplicationIdentity{}
  mut identity_error := ''
  for engine in group.engines {
   found := app_bundle.engine_identity(plan.source.config_path,engine.id) or {identity_error='application_identity_unavailable';continue}
   if found.app_id == '' {continue}
   if identity.app_id != '' && (identity.app_id != found.app_id || identity.installation_id != found.installation_id) {identity_error='application_binding_ambiguous';break}
   identity=found
  }
  groups[i]=application_catalog.Application{...group,identity:if identity_error == '' {identity} else {app_bundle.ApplicationIdentity{}},identity_error:identity_error}
 }
 return application_catalog.Snapshot{...snapshot,apps:groups}
}

fn admin_apps_from_plan(plan runtime_plan.RuntimePlan) application_catalog.Snapshot {
	return application_catalog.from_plan(plan)
}
