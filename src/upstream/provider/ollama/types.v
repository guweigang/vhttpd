module ollama

// OllamaNdjsonMessage represents the "message" field of an Ollama NDJSON row.
pub struct OllamaNdjsonMessage {
pub:
	content string
}

// OllamaNdjsonRow represents a single NDJSON line from the Ollama API.
pub struct OllamaNdjsonRow {
pub:
	message  OllamaNdjsonMessage
	response string
	done     bool
}

// field extracts a piece from an NDJSON row by path.
pub fn (row OllamaNdjsonRow) field(path string) string {
	return match path {
		'message.content' { row.message.content }
		'response' { row.response }
		else { '' }
	}
}
