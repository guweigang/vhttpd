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
	js_err := ctx.js_exception()
	js_msg := js_err.msg().trim_space()
	if js_msg != '' && js_msg != '{}' {
		return js_msg
	}

	val := ctx.js_exception_value()
	defer {
		val.free()
	}
	json_msg := val.json_stringify()
	if json_msg != '' && json_msg != 'undefined' && json_msg != 'null' && json_msg != '{}' {
		eprintln('[vhttpd] DEBUG: captured raw js exception json=${json_msg}')
		return json_msg
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
