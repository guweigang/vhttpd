module ws

struct ConnectionIdentityFixture {
	hub &HubState
}

fn connection_identity_batch(fixture ConnectionIdentityFixture) []string {
	mut hub := fixture.hub
	mut ids := []string{cap: 128}
	for _ in 0 .. 128 { ids << hub.next_connection_id() }
	return ids
}

fn test_connection_identity_is_unique_across_concurrent_publishers() {
	fixture := ConnectionIdentityFixture{ hub: &HubState{} }
	mut batches := []thread []string{}
	for _ in 0 .. 8 { batches << spawn connection_identity_batch(fixture) }
	mut seen := map[string]bool{}
	for batch in batches {
		for id in batch.wait() {
			assert id != ''
			assert id !in seen
			seen[id] = true
		}
	}
	assert seen.len == 1024
}
