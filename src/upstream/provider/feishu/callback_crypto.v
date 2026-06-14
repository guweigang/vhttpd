module feishu

import crypto.aes
import crypto.cipher
import crypto.sha256
import encoding.base64
import x.json2

// ── Callback Crypto ──

pub fn CallbackChallengeResponse.challenge(payload string) string {
	parsed := json2.decode[json2.Any](payload) or { return '' }
	root := parsed.as_map()
	if JsonField.string(root, 'type') != 'url_verification' {
		return ''
	}
	return JsonField.string(root, 'challenge')
}

pub fn CallbackChallengeResponse.pkcs7_unpad(data []u8) ![]u8 {
	if data.len == 0 {
		return error('empty encrypted payload')
	}
	padding := int(data[data.len - 1])
	if padding <= 0 || padding > aes.block_size || padding > data.len {
		return error('invalid pkcs7 padding')
	}
	for i in data.len - padding .. data.len {
		if int(data[i]) != padding {
			return error('invalid pkcs7 padding')
		}
	}
	return data[..data.len - padding].clone()
}

pub fn CallbackChallengeResponse.signature_valid(headers map[string]string, encrypt_key string, payload string) bool {
	mut signature := (headers['x-lark-signature'] or { '' }).trim_space().to_lower()
	if signature == '' {
		signature = (headers['x-lark-request-signature'] or { '' }).trim_space().to_lower()
	}
	if signature == '' {
		return encrypt_key.trim_space() == ''
	}
	timestamp := (headers['x-lark-request-timestamp'] or { '' }).trim_space()
	nonce := (headers['x-lark-request-nonce'] or { '' }).trim_space()
	if timestamp == '' || nonce == '' || encrypt_key.trim_space() == '' {
		return false
	}
	expected := sha256.sum('${timestamp}${nonce}${encrypt_key}${payload}'.bytes()).hex().to_lower()
	return signature == expected
}

pub fn CallbackChallengeResponse.decrypt_payload(encrypt_key string, payload string) !string {
	if encrypt_key.trim_space() == '' {
		return payload
	}
	parsed := json2.decode[json2.Any](payload) or { return payload }
	root := parsed.as_map()
	encrypted := JsonField.string(root, 'encrypt')
	if encrypted == '' {
		return payload
	}
	ciphertext := base64.decode(encrypted)
	if ciphertext.len < aes.block_size || ciphertext.len % aes.block_size != 0 {
		return error('invalid feishu encrypted payload length')
	}
	key := sha256.sum(encrypt_key.bytes())
	iv := key[..aes.block_size].clone()
	mut block := aes.new_cipher(key)
	mut mode := cipher.new_cbc(block, iv)
	mut plaintext := []u8{len: ciphertext.len}
	mode.decrypt_blocks(mut plaintext, ciphertext)
	unpadded := CallbackChallengeResponse.pkcs7_unpad(plaintext)!
	return unpadded.bytestr()
}
