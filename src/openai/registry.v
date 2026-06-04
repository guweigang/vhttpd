module openai

import time

// response_registry_record builds an OpenAIResponseRecord from a resolved plan and body.
pub fn response_registry_record(plan OpenAIResolvedPlan, response_id string, body string, req_id string, trace_id string) OpenAIResponseRecord {
	now := time.now().unix()
	status := response_status_from_body(body)
	return OpenAIResponseRecord{
		id:              response_id
		backend_name:    plan.backend_name
		backend_kind:    plan.backend.kind
		executor:        plan.backend.executor
		model:           plan.model
		status:          if status == '' { 'completed' } else { status }
		created_at_unix: now
		updated_at_unix: now
		request_id:      req_id
		trace_id:        trace_id
		body:            body
	}
}
