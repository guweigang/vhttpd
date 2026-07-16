module main

import runtime_plan

struct AdminRuntimeGraphNode {
pub:
	id       string
	ref      string
	domain   string
	label    string
	kind     string
	group    string
	status   string
	metadata map[string]string
}

struct AdminRuntimeGraphEdge {
pub:
	id       string
	from     string
	to       string
	kind     string
	metadata map[string]string
}

struct AdminRuntimeGraph {
pub:
	nodes []AdminRuntimeGraphNode
	edges []AdminRuntimeGraphEdge
}

fn (app App) admin_runtime_graph_snapshot() AdminRuntimeGraph {
	plan := app.plan
	mut graph := AdminRuntimeGraphBuilder.new()
	for id, listener in plan.listeners {
		graph.node('listener', id, listener.id, listener.protocol, '', {
			'transport': listener.transport
			'host':      listener.host
			'port':      '${listener.port}'
			'tls':       '${listener.tls.enabled}'
		})
	}
	for id, resource in plan.resources {
		graph.node('resource', id, resource.id, resource.kind, resource.category,
			map[string]string{})
	}
	for id, engine in plan.engines {
		graph.node('engine', id, engine.id, engine.kind, '', {
			'capabilities': engine.capabilities.join(',')
		})
		for resource_ref in engine.resources {
			graph.ref_edge('engine_uses_resource', 'engine:${id}', resource_ref.str())
		}
	}
	for id, adapter in plan.adapters {
		graph.node('adapter', id, adapter.id, adapter.kind, '', map[string]string{})
		if engine_ref := adapter.engine {
			graph.ref_edge('adapter_uses_engine', 'adapter:${id}', engine_ref.str())
		}
		if storage_ref := adapter.storage {
			graph.ref_edge('adapter_uses_storage', 'adapter:${id}', storage_ref.str())
		}
		graph.option_ref_edges('adapter_uses_relay', 'adapter:${id}', adapter.options, [
			'target',
			'relay',
		])
		graph.option_ref_edges('adapter_routes_to_pipeline', 'adapter:${id}', adapter.options, [
			'completed_pipeline',
			'pipeline',
		])
	}
	for id, transform in plan.transforms {
		graph.node('transform', id, transform.id, transform.kind, '', {
			'handler': transform.handler
		})
		if engine_ref := transform.engine {
			graph.ref_edge('transform_uses_engine', 'transform:${id}', engine_ref.str())
		}
	}
	for id, policy in plan.policies {
		graph.node('policy', id, policy.id, policy.kind, policy.category, map[string]string{})
	}
	for id, provider in plan.providers {
		graph.node('provider', id, provider.id, provider.protocol, provider.driver, {
			'plugin': provider.plugin
		})
		if engine_ref := provider.engine {
			graph.ref_edge('provider_uses_engine', 'provider:${id}', engine_ref.str())
		}
	}
	for id, relay_plan in plan.relays {
		graph.node('relay', id, relay_plan.id, relay_plan.mode, relay_plan.carrier,
			map[string]string{})
		if ingress_ref := relay_plan.ingress {
			graph.ref_edge('relay_ingress', 'relay:${id}', ingress_ref.str())
		}
		if auth_ref := relay_plan.auth {
			graph.ref_edge('relay_uses_auth', 'relay:${id}', auth_ref.str())
		}
	}
	for pipeline in plan.pipelines {
		pipeline_ref := 'pipeline:${pipeline.id}'
		graph.node('pipeline', pipeline.id, pipeline.id, 'pipeline', pipeline.group, {
			'methods':      pipeline.match.methods.join(',')
			'hosts':        pipeline.match.hosts.join(',')
			'paths':        pipeline.match.paths.join(',')
			'path_regexp':  pipeline.match.path_regexp
			'path_regexps': pipeline.match.path_regexps.join(',')
		})
		graph.ref_edge('ingress', pipeline.ingress.str(), pipeline_ref)
		for transform_ref in pipeline.transforms {
			graph.ref_edge('uses_transform', pipeline_ref, transform_ref.str())
		}
		for policy_ref in pipeline.policies {
			graph.ref_edge('uses_policy', pipeline_ref, policy_ref.str())
		}
		graph.ref_edge('egress', pipeline_ref, pipeline.egress.str())
	}
	return graph.finish()
}

struct AdminRuntimeGraphBuilder {
mut:
	nodes      []AdminRuntimeGraphNode
	edges      []AdminRuntimeGraphEdge
	seen_nodes map[string]bool
	seen_edges map[string]bool
}

fn AdminRuntimeGraphBuilder.new() AdminRuntimeGraphBuilder {
	return AdminRuntimeGraphBuilder{
		seen_nodes: map[string]bool{}
		seen_edges: map[string]bool{}
	}
}

fn (mut builder AdminRuntimeGraphBuilder) node(domain string, id string, label string, kind string, group string, metadata map[string]string) {
	ref := '${domain}:${id}'
	if builder.seen_nodes[ref] {
		return
	}
	builder.seen_nodes[ref] = true
	builder.nodes << AdminRuntimeGraphNode{
		id:       id
		ref:      ref
		domain:   domain
		label:    if label != '' { label } else { id }
		kind:     kind
		group:    group
		status:   'configured'
		metadata: metadata.clone()
	}
}

fn (mut builder AdminRuntimeGraphBuilder) ref_edge(kind string, from string, to string) {
	from_ref := normalize_runtime_graph_ref(from)
	to_ref := normalize_runtime_graph_ref(to)
	if from_ref == '' || to_ref == '' {
		return
	}
	id := '${kind}:${from_ref}->${to_ref}'
	if builder.seen_edges[id] {
		return
	}
	builder.seen_edges[id] = true
	builder.edges << AdminRuntimeGraphEdge{
		id:       id
		from:     from_ref
		to:       to_ref
		kind:     kind
		metadata: map[string]string{}
	}
}

fn (mut builder AdminRuntimeGraphBuilder) option_ref_edges(kind string, from string, options runtime_plan.PlanOptions, keys []string) {
	for key in keys {
		if value := options.strings[key] {
			if value.contains(':') {
				builder.ref_edge(kind, from, value)
			}
		}
	}
}

fn (builder AdminRuntimeGraphBuilder) finish() AdminRuntimeGraph {
	mut nodes := builder.nodes.clone()
	mut edges := builder.edges.clone()
	nodes.sort(a.ref < b.ref)
	edges.sort(a.id < b.id)
	return AdminRuntimeGraph{
		nodes: nodes
		edges: edges
	}
}

fn normalize_runtime_graph_ref(raw string) string {
	clean := raw.trim_space()
	if clean == '' || !clean.contains(':') {
		return ''
	}
	return clean
}
