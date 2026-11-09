module devmcp

fn source_workspace_tool_specs() []ToolSpec {
	return [
		ToolSpec{ name: 'source_workspace_get', description: 'Read the Desktop-authorized source workspace binding and configuration readiness. Works without installation or a TOML entry. No filesystem paths or credentials are exposed.', read_only: true },
		ToolSpec{ name: 'source_workspace_prepare', description: 'Prepare binding an existing directory inside the Desktop-authorized source root, in place without installing or copying the project. directory defaults to dot; entry defaults to vhttpd.toml and may be absent. Optional vjsx template initialization requires an entirely empty directory. Returns a revision-guarded five-minute plan; writes only private staging files.', properties: '{"directory":{"type":"string"},"entry":{"type":"string"},"template":{"type":"string","enum":["vjsx-http","vjsx-api","environment"]}}' },
		ToolSpec{ name: 'source_workspace_bind', description: 'Apply a source binding plan while the owned runtime is stopped. Rechecks directory identity and revisions; optional scaffold creates files exclusively. Never installs an application. Returns a new binding_revision; reread context. Restore/discard applied edits before rebinding.', properties: '{"id":{"type":"string"}}', required: '["id"]' },
		ToolSpec{ name: 'source_workspace_unbind', description: 'Release this source binding without deleting or changing source files. Runtime must be stopped and applied edits restored or explicitly discarded. Invalidates old bindings and previews; Desktop directory authorization remains for a fresh plan.' },
	]
}
