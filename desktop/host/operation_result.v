module host

// Domain-specific results survive unrelated refreshes on the same worker.
pub struct OperationResult {
pub:
	sequence   u64
	action     string
	target     string
	preview_id string
	message    string
	error      bool
}
