module dispatch

import runtime_plan

pub struct RuntimePlanValidationReport {
pub:
	capability_issues []PipelineCapabilityIssue
	diagnostics       []runtime_plan.PlanDiagnostic
}

pub fn validate_runtime_plan_projection(plan runtime_plan.RuntimePlan) RuntimePlanValidationReport {
	issues := pipeline_capability_issues_from_plan(plan)
	reference_diagnostics := pipeline_projection_reference_diagnostics_from_plan(plan)
	return RuntimePlanValidationReport{
		capability_issues: issues
		diagnostics:       pipeline_projection_diagnostics_from_parts(reference_diagnostics, issues)
	}
}

pub fn runtime_plan_projection_diagnostics(plan runtime_plan.RuntimePlan) []runtime_plan.PlanDiagnostic {
	return validate_runtime_plan_projection(plan).diagnostics
}

fn pipeline_projection_diagnostics_from_parts(reference_diagnostics []runtime_plan.PlanDiagnostic, issues []PipelineCapabilityIssue) []runtime_plan.PlanDiagnostic {
	mut diagnostics := reference_diagnostics.clone()
	diagnostics << pipeline_capability_issues_to_diagnostics(issues)
	return diagnostics
}

fn pipeline_projection_reference_diagnostics_from_plan(plan runtime_plan.RuntimePlan) []runtime_plan.PlanDiagnostic {
	mut diagnostics := []runtime_plan.PlanDiagnostic{}
	for pipeline in plan.pipelines {
		if !pipeline_projection_ingress_exists(plan, pipeline.ingress) {
			diagnostics << runtime_plan.PlanDiagnostic{
				severity: 'error'
				code:     'pipeline_projection_missing_ingress'
				path:     'pipelines.${pipeline.id}.ingress'
				message:  'pipeline ${pipeline.id} references missing ingress ${pipeline.ingress.str()}'
			}
		}
		for reference in pipeline.transforms {
			if reference.domain != .transform {
				diagnostics << runtime_plan.PlanDiagnostic{
					severity: 'error'
					code:     'pipeline_projection_invalid_transform_ref'
					path:     'pipelines.${pipeline.id}.transforms'
					message:  'pipeline ${pipeline.id} uses non-transform reference ${reference.str()} as transform'
				}
				continue
			}
			if reference.id !in plan.transforms {
				diagnostics << runtime_plan.PlanDiagnostic{
					severity: 'error'
					code:     'pipeline_projection_missing_transform'
					path:     'pipelines.${pipeline.id}.transforms'
					message:  'pipeline ${pipeline.id} references missing transform ${reference.str()}'
				}
			}
		}
		if !pipeline_projection_egress_exists(plan, pipeline.egress) {
			diagnostics << runtime_plan.PlanDiagnostic{
				severity: 'error'
				code:     'pipeline_projection_missing_egress'
				path:     'pipelines.${pipeline.id}.egress'
				message:  'pipeline ${pipeline.id} references missing egress ${pipeline.egress.str()}'
			}
		}
	}
	return diagnostics
}

fn pipeline_projection_ingress_exists(plan runtime_plan.RuntimePlan, reference runtime_plan.ResourceRef) bool {
	return match reference.domain {
		.listener {
			reference.id in plan.listeners
		}
		.adapter {
			adapter := plan.adapters[reference.id] or { return false }
			adapter.kind == 'event-ingress'
		}
		.relay {
			reference.id in plan.relays
		}
		.provider {
			reference.id in plan.providers
		}
		else {
			false
		}
	}
}

fn pipeline_projection_egress_exists(plan runtime_plan.RuntimePlan, reference runtime_plan.ResourceRef) bool {
	return match reference.domain {
		.adapter { reference.id in plan.adapters }
		.terminal { terminal_descriptor(reference.id) != none }
		else { false }
	}
}
