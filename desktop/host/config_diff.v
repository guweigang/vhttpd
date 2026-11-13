module host

import config
import crypto.sha256
import os

struct ConfigRevision {
	source config.RuntimeConfigSource
	hash string
}

pub struct ConfigFileDiff {
pub:
	path string
	change string
	relays []string
	pipelines []string
	editable bool
}

fn config_revisions(path string) ![]ConfigRevision {
	mut revisions := []ConfigRevision{}
	for source in config.runtime_config_sources(path)! {
		revisions << ConfigRevision{source: source, hash: sha256.sum(os.read_bytes(source.path)!).hex()}
	}
	return revisions
}

fn config_file_diffs(before []ConfigRevision, after []ConfigRevision) []ConfigFileDiff {
	mut result := []ConfigFileDiff{}
	for old in before {
		next := after.filter(it.source.path == old.source.path)
		if next.len > 0 && next[0].hash == old.hash { continue }
		mut relays := old.source.relay_ids.clone()
		mut pipelines := old.source.pipeline_ids.clone()
		if next.len > 0 {
			for id in next[0].source.relay_ids { if id !in relays { relays << id } }
			for id in next[0].source.pipeline_ids { if id !in pipelines { pipelines << id } }
		}
		result << ConfigFileDiff{path: old.source.path, change: if next.len == 0 { '移出项目' } else { '已修改' }, relays: relays, pipelines: pipelines, editable: next.len > 0}
	}
	for next in after {
		if before.any(it.source.path == next.source.path) { continue }
		result << ConfigFileDiff{path: next.source.path, change: '新加入', relays: next.source.relay_ids.clone(), pipelines: next.source.pipeline_ids.clone(), editable: true}
	}
	return result
}

fn affected_config_sources(before []ConfigRevision, after []ConfigRevision, relays []string, pipelines []string) []ConfigFileDiff {
	mut result := []ConfigFileDiff{}
	for revision in after {
		mut ids := revision.source.relay_ids.clone()
		mut pids := revision.source.pipeline_ids.clone()
		for old in before.filter(it.source.path == revision.source.path) {
			for id in old.source.relay_ids { if id !in ids { ids << id } }
			for id in old.source.pipeline_ids { if id !in pids { pids << id } }
		}
		r := ids.filter(it in relays)
		p := pids.filter(it in pipelines)
		if r.len + p.len == 0 { continue }
		result << ConfigFileDiff{path: revision.source.path, change: '受影响组件来源', relays: r, pipelines: p, editable: true}
	}
	for revision in before {
		if after.any(it.source.path == revision.source.path) { continue }
		r := revision.source.relay_ids.filter(it in relays)
		p := revision.source.pipeline_ids.filter(it in pipelines)
		if r.len + p.len == 0 { continue }
		result << ConfigFileDiff{path: revision.source.path, change: '原组件来源（已移出项目）', relays: r, pipelines: p}
	}
	return result
}
