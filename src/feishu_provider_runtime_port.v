module main

import encoding.base64
import feishu
import json

fn (mut hub ProviderRuntimeHub) feishu_provider_runtime_send_message(req feishu.SendMessageRequest, mut caller ProviderRuntimePluginCaller) !feishu.SendMessageResult {
	raw := hub.provider_runtime_call(ProviderRuntimeInvocation{
		provider: 'feishu'
		action:   'send_message'
		payload:  json.encode(req)
	}, mut caller)!
	result := json.decode(feishu.SendMessageResult, raw) or {
		return error('provider_runtime_driver_invalid_result:feishu:send_message:${err.msg()}')
	}
	if !result.ok && result.error.trim_space() != '' {
		return error('provider_runtime_driver_failed:feishu:send_message:${result.error}')
	}
	return result
}

fn (mut hub ProviderRuntimeHub) feishu_provider_runtime_update_message(req feishu.UpdateMessageRequest, mut caller ProviderRuntimePluginCaller) !feishu.SendMessageResult {
	raw := hub.provider_runtime_call(ProviderRuntimeInvocation{
		provider: 'feishu'
		action:   'update_message'
		payload:  json.encode(req)
	}, mut caller)!
	result := json.decode(feishu.SendMessageResult, raw) or {
		return error('provider_runtime_driver_invalid_result:feishu:update_message:${err.msg()}')
	}
	if !result.ok && result.error.trim_space() != '' {
		return error('provider_runtime_driver_failed:feishu:update_message:${result.error}')
	}
	return result
}

fn (mut hub ProviderRuntimeHub) feishu_provider_runtime_upload_image(req feishu.UploadImageRequest, mut caller ProviderRuntimePluginCaller) !feishu.UploadImageResult {
	raw := hub.provider_runtime_call(ProviderRuntimeInvocation{
		provider: 'feishu'
		action:   'upload_image'
		payload:  json.encode(req)
	}, mut caller)!
	result := json.decode(feishu.UploadImageResult, raw) or {
		return error('provider_runtime_driver_invalid_result:feishu:upload_image:${err.msg()}')
	}
	if !result.ok && result.error.trim_space() != '' {
		return error('provider_runtime_driver_failed:feishu:upload_image:${result.error}')
	}
	return result
}

fn (mut hub ProviderRuntimeHub) feishu_provider_runtime_upload_image_bytes(req feishu.UploadImageRequest, data []u8, mut caller ProviderRuntimePluginCaller) !feishu.UploadImageResult {
	mut content_length := data.len
	if req.content_length > 0 {
		content_length = req.content_length
	}
	return hub.feishu_provider_runtime_upload_image(feishu.UploadImageRequest{
		app:            req.app
		image_type:     req.image_type
		filename:       req.filename
		content_type:   req.content_type
		data_base64:    base64.encode(data)
		content_length: content_length
	}, mut caller)
}
