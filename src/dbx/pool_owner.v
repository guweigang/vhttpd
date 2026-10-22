module dbx

import provider
import sync
import time

// The callbacks belong to the published resource, so every operation and its
// cleanup use the same driver implementation even after a stop is requested.
pub struct PoolFactory {
pub:
	open_fn fn (provider.DbRuntimeSettings) !PoolHandle @[required]
	close_fn fn (mut PoolHandle) @[required]
	acquire_fn fn (PoolHandle, fn () bool) !SessionHandle @[required]
	release_fn fn (PoolHandle, SessionHandle) @[required]
	connect_fn fn (provider.DbRuntimeSettings) !SessionHandle @[required]
	close_connection_fn fn (mut SessionHandle) @[required]
}

@[heap]
struct OwnedPool {
	factory PoolFactory @[required]
	settings provider.DbRuntimeSettings @[required]
mut:
	handle PoolHandle
}

@[heap]
struct PoolBuild {
mut:
	done bool
	failure string
}

@[heap]
pub struct PoolOwner {
mut:
	mu sync.Mutex
	generation u64
	stopping bool
	closing bool
	closed bool
	activities int
	borrowed int
	resource ?&OwnedPool
	building ?&PoolBuild
}

struct PoolUse {
	resource &OwnedPool @[required]
	generation u64
}

pub fn (mut owner PoolOwner) is_ready() bool {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	return owner.resource != none
}

pub fn (mut owner PoolOwner) request_stop() {
	owner.mu.@lock()
	owner.stopping = true
	owner.mu.unlock()
}

// Listener generation ownership ensures reopen follows the old run's cleanup.
// A cancelled startup with no resources also permits a fresh generation.
pub fn (mut owner PoolOwner) reopen() bool {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	if !owner.stopping { return true }
	if owner.closing || owner.activities > 0 || owner.resource != none { return false }
	owner.generation++
	owner.borrowed = 0
	owner.stopping = false
	owner.closed = false
	return true
}

pub fn (mut owner PoolOwner) ensure(settings provider.DbRuntimeSettings, factory PoolFactory) ! {
	owner.mu.@lock()
	if owner.stopping { owner.mu.unlock(); return error('db_stopping') }
	if owner.resource != none { owner.mu.unlock(); return }
	if pending := owner.building {
		owner.mu.unlock()
		owner.wait_build(pending)!
		return
	}
	mut build := &PoolBuild{}
	owner.building = build
	owner.activities++
	generation := owner.generation
	owner.mu.unlock()
	mut failure := ''
	defer {
		owner.mu.@lock()
		build.failure = failure
		build.done = true
		owner.building = none
		owner.activities--
		owner.mu.unlock()
	}
	pool := factory.open_fn(settings) or { failure = err.msg(); return err }
	mut candidate := &OwnedPool{factory: factory, settings: settings, handle: pool}
	owner.mu.@lock()
	publish := !owner.stopping && owner.generation == generation
	if publish { owner.resource = candidate }
	owner.mu.unlock()
	if !publish {
		// The pending build stays active until rejected candidate cleanup ends.
		factory.close_fn(mut candidate.handle)
		failure = 'db_stopping'
		return error(failure)
	}
}

fn (mut owner PoolOwner) wait_build(build &PoolBuild) ! {
	for {
		owner.mu.@lock()
		stopping := owner.stopping
		done := build.done
		failure := build.failure
		owner.mu.unlock()
		if stopping { return error('db_stopping') }
		if done {
			if failure != '' { return error(failure) }
			return
		}
		time.sleep(time.millisecond)
	}
}


fn (mut owner PoolOwner) finish_use() {
	owner.mu.@lock()
	owner.activities--
	owner.mu.unlock()
}

// A lease retains its originating resource and generation through transactions.
// Restart cannot redirect an old return or refill into the replacement pool.
struct PoolOrigin {
	owner &PoolOwner @[required]
	resource &OwnedPool @[required]
	generation u64
	permit &PoolPermit @[required]
}

@[heap]
struct PoolPermit {
	owner &PoolOwner @[required]
	generation u64
mut:
	done bool
	refill_started bool
}

fn (mut permit PoolPermit) finish() {
	mut owner := permit.owner
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	if permit.done { return }
	permit.done = true
	if owner.generation == permit.generation { owner.borrowed-- }
}

pub fn (mut owner PoolOwner) acquire() !&ConnectionLease {
	owner.mu.@lock()
	generation := owner.generation
	owner.mu.unlock()
	for {
		owner.mu.@lock()
		if owner.stopping || owner.closing || owner.closed || owner.generation != generation {
			owner.mu.unlock()
			return error('db_stopping')
		}
		resource := owner.resource or { owner.mu.unlock(); return error('db_pool_unavailable') }
		capacity := if resource.settings.pool_size > 0 { resource.settings.pool_size } else { 5 }
		if owner.borrowed >= capacity {
			owner.mu.unlock()
			time.sleep(time.millisecond)
			continue
		}
		owner.borrowed++
		owner.activities++
		owner.mu.unlock()
		defer { owner.finish_use() }
		mut permit := &PoolPermit{owner: owner, generation: generation}
		should_stop := fn [mut owner, generation] () bool { return owner.stopped_generation(generation) }
		mut conn := resource.factory.acquire_fn(resource.handle, should_stop) or { permit.finish(); return err }
		owner.mu.@lock()
		admitted := !owner.stopping && !owner.closing && !owner.closed && owner.generation == generation
		owner.mu.unlock()
		if !admitted {
			// Keep the acquisition active until the late connection is disposed.
			defer { permit.finish() }
			resource.factory.close_connection_fn(mut conn)
			return error('db_stopping')
		}
		return &ConnectionLease{
			connection: conn
			pool_origin: PoolOrigin{owner: owner, resource: resource, generation: generation, permit: permit}
		}
	}
}

