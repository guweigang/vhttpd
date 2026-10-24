module executor

import vjsx

pub struct InProcVjsxError {}

fn InProcVjsxError.should_retry_dispatch(err_msg string) bool {
	return err_msg.starts_with('inproc_vjsx_executor_runtime_create_failed:')
}

pub fn InProcVjsxError.normalize_message(err_msg string, fallback string) string {
	normalized := err_msg.trim_space()
	if normalized != '' && normalized != '{}' {
		return normalized
	}
	return fallback
}

fn InProcVjsxError.context_message(ctx &vjsx.Context, err_msg string, fallback string) string {
	// Take the exception once. SDK calls may already have consumed the slot;
	// converting its empty value would hide the supplied V error.
	val := ctx.js_exception_value()
	defer { val.free() }
	if !val.is_null() && !val.is_undefined() && !val.is_uninitialized() {
		js_msg := val.to_error().msg().trim_space()
		// Diagnostic coercion can itself throw. It must not leave a new error
		// owned by the context after the original has been consumed.
		inspection_error := ctx.js_exception_value()
		inspection_error.free()
		if js_msg != '' && js_msg != '{}'
			&& (js_msg != '[object Object]' || !val.is_object()) {
			return js_msg
		}
		json_msg := val.json_stringify()
		serialization_error := ctx.js_exception_value()
		serialization_error.free()
		if json_msg != '' && json_msg != 'undefined' && json_msg != 'null' && json_msg != '{}' {
			return json_msg
		}
	}

	normalized := InProcVjsxError.normalize_message(err_msg, '')
	if normalized != '' {
		return normalized
	}
	return fallback
}

fn InProcVjsxError.not_ready(op string) IError {
	return error('inproc_vjsx_executor_not_ready:${op}')
}
