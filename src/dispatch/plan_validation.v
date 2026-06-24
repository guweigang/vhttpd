module dispatch

import runtime_plan

pub struct RuntimePlanValidationReport {
pub:
	capability_issues []PipelineCapabilityIssue
	diagnostics       []runtime_plan.PlanDiagnostic
}

pub fn validate_runtime_plan_projection(plan runtime_plan.RuntimePlan) RuntimePlanValidationReport {
	issues := pipeline_capability_issues_from_plan(plan)
	return RuntimePlanValidationReport{
		capability_issues: issues
		diagnostics:       pipeline_capability_issues_to_diagnostics(issues)
	}
}

pub fn runtime_plan_projection_diagnostics(plan runtime_plan.RuntimePlan) []runtime_plan.PlanDiagnostic {
	return validate_runtime_plan_projection(plan).diagnostics
}