fn (mut owner PoolOwner) stopped_generation(generation u64) bool {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	return owner.stopping || owner.closed || owner.generation != generation
}

fn (mut owner PoolOwner) origin_use(origin PoolOrigin, returning bool) !PoolUse {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	if owner.generation != origin.generation || owner.closing || owner.closed
		|| (owner.stopping && !returning) { return error('db_stopping') }
	resource := owner.resource or { return error('db_pool_unavailable') }
	if voidptr(resource) != voidptr(origin.resource) { return error('db_stopping') }
	owner.activities++
	return PoolUse{resource: resource, generation: owner.generation}
}

fn (origin PoolOrigin) return_connection(conn SessionHandle) {
	mut permit := origin.permit
	defer { permit.finish() }
	mut owner := origin.owner
	use := owner.origin_use(origin, true) or {
		mut owned := conn
		origin.resource.factory.close_connection_fn(mut owned)
		return
	}
	defer { owner.finish_use() }
	use.resource.factory.release_fn(use.resource.handle, conn)
}

fn (origin PoolOrigin) refill() ! {
	mut owner := origin.owner
	mut permit := origin.permit
	owner.mu.@lock()
	if owner.stopping || owner.generation != origin.generation { owner.mu.unlock(); return error('db_stopping') }
	if !permit.done { owner.mu.unlock(); return error('db_connection_not_retired') }
	if permit.refill_started { owner.mu.unlock(); return error('db_pool_refill_already_requested') }
	permit.refill_started = true
	owner.mu.unlock()
	use := owner.origin_use(origin, false)!
	defer { owner.finish_use() }
	settings := use.resource.settings
	mut conn := use.resource.factory.connect_fn(provider.DbRuntimeSettings{...settings, pool_size: 1})!
	owner.mu.@lock()
	mut publish := false
	if resource := owner.resource {
		publish = !owner.stopping && owner.generation == use.generation
			&& voidptr(resource) == voidptr(use.resource)
	}
	owner.mu.unlock()
	if !publish {
		use.resource.factory.close_connection_fn(mut conn)
		return error('db_stopping')
	}
	use.resource.factory.release_fn(use.resource.handle, conn)
}

// Called after listener handlers and transaction owners have drained. Builds
// and refill/driver operations also finish before the native pool is closed.
pub fn (mut owner PoolOwner) close() {
	owner.mu.@lock()
	generation := owner.generation
	owner.stopping = true
	if owner.closed { owner.mu.unlock(); return }
	if owner.closing {
		owner.mu.unlock()
		for {
			owner.mu.@lock()
			done := owner.closed || owner.generation != generation
			owner.mu.unlock()
			if done { return }
			time.sleep(time.millisecond)
		}
	}
	owner.closing = true
	owner.mu.unlock()
	for {
		owner.mu.@lock()
		if owner.activities == 0 { break }
		owner.mu.unlock()
		time.sleep(time.millisecond)
	}
	owned := owner.resource
	owner.resource = none
	owner.mu.unlock()
	if mut resource := owned { resource.factory.close_fn(mut resource.handle) }
	owner.mu.@lock()
	owner.closed = true
	owner.closing = false
	owner.mu.unlock()
}

$if enable_db ? {
	pub fn PoolFactory.native() PoolFactory {
		return PoolFactory{
			open_fn: native_pool_open
			close_fn: native_pool_close
			acquire_fn: native_pool_acquire
			release_fn: native_pool_release
			connect_fn: native_pool_replacement
			close_connection_fn: native_connection_close
		}
	}
	fn native_pool_open(settings provider.DbRuntimeSettings) !PoolHandle { return PoolHandle.open(settings)! }
	fn native_pool_close(mut pool PoolHandle) { pool.close() }
	fn native_pool_acquire(pool PoolHandle, should_stop fn () bool) !SessionHandle { mut borrowed := pool; return borrowed.acquire_until(should_stop)! }
	fn native_pool_release(pool PoolHandle, conn SessionHandle) { mut borrowed := pool; borrowed.release(conn) }
	fn native_connection_close(mut conn SessionHandle) { conn.close() or {} }
	fn native_pool_replacement(settings provider.DbRuntimeSettings) !SessionHandle {
		mut temporary := PoolHandle.open(settings)!
		defer { temporary.close() }
		return temporary.acquire()!
	}
}
