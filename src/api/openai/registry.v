module openai

import time
import x.json2

// from_plan builds an OpenAIResponseRecord from a resolved plan and body.
pub fn OpenAIResponseRecord.from_plan(plan OpenAIResolvedPlan, response_id string, body string, req_id string, trace_id string) OpenAIResponseRecord {
	now := time.now().unix()
	status := OpenAIResponseRecord.status_from_body(body)
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

// ── OpenAIResponseRecord Static Methods (body parsing) ──

// id_from_body extracts the response ID from a JSON response body.
pub fn OpenAIResponseRecord.id_from_body(body string) string {
	parsed := json2.decode[json2.Any](body) or { return '' }
	root := parsed.as_map()
	if (root['object'] or { json2.Any('') }).str() != 'response' {
		return ''
	}
	return (root['id'] or { json2.Any('') }).str().trim_space()
}

// status_from_body extracts the status field from a JSON response body.
pub fn OpenAIResponseRecord.status_from_body(body string) string {
	parsed := json2.decode[json2.Any](body) or { return '' }
	root := parsed.as_map()
	return (root['status'] or { json2.Any('') }).str()
}

// id_from_relative extracts the response ID from a relative URL path.
pub fn OpenAIResponseRecord.id_from_relative(relative string) string {
	path := relative.all_before('?')
	prefix := '/responses/'
	if !path.starts_with(prefix) {
		return ''
	}
	rest := path[prefix.len..]
	if rest.trim_space() == '' {
		return ''
	}
	return rest.split('/')[0].trim_space()
}
