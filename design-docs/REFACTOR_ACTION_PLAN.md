# vhttpd Refactor Action Plan

This plan turns the prioritized findings in [`CODE_REVIEW_2026_08_06.md`](CODE_REVIEW_2026_08_06.md) §4 into a concrete, sequenced work list. Each milestone lists its scope, the files it touches, the verification signal, and the rollback strategy.

Track this file as milestones complete; cross-link any deviation back to the review.

## Progress — 2026-10-14

The V3 compatibility baseline is established. The first Milestone 1 slice removes the unsafe `AppFacadeWrapper`: `App` now implements `executor.AppFacade` directly in `src/app_executor_facade.v`, while transitional executor aliases and factory helpers live in `src/executor_types.v`. `src/executor_bridge.v` is deleted. The two new facade regressions verify that configuration updates remain visible and mutations affect the original App rather than a boxed copy. `make lint-safety` runs before `test-fast` and rejects raw App casts in the executor facade; provider callback casts remain a separate migration.

**Deviation from the original Milestone 1 plan:** V3 compiles the direct typed interface successfully, so the current slice preserves the existing live-reference capability contracts instead of replacing them with snapshots. This avoids stale configuration during runtime plan replacement. The original [review finding 2.2](CODE_REVIEW_2026_08_06.md) describes the removed workaround. Splitting the remaining broad AppFacade dependency into subsystem-owned capabilities, full-suite validation, and Linux/production validation are still pending; Milestone 1 is not closed.

Validation for this slice: strict V3 build and 206 end-to-end checks pass on macOS (4 CLI checks and 202 config/runtime checks). The facade, executor, and worker integration suites also pass (3 test files, including both new live-reference regressions). `git diff --check` and `make lint-safety` pass. 

### Milestone 2 worker ownership slice — 2026-10-14

Pool selection, queue accounting, process ensure/restart, request accounting, drain/resume, and selection diagnostics now live under `src/worker/` as WorkerState operations. Connection retries and stream/MCP/WebSocket transport dispatch also live in that module with explicit callback contexts. `worker.LifecyclePort` owns the event dependency with a safe no-op default; connector and dispatch callbacks are required at construction.

`EngineRuntime` retains primary/named-pool routing. `src/app_worker_backend.v` collects application adapters and supplies callbacks for events, pool selection, and request completion. Three unused App helpers were removed. `worker.DrainStatus` is shared by worker administration and runtime-plan replacement, with the existing response fields preserved. The core module references neither App nor EngineRuntime; `make lint-safety` now enforces this boundary. Existing mutex acquisition order, queue error classes, and request/release accounting were preserved.

Validation: strict V3 build with DB enabled passes on macOS; 4 integration test files and 3 standalone worker test files pass. New regressions cover concurrent exclusive leasing, busy/draining worker exclusion, drain/resume counters, and immediate queue backpressure. All 206 E2E checks pass (4 CLI plus 202 config/runtime checks), including controlled queue-full, queued completion, timeout, and replacement scenarios. Full-suite and Linux validation remain pending; the VM compiler is unchanged and the mounted checkout contains pre-existing unrelated tracked changes, so the Linux testing skill's preflight stop rule applies.

### Engine administration and executor capabilities — 2026-10-14

WorkerState now owns restart-by-id/restart-all, process and pool snapshots, queue metrics, backend lifecycle context construction/start/stop, and scheme/environment mutation. `src/worker/admin.v`, `metrics.v`, and `backend_lifecycle.v` contain these operations without an admin or application dependency. `EngineRuntime` delegates per-pool operations and retains pool selection and executor orchestration. The application layer projects worker snapshots into the existing admin response types, preserving JSON fields and restart error strings.

The five worker facade ports now store and accept only their corresponding capability interfaces: backend config, sockets, stream, MCP, and WebSocket dispatch. They no longer retain a complete AppFacade. SocketWorkerExecutor and PhpCgiExecutor keep their polymorphic AppFacade entry points as adapters; their HTTP algorithms and the socket WebSocket-open algorithm live in `src/executor/worker_dispatch_core.v`, accepting only WorkerSocketFacade and WorkerBackendConfigFacade. Embedded executor host paths still use the broader facade and remain future work.

Validation: strict V3 build with DB enabled, 8 worker/executor module test files, 4 integration test files, and all 206 E2E checks pass on macOS. New tests exercise hosts implementing only a single capability, live mutation through narrow ports, both HTTP cores without unrelated App capabilities, detached admin snapshots, restart errors, metrics, and lifecycle configuration isolation. Safety lint now prevents complete AppFacade references in worker ports/dispatch core. Full-suite and Linux validation remain pending under the previously recorded VM preflight stop rule.

### Registry lookup and embedded host boundary — 2026-10-14

`src/engine_registry.v` provides a single `lookup_engine` entry point with explicit worker-config, strict executor-kind, dispatch-pool, and drain-pool policies. Configuration getters, socket selection, HTTP kind dispatch, and drain/resume all use it. Existing behavior is preserved: dispatch pools prefer a named key and fall back to primary; worker config gives the primary kind precedence; strict HTTP kind lookup does not add empty-key aliases; drain additionally accepts empty/main/primary aliases. Lookup results retain the original WorkerState and distinguish primary identity from a named pool literally called `main`.

Embedded executor lane state, tasks, request contexts, host APIs, plugins, snapshot/startup paths, and dispatch internals now use `executor.EmbeddedHost`. It composes only runtime configuration, platform events/snapshots, provider bridge, command envelopes, and WebSocket command execution. It has no worker socket/configuration or transport dispatch methods. Seven uniform LogicExecutor entry points keep AppFacade only in `inproc_vjsx_facade_adapter.v`, adapting it to EmbeddedHost once. The internal host and lane references remain live across configuration updates; a JavaScript HTTP test verifies this using a host that implements no worker capabilities. Safety lint prevents broad AppFacade references outside the embedded adapter.

Validation: strict V3 build, 4 executor module test files, 5 registry/worker/executor integration files, and 3 embedded runtime test files pass on macOS. The last group includes all 70 inproc executor test functions plus host API and startup coverage. All 206 E2E checks pass on an isolated rerun. The first E2E run overlapped heavy compilation and missed the provider WebSocket probe's 10-second deadline; it passed with the same binary after that load ended. A pre-existing snapshot assertion assumed JSON object key order; it now decodes the snapshot and asserts the HTTP capability value semantically.

### Optional embedded request-host lookup — 2026-10-14

`src/executor/inproc_vjsx_request_host.v` centralizes host lookup with explicit request-only, lane fallback, and executor fallback policies. It captures the host and request metadata under one state lock and releases that lock before invoking host services. Request context, lane-retained host, and executor-retained host now store `?EmbeddedHost`; empty and destroyed hosts use `none`. Nine unsafe interface nil placeholders are removed from config, emit, bridge/WebSocket dispatch, snapshot, affinity, and actor paths. Request-only APIs stop resolving after request completion; asynchronous WebSocket dispatch retains its lane host without expired trace metadata, while snapshot retains its executor fallback.

Validation: strict V3 build with DB enabled, 4 executor module test files, and 3 embedded integration test files pass on macOS (including all 70 inproc executor functions). New lookup and real JavaScript callback tests cover absent hosts, invalid lane indexes, request precedence, metadata normalization, live host mutations, request clearing, lane destruction, and fallback behavior. Safety lint guards against unsafe host interface placeholders; `git diff --check` passes. All 206 E2E checks pass with the verified binary (4 CLI plus 202 config/runtime checks). Logs are recorded in `tmp/request-host-validation/`.

### Command/provider capability hosts — 2026-10-14

`src/command_host.v` defines required Codex, Feishu, and generic command capabilities. The three handlers no longer store nil App pointers or reference the concrete App type. Feishu buffer state is injected through a typed state accessor; application adapters in `src/app_command_host.v` delegate bridge proxy operations. Existing command routing, target resolution, statuses, and error propagation are preserved.

Feishu bridge client and server callbacks recover heap-allocated, required callback contexts from the WebSocket API's `voidptr`, rather than recovering App. These contexts carry a narrow dispatch/proxy host and a required bridge state reference. Client reconnect/heartbeat and server-session internals use those capabilities; request normalization remains in the App adapter. Provider WebSocket closures capture `ProviderWebSocketHost`; Feishu heartbeat uses FeishuState directly, removing the unsafe App aliases from post-connect closures. OpenAI frame mapping uses an optional single-method mapper host with an explicit missing-host result, and the HTTP progress callback now directly recovers its dedicated stream state instead of manipulating pointer storage. Four unsafe App conversion sites and six nil App/state reference defaults are removed in this slice.

Validation: strict V3 build with DB enabled, 7 command/provider/Feishu/OpenAI test files, and all 6 codexbot-fast files (52 test functions) pass on macOS. New narrow-host regressions cover live command mutation, admin restart results, bridge pending-result delivery, callback/proxy dispatch, error/close cleanup, and optional frame mapper behavior without constructing App. The initial gateway run found an existing SSE assertion that assumed `id` was the first JSON key; it now parses each SSE chunk and checks its fields, and the complete gateway suite passes on rerun. All 206 E2E checks pass with the verified binary. Safety lint now scans all of `src` for unsafe App conversions and guards the concrete-App-free handler/client boundaries; `git diff --check` passes. Logs are recorded in `tmp/command-provider-validation/`.

### Required command/provider context injection — 2026-10-14

All 19 nil callback defaults in `command.RuntimeContext`, `provider.RuntimeContext`, `provider.RuntimeDispatchContext`, and `ProviderInstanceRuntimeContext` are replaced with required constructor fields. These callbacks are invoked unconditionally; optional handler/static-spec lookup continues to be expressed by the callback result. CommandExecutor, ProviderSpec, and ProviderRuntimeAdapter also require their context fields, preventing an aggregate constructor from silently creating an incomplete context. Existing App builders already inject all production callbacks. Tests with intentional empty behavior explicitly choose `provider.RuntimeContext.noop()`, implemented with named safe functions. The shutdown fixture now registers its provider with the real App-built context instead of constructing an empty context and assigning it later.

Validation: strict V3 build with DB enabled, 8 related command/provider/instance/registry/lifecycle/OpenAI test files, safety lint, and `git diff --check` pass on macOS. New tests exercise callback arguments, mutations of original captured state, error propagation, explicit no-op lifecycle behavior, dispatch URL failures, instance normalization, and existing apply-error handling. Three compiler-negative probes reject incomplete command, provider lifecycle, and provider dispatch contexts. Safety lint rejects both nil defaults and callback fields lacking required injection.

Parallel compilation became unusually slow while other project builds were active; the remaining integration checks completed in isolated/serial runs. The new contract also exposed the shutdown fixture's deferred context assignment, which was corrected before its successful rerun. Two E2E attempts missed the provider handshake probe deadline. The final build and the preceding slice's passing binary have identical SHA-256 hashes; after compilation ended and this slice's leftover test processes were cleaned up, an isolated rerun passed all 206 E2E checks with the original timeout unchanged. Logs and expected compiler failures are recorded in `tmp/runtime-context-injection-validation/`.

### Provider lifecycle context ownership — 2026-10-14

ProviderSpec is now the sole registered lifecycle-context holder. ProviderRuntimeAdapter retains only its required Provider and forwards the caller's context to start, stop, and snapshot. All five bootstrap/registry adapter construction sites drop their extra context field. ProviderSpec provides the lifecycle invocation methods used by admin and generic runtime snapshots and shutdown. Shutdown captures a list of complete specs under App.mu and invokes stop outside the lock; the two parallel runtime/context arrays and their hub wrapper are removed, preserving the prior map iteration behavior and stop-error reporting.

Validation: strict V3 build with DB enabled, 4 related lifecycle/bootstrap/registry/server test files, safety lint, and `git diff --check` pass on macOS. New regressions replace a registered spec's context and verify that start, shutdown, admin snapshots, and generic runtime snapshots use the replacement; they also verify that context mutations made by a Provider pass back through the adapter to the caller. Safety lint prevents RuntimeContext storage from returning to ProviderRuntimeAdapter. All 206 E2E checks pass on the first run with the verified binary. Logs are recorded in `tmp/provider-lifecycle-context-validation/`.

Linux/production, full-suite, and codexbot lifecycle coverage remain pending. The VM preflight still found pre-existing unrelated tracked `.qoder` changes; Linux validation stopped under the Linux testing skill's recorded preflight rule. Next: continue the remaining runtime ownership and safety work before closing the milestones.

### Provider bootstrap registration and context construction — 2026-10-14

Each enabled provider now assembles one complete ProviderSpec with one lifecycle context, then registers and runs that spec. Bootstrap no longer calls the generic registration API that constructed a second context. Full-spec registration synchronizes both provider lookup maps. The complete spec is visible before init; init mutations are published before start, and final context mutations are retained on successful startup and init/start failure. Existing failure events remain unchanged.

Validation: final DB-enabled V3 build, 4 related bootstrap/lifecycle/registry/server test files, safety lint, and git diff --check pass. New regressions cover complete-spec visibility, lifecycle context mutation and failure persistence, error events, and shutdown. Original isolated provider and SSE scenarios pass on both the previous verified binary and the new binary. Logs are recorded in tmp/provider-bootstrap-validation/.

Initial full E2E attempts stopped at provider WebSocket handshake waiting, SSE HTTP 404, and handshake waiting respectively; the second attempt passed the provider scenarios. The follow-up below resolves this validation gap. Linux validation stopped at the existing unrelated tracked .qoder changes under the recorded VM preflight rule. Full-suite and codexbot lifecycle coverage remain pending.

### Provider WebSocket and SSE E2E stability — 2026-10-14

The provider upstream probe now consumes WebSocket bytes in Node's HTTP upgrade head buffer. A deterministic integration regression sends the upgrade request and masked frames in one write: the previous probe times out, while the fixed probe completes. The unchanged 10-second protocol deadline now begins at upgrade instead of counting vhttpd cold startup. Each independent acceptance scenario stops and reaps its test processes; relay startup no longer registers PIDs in a discarded command-substitution subshell. This removes accumulated servers/workers/embedded runtimes from later scenarios. Preserved timing logs show the original probe expiring around late startup, before the handshake dispatch completed.

The SSE demo now supplies a generator factory instead of sharing a consumed Generator across connections. Repeated stream opens previously reproduced a Cannot rewind a generator that was already run exception. PHP regression coverage verifies completion/reopen, interruption/reconnect, and independent readers. Acceptance coverage now checks a second complete SSE connection. Optional diagnostic artifact retention is available without changing normal cleanup.

Validation: complete E2E passes with 4 CLI and 203 config/runtime checks, FAIL 0, plus the Node and PHP regressions. Provider handshake/message/ack and SSE first-open/reopen pass. Safety lint, diff and script syntax checks pass. Evidence is recorded in tmp/e2e-stability-validation/. This slice changes the fixtures, example and test lifecycle; it uses the already verified V3 binary. Linux remains pending under the recorded VM preflight rule.

### StreamRuntimeContext explicit injection — 2026-10-14

StreamRuntimeContext removes all four nil callback defaults. Emit/open/next/close callbacks and a narrow open-failure renderer are required constructor inputs. app_stream_runtime.v owns App assembly and the existing dispatch/direct-stream entry adapters. Stream dispatch no longer receives App; the open-error response uses the injected renderer. The context, dispatch execution, and direct stream execution files contain no App reference. Existing fallback, HTTP 500 error metadata, events, and close behavior are preserved.

Validation: final DB-enabled V3 build, 4 related context/stream-projection/server test files, and safety lint pass. Three new regressions verify callback/correlation forwarding, App-free fallback/error rendering, and best-effort close state/error injection. A negative compiler probe using the actual context source rejects an empty constructor with five required-field errors. Complete E2E passes 207 CLI/config checks plus Node/PHP regressions, including provider handshake and SSE open/reopen. git diff --check passes. Logs are recorded in tmp/stream-context-validation/.

Linux preflight still finds unrelated tracked .qoder changes and stops under the recorded skill rule; Linux/production, full-suite, and codexbot lifecycle coverage remain pending. Continue the remaining ownership and safety work before closing the milestones.

### Remaining runtime callback injection and ownership — 2026-10-14

104 remaining nil function defaults are removed from admin, WebSocket hub/upstream/relay-agent, upstream/I/O, DB server/runtime, OpenAI path, and executor lifecycle/factory/kernel declarations. All require explicit injection. Four new narrow callbacks are also required: upstream validation-error rendering and the three relay-carrier capabilities. The global source safety check now rejects nil function defaults anywhere in src.

Admin reads capture live subsystem references; pipeline and relay snapshots belong to their owners. Upstream registry owns context construction, while App forwarding and error rendering live in app_upstream_runtime.v. Upstream execution no longer receives App. WebSocket state context construction remains on WebSocketRuntime, with App kernel assembly isolated in app_websocket_runtime.v. Command execution requires the supplied kernel instead of constructing an empty port, preserving it through broadcast dispatch and returned commands. Relay carriers retain only a three-callback context. Relay agent protocol contexts and WebSocket contexts have separate explicit ownership; relay/control callbacks capture their owners, and pipeline dispatch uses a narrow host.

Validation: strict DB-enabled V3 build, 14 related ownership/integration/worker/ws/OpenAI test files, safety lint, and git diff --check pass. New regressions verify live admin reads, App-free upstream register/snapshot/validation handling, narrow carrier ownership, and injected kernel broadcast dispatch with hub state updates. The empty-constructor negative probe yields 108 required-field diagnostics. Complete E2E passes 207 CLI/config checks plus Node/PHP regressions. Evidence is recorded in tmp/runtime-contexts-validation/.

Linux preflight remains stopped on unrelated tracked .qoder changes under the recorded skill rule. DB live queries were not enabled. Production/Linux, full-suite and broader ownership work remain pending before declaring V2 complete. The relay pointer and codexbot lifecycle follow-up is recorded below.

### Relay session ownership and required App bindings — 2026-10-14

RelayWebSocketBridgeState no longer stores App or recovers unsafe App aliases. It requires the relay runtime, an event sink, one-method RelayIngressDispatchHost, lifecycle state and a narrow ws.RelaySessionContext. This five-callback session context is built by WebSocketRuntime and is shared by relay hub/agent paths without retaining kernel callbacks. App handshake/state assembly is isolated in app_websocket_relay_runtime.v. Relay core has no App dependency, and its remaining unsafe operations are the three typed callback-state casts required by the WebSocket library.

EventDispatchServices retains an explicit event sink and trace ID instead of App; HTTP/relay assembly injects the ControlPlaneRuntime sink. AdminApp.shared and MultiServerAppBinding.app require references at construction and have no nil defaults. Regression fixtures use the real required state constructor. New regressions verify idempotent lifecycle/hub cleanup and trace/event-counter behavior. An empty-constructor compiler probe rejects omitted session callbacks, relay dependencies, lifecycle state, event sink and App bindings.

Validation: strict DB-enabled V3 build, 7 relay/session/server/ws test files, safety lint and git diff --check pass. Complete E2E passes 207 CLI/config checks plus Node/PHP regressions. Previously pending codexbot lifecycle validation also passes all 27 test functions, covering cancellation, restoration across restart, completion/final-answer and error handling. Evidence is recorded in tmp/relay-ownership-validation/.

Linux remains stopped at unrelated tracked .qoder changes under the recorded VM rule. Whole-project full suite, production/Linux coverage and broader ownership remain pending. The resource-handle follow-up is recorded below.

### Optional resource handles and closing ownership — 2026-10-14

Cache/DB listeners, executor stream/session outcomes, managed worker processes, PostgreSQL pool/session handles, Codex/Feishu provider connections, MCP SSE connections and VJSX lane session/module handles now use explicit options. Required WebSocket lifecycle references and broadcast targets no longer have nil defaults; worker WebSocket ingress creates a real open lifecycle. OpenAI/NDJSON callback state is cast directly from injected user_ptr without a fake nil intermediate.

Closing responsibility is explicit: listener stop and HTTP stream take clear the stored handle before handing it off; lane destroy releases module before session regardless of initialization flags, and unpublished sessions are closed on bootstrap failure. Worker pool stop mutates the actual slots; failed startup/restart reaps the newly created process. PostgreSQL operations reject absent driver-specific handles and repeated close is safe. Feishu outbound cleanup only clears the matching connection, preserving a replacement from reconnect.

MCP and WebSocket flush preserve queued messages while a transport is unbound. Complete E2E initially exposed an invalid client reference in Hub flush after the optional migration; a locked take_pending_batch now explicitly unwraps the client into a required reference and transfers the messages before writing outside the lock. A real-client regression checks pointer identity and safe writes; the corrected full E2E passes 207 CLI/config checks plus Node/PHP regressions.

Validation: strict DB-enabled V3 build, 17 distinct related test files (including corrected targeted retests), complete E2E, safety lint and git diff --check pass. The first batches contained two repaired compilation failures; their successful retests and the first E2E crash are preserved with the final results. The verified binary is copied to the workspace. Evidence and the ownership inventory are in tmp/resource-handles-validation/. External C ABI null checks remain. The executor state/task construction follow-up is recorded below. The global worker PID registry remains a broader lifecycle topic. Live DB, whole-project suite, production and Linux runtime validation remain pending.

### Required executor state and queued task dependencies — 2026-10-14

InProcVjsxExecutor requires its shared VjsxExecutorState. All production constructors and lane/worker views inject the existing state; unreachable missing-state fallbacks are removed. The one engine-registry fixture that used an empty executor now uses the normal zero-lane factory. Snapshot, warmup, pump, affinity and WebSocket tasks require their result slot and completion channels; task hosts are also injected explicitly, and WebSocket start notification is required. Warmup copies the EmbeddedHost interface directly instead of using an unsafe address of that interface variable.

Mailbox selection now returns an optional WebSocketMailboxSelection containing the actual queued task. Selection, FIFO dequeue and the running mark occur under one state lock; no empty task with a nil slot represents absence. Failed lane/worker lookup restores the original tasks, slots and pending state, and failed dispatch releases the lane lease.

Validation: DB-enabled V3 build, 8 related test files after a targeted retest, 5 new ownership/mailbox test functions, missing-dependency compiler rejection, safety lint and git diff --check pass. Complete E2E passes all 207 CLI/config checks plus Node/PHP regressions. The new fixture initially triggered a V3 generic Value equality C-generation error; shared-state/slot identity assertions now compare addresses, and optional selections use explicit bindings. The final retest has zero V errors, warnings or notices. Evidence is in tmp/task-ownership-validation/.

The built executor sources match the final workspace sources. Linux remains stopped at pre-existing tracked .qoder changes under the VM skill rule. Concurrent shutdown ownership, whole-project suite and production/Linux coverage remain broader follow-ups; this does not mark all V2 work complete. The managed worker PID follow-up is recorded below.

### Managed worker process registry ownership — 2026-10-14

The process_runtime module owns one process-wide ManagedProcessRegistry of actual os.Process handles, with serialized launch, observation, retirement and shutdown. Initial start, ensure/retry and restart all register immediately through the same entry point. Normal stop, failed readiness and natural exit remove the owner record before reap; a stale handle cannot unregister a replacement merely because its numeric PID matches. WNOWAIT observes exit without freeing the PID before group cleanup. Snapshots prune exited children, and process shutdown drains the registry and rejects later launches. Transport/worker paths no longer maintain a raw global PID array or independently spawn/probe/reap managed children. Admin snapshots suppress retired PID/RSS fields.

SIGINT/SIGTERM callbacks only perform an errno-preserving nonblocking pipe write; an ordinary thread logs and drains the registry. The pipe is close-on-exec. Active-runtime registration/config snapshots are synchronized, and App summary callbacks run after releasing that registry lock. Normal/error return from the server entry also drains the process owner.

Validation repaired two V3 boundary issues: a fixed-array C out-parameter did not produce usable pipe FDs, so pipe creation returns an explicitly declared C typedef structure by value; a mutable optional proc check lost the replacement handle during restart, so retire_process returns whether ownership was transferred instead. The blocked pipe test was sampled and stopped, and the known orphan from the failed restart fixture was identified by its unique path/PGID and reaped. Corrected regressions pass and no test processes remain.

DB-enabled V3 build, 10 related test files after targeted retests, 8 new process/PID test functions, safety lint and git diff --check pass. Two real-server Node regressions restart the worker through admin, verify old PID removal, then send SIGTERM/SIGINT and confirm the replacement exits. They run in the full E2E entry point, which passes 207 CLI/config checks plus these regressions and the existing Node/PHP stream/upgrade regressions. Final built process/worker/transport/server sources match the workspace. The verified binary is copied to the workspace. Evidence is in tmp/pid-registry-validation/.

Linux preflight initially timed out waiting for OrbStack services; a later read-only retry succeeded and still found the unrelated tracked .qoder changes, so runtime testing stopped under the VM skill rule. Full-suite, production/Linux, live DB and broader concurrent executor shutdown validation remain pending before V2 completion.

### Executor concurrent shutdown ownership — 2026-10-14

Executor close is terminal and has one synchronized admission boundary. Lane acquisition, all five bounded queue submissions, mailbox scheduling and bootstrap reject new work after stopping begins. Queue submissions never block while holding the lifecycle mutex. Pending mailbox entries complete with an explicit closed error; a scheduler that selected a task before stopping cancels its task instead of restoring it. The owner notifies every lane worker before joining any of them; workers drain accepted tasks through the same loop and block normally when idle. Signature refresh is joined, and direct lane leases, mailbox schedulers and host builders finish before module/session destruction. Concurrent close callers await the same completed teardown.

Wakeup scheduling is disabled and sleeping deliveries notice cancellation promptly. Host remembrance and late actor/affinity binding writes cannot restore closed state. Actor probes now transfer one lane lease to the worker instead of releasing it twice; failed direct WebSocket and affinity submissions release the caller-owned lease.

DB-enabled V3 build, 8 related test files (128 functions, including 6 new concurrent shutdown regressions), safety lint and git diff --check pass after targeted retests. One relay cold-start request exceeded its existing 10-second deadline while production build ran concurrently; the complete 70-function executor file passed independently without changing code or timeouts. Both logs are retained. Final full E2E passes 207 CLI/config checks plus upgrade-frame, two worker restart/signal and PHP SSE regressions. All 78 executor production sources match build staging, and the verified binary is copied to the workspace. Evidence is in tmp/executor-shutdown-validation/.

Linux remains stopped at unrelated tracked .qoder changes under the VM skill rule. Close cooperatively waits for admitted execution; whole-project suite, production load/forced-abort behavior, live DB and Linux runtime coverage remain pending before V2 completion.

### Executor task timeout and cancellation ownership — 2026-10-14

Every queued slot now shares an ExecutorTaskControl with pending/running/completed/cancelled state, one winning cancellation reason and one terminal notification. All five queue classes use one timeout path. Pending cancellation removes mailbox/registry ownership and retracts a lane lease once; cancelled channel copies are skipped without releasing a later owner's lease. Running tasks retain their lease until their worker exits. The vjsx atomic interrupt cancels running JS, and the worker destroys an interrupted session before releasing its lane. Unpublished sessions attach cancellation before evaluation and detach it before close.

Snapshot, warmup and pump tasks also acquire exclusive lane ownership. Busy maintenance tasks briefly requeue and resume after the direct owner exits; timeout and shutdown stop retries. Mailbox scheduling no longer blocks while acquiring a lane. Affinity release cancels pending registered tasks even if already selected from the mailbox. Cancelled/failed WebSocket open and close clear connection/actor bindings. Normal completion releases ownership before notification, while repeated cleanup preserves the winning outcome.

DB-enabled V3 build, 8 related test files (125 functions, including 11 new cancellation regressions), safety lint and git diff --check pass after targeted retests. Actual infinite JS interruption, poisoned-session rebuild, busy-lane resumption, selected mailbox release, open/close binding cleanup and single notification are covered. The 70-function executor file, startup and 30 logic/plan replacement functions pass; the final binding change also passes a targeted 23-function WebSocket retest. Final full E2E passes 207 CLI/config checks plus upgrade-frame, two worker restart/signal and PHP SSE regressions. Timeout constants were not increased. All 79 executor production sources match build staging; the verified binary is copied to the workspace. Evidence is in tmp/executor-cancel-validation/.

Linux again stops at the existing unrelated tracked .qoder changes under the VM skill rule. Blocking native callbacks and direct synchronous calls remain cooperative; their session/lane is not destroyed while executing. Whole-project suite, production load, live DB and Linux runtime validation remain broader follow-ups before V2 completion.

---

### Card bridge session and registry ownership — 2026-10-15

The resource review covered card bridge server/client sessions, upstream reconnect/heartbeat paths, cache/DB listeners and shutdown hooks. This slice fixes confirmed card bridge registry races: unregister now requires the actual connection identity, so an old close callback or failed send cannot remove a replacement registered under the same client ID. Required registration references no longer carry a redundant nil guard.

The server session owns an explicit optional accepted client. Acceptance captures ownership without publishing; the attached callback publishes only after the 101 response has been written and WebSocket callbacks installed. Deferred teardown takes the optional handle once, removes only its own registration, closes its connection and closes the transferred TCP handle even when handshaking fails before callbacks are installed. The registry borrows connection handles and does not own session teardown.

DB-enabled V3 build, 3 related test files (16 functions, including 6 new bridge lifecycle regressions), safety lint and git diff --check pass. Tests cover stale unregister/close, unpublished handshake failure, repeated teardown, failed sends and actual TCP EOF after replacement, plus native provider handshake/normalization. An existing test's nil assertion on an optional handle failed in the initial run; both assertions now explicitly compare with none, and the complete affected file passes. Final full E2E passes 207 CLI/config checks plus upgrade-frame, worker restart/signal and PHP SSE regressions. All 401 production V sources match build staging; the verified binary is copied to the workspace. Evidence is in tmp/bridge-owner-validation/.

Linux read-only preflight again finds unrelated tracked .qoder changes; runtime testing stops under the VM skill rule. Listener startup/stop overlap and upstream/bridge heartbeat stop/join ownership remain the next review slices. This change does not claim completion of all subsystem ownership, the whole-project suite, production load or live DB/Linux runtime validation.

### Cache and DB listener generation ownership — 2026-10-15

Cache and DB listeners now share listener_runtime.Owner. It holds one optional listener and serializes startup, publication, stop and deferred cleanup by generation. Production startup reserves synchronously before spawning, so a delayed serving loop cannot undo a subsequent stop. Duplicate starts are rejected before touching the socket path; DB provider start reports db_listener_busy. A candidate that loses publication remains local to its serving loop and is closed there. Published handles are closed/unlinked exactly once by their generation's finalizer; stale finalizers and state/error updates cannot affect a replacement.

Stop returns an optional generation instead of transferring a listener to another thread. Provider stop and cache shutdown wait for that generation outside App.mu. Waiting ignores newer generations. DB keeps the reservation through session/pool cleanup, preventing a new listener from starting while old shared-resource cleanup runs. The listening socket lifetime is separate from the existing accepted-request lifecycle.

The shared listen helper explicitly sets the Unix listener nonblocking and uses a 100 ms accept timeout. Real socket regression tests exposed that the current V library otherwise blocks in its initial accept call despite an accept timeout. Idle polling does not record runtime errors, and accepted sockets observed after stop are closed instead of dispatched.

Final DB-enabled V3 build, 6 related test files (20 distinct functions, including 12 new lifecycle regressions), safety lint and git diff --check pass. Coverage includes simultaneous start reservation, stop before bind/publication, duplicate starts, failed bind, stale teardown, cleanup barriers, three real cache ping/restart cycles, ten immediate start/stop cycles and eight concurrent provider stops followed by restart. The non-DB branch also passes all 5 resource-handle tests after correcting its remaining old callback signature. Earlier fixture/compiler failures and the blocking-accept regression are retained with their final passing retests. Full E2E passes 207 CLI/config checks plus upgrade-frame, worker restart/signal and PHP SSE regressions. All 402 production V sources match final build staging; the verified binary is copied to the workspace. Evidence is in tmp/listener-owner-validation/.

Linux read-only preflight again stops at unrelated tracked .qoder changes under the VM skill rule. Upstream/bridge reconnect and heartbeat stop/join ownership remain the next review slice. Whole-project suite, production load, live DB and Linux runtime validation remain broader follow-ups before V2 completion.

## Milestone 0 — Preparation (½ day)

**Goal:** baseline the current state so we can measure each milestone.

- [ ] Record current `vhttpd` binary size and build time on each platform from CI artifact logs.
- [ ] Capture `make test-fast` baseline wall-clock and pass/fail counts.
- [ ] Run `make prod` locally; record binary size, RSS at idle, and a single-request p50/p99.
- [ ] Tag the current commit as `pre-refactor-baseline`.

**Files touched:** none (read-only).

**Verification:** baseline numbers checked into a `docs/perf-baseline.md`.

---

## Milestone 1 — Replace `unsafe { voidptr(&app) }` bridge (2–3 days)

**Goal:** delete `executor_bridge.v` and remove the V-codegen-bug workaround.

**Scope:** the entire `executor.AppFacade` interface in `src/executor/`.

**Plan:**

1. Read every `AppFacade` method in `src/executor/app_facade*.v`. Catalog the fields of `App` it transitively reads.
2. Replace each method's signature with concrete-value arguments (e.g. `runtime_config_json string`, `plan_json string`, `read_timeout_ms_for_kind fn(string) int`).
3. Move the call sites that build the `AppFacade` to pass those values directly. Most call sites live in `src/app_runtime_builder.v` and `src/executor/`.
4. Delete `src/executor_bridge.v` and its 194 lines of `unsafe { &App(w.app_ptr) }` blocks.
5. Add a `grep -r "voidptr(&app)\|unsafe { &App" src/` check in `scripts/lint_safety.sh` so the pattern cannot reappear unnoticed.

**Files touched (estimate):** `src/executor/app_facade*.v`, `src/app_runtime_builder.v`, `src/executor_bridge.v` (delete), `scripts/lint_safety.sh` (new).

**Verification:**

- `make prod` succeeds on linux-amd64 + macos-arm64.
- `make test-fast` passes with no new failures.
- `grep -r "unsafe { &App\|voidptr(&app)" src/` returns nothing.
- `worker_backend_dispatch_*` integration tests pass (they go through the AppFacade).

**Rollback:** revert the merge commit. The bridge is isolated to one file so the revert should be clean.

**Risk:** HIGH (touches the interface used by hot paths). Mitigation: keep the change behind a single feature branch; merge only after `test-all` passes locally and CI is green for both platforms.

---

## Milestone 2 — `App` decomposition: `ExecutorHost` + `worker_backend` (1 week)

**Goal:** break the circular dependency that blocks Phase 2.1 of `TODO_REFACTOR.md`.

**Scope:** `src/executor/`, `src/worker/`, `src/worker_backend_*.v`.

**Plan:**

1. Define `ExecutorHost` interface in `src/executor/host.v`:
   - methods that today read `app.engines.*`, `app.protocols.*`, etc.
   - this is the seam the `unsafe` bridge currently fakes.
2. Change `LogicExecutor` interface methods from `fn (mut app App)` to `fn (mut host ExecutorHost)`.
3. For `worker_backend_*.v`: introduce `WorkerState` struct holding `pool / queue / lifecycle / drain` fields. Move methods from `App` to `WorkerState` where they don't need other subsystems.
4. Add `WorkerState` as a `&mut` field on `App` (one transitional step before Milestone 3 removes it from `App` entirely).
5. Run `make test-fast` after each file move; commit green.

**Files touched (estimate):** ~15 files. `src/executor/host.v` (new), `src/worker/connection.v`, `src/worker_backend_*.v` (12 files), `src/command_*.v` (interface call sites).

**Verification:**

- `make test-fast` green.
- `grep -c "fn (mut app App)" src/worker_backend_*.v` drops by at least 50%.
- `wc -l src/main.v` should not increase.

**Rollback:** revert merge. The interface extraction is additive — old `App` methods can stay until the new path is fully wired.

**Risk:** MED. Mostly mechanical; the hard part is keeping the lock order in `src/server.v:4-24` intact.

---

## Milestone 3 — `App` decomposition: `command` and `feishu` (1 week)

**Goal:** continue Phase 2.1 modularization; bring `command_handlers.v` off `App`.

**Scope:** `src/command/`, `src/feishu/`, `src/feishu_card_bridge_*.v`.

**Plan:**

1. Define `CommandContext` and `FeishuState` structs that bundle the state `command_handlers.v` and `feishu_card_bridge_*.v` read off `App`.
2. Replace `app &App = unsafe { nil }` global in `src/command_handlers.v` with explicit injection.
3. Replace the `unsafe { nil }` placeholders in `src/feishu_card_bridge_*.v` (5+ sites) with struct fields initialized through a builder.
4. After both done: drop the `unsafe { nil }` pattern from `src/engine_runtime.v:9` (the `emit_fn` global) — give `EngineRuntime` an explicit callback field.

**Files touched (estimate):** ~12 files.

**Verification:**

- `grep -rn "unsafe { nil }" src/` shrinks by at least 8 sites.
- `make test-codexbot-fast` green (the integration tests cover feishu + command paths).
- `make test-fast` green.

**Rollback:** revert merge; the `unsafe { nil }` global pattern remains functional.

**Risk:** MED. The lock order doc in `server.v` is the safety net — keep it updated as fields move.

---

## Milestone 4 — Consolidate logging (½ day)

**Goal:** merge `runtime_trace` (`src/main.v:33`) and `app.emit` (`src/app_composition_runtime.v:74`) into a single log path. Fixes finding 2.4 and 2.8 in one move.

**Scope:** `src/main.v`, `src/app_composition_runtime.v`, `src/logging/`.

**Plan:**

1. Add a `runtime_trace_path` config field (optional). When unset, trace events flow through `app.emit` only.
2. Delete the `runtime_trace` function in `src/main.v` and its 4 hardcoded labels. Replace each call site with `app.emit('runtime.trace', fields)`.
3. Extend `app.emit` to handle trace events (`server.started`, `admin.started`, etc.) by writing them to `control.event_log` instead of `/tmp/vhttpd_runtime_trace.log`.
4. Document the new log path in `docs/OVERVIEW.md` (fixes 2.10).
5. Add a `VHTTPD_LOG_FORMAT=json` flag (also addresses Phase 4 of `TODO_REFACTOR.md`).

**Files touched:** `src/main.v`, `src/app_composition_runtime.v`, `src/config/runtime_config.v`, `docs/OVERVIEW.md`.

**Verification:**

- `grep -n "/tmp/vhttpd_runtime_trace" src/` returns nothing.
- Boot the binary, hit a few endpoints, confirm `control.event_log` contains the same event names that `runtime_trace` used to log.
- `make test-fast` green.

**Rollback:** revert merge; the original two-path system still works.

**Risk:** LOW. The only behavioral change is where trace events land; both paths remain functional during the transition.

---

## Milestone 5 — CI: e2e + inproc on every PR (½ day)

**Goal:** catch e2e regressions on PR instead of waiting for a manual run.

**Scope:** `.github/workflows/vhttpd-binaries.yml`, `tests/e2e/run.sh`, `Makefile`.

**Plan:**

1. Add a `test-inproc-fast` job to the CI matrix that runs `make test-codexbot-fast V_CC=cc` (skip the 1103-line lifecycle test for PR, run it nightly).
2. Add a `test-e2e` job that runs `make test-e2e` after `make prod`. Use the built binary, not `vhttpd` already on PATH.
3. Add a nightly `nightly-full` workflow on `schedule: cron: '0 3 * * *'` that runs `make test-all` and `make test-codexbot-lifecycle`.
4. Update `sync-vphp-package.yml` trigger to include `php/app/**` (or document the deliberate exclusion).

**Files touched:** `.github/workflows/vhttpd-binaries.yml` (add jobs), `.github/workflows/nightly-full.yml` (new), `.github/workflows/sync-vphp-package.yml` (paths).

**Verification:**

- Open a throwaway PR; observe both new jobs run.
- Nightly job fires at 03:00 UTC and produces artifacts.
- `make test-all` exits 0 in the nightly job.

**Rollback:** disable the workflow files via `gh workflow disable`.

**Risk:** LOW. CI-only changes; no production surface affected.

---

## Milestone 6 — Non-blocking backoff (1 day)

**Goal:** replace `time.sleep` in request/connection paths with non-blocking backoff. Addresses finding 2.6.

**Scope:** 10 files listed in the review.

**Plan:**

1. Convert each `time.sleep(N seconds)` in `feishu_card_bridge_client_runtime.v:112` and `:161` to a 5-step backoff with a check for shutdown in between.
2. Convert `feishu_provider_connection_runtime.v:31` to `select { <-time.after(...) }` if V's stdlib supports it, otherwise a poll loop that respects a `done chan`.
3. For the small (200ms–500ms) sleeps in `codex_provider_websocket_runtime.v`, `mcp_session_stream_runtime.v`, etc.: keep `time.sleep` but add a comment that they're bounded polling and verify the total worst-case latency is acceptable.

**Files touched:** ~10 files.

**Verification:**

- `make test-codexbot-fast` green.
- Manual: open a feishu card bridge, kill the upstream, observe the reconnect loop without freezing the websocket send path for > 1s at a time.

**Rollback:** revert merge; the time.sleep calls revert.

**Risk:** LOW. Behavior change is bounded.

---

## Milestone 7 — v1 config deprecation (½ day)

**Goal:** surface the v1 → v2 path so users have a timeline.

**Scope:** `src/config/v1_plan_compat.v`, `vhttpd.toml`, README.

**Plan:**

1. Mark every v1 field that gets translated to v2 in `v1_plan_compat.v` with `@[deprecated: 'use v2 plan; v1 fields will be removed 2027-02']`.
2. Add a "Deprecation Timeline" section to `README.md` listing which keys are deprecated and the removal date.
3. Move `src/config/v1_plan_compat.v` and `src/config/v1_plan_compat_test.v` into `src/config/compat/v1/` so the v2 path is the primary layout.
4. Update `vhttpd.toml` to use v2 syntax; keep the file at `examples/v1-vhttpd.toml` for reference.

**Files touched:** `src/config/v1_plan_compat.v`, `vhttpd.toml`, `README.md`, directory moves.

**Verification:**

- `make test-fast` green (compat tests still pass).
- README deprecation section renders correctly in `mkdocs serve`.

**Rollback:** revert merge.

**Risk:** LOW. Pure documentation + file moves; runtime unchanged.

---

## Sequencing

| Order | Milestone | Depends on | Owner signal |
|---|---|---|---|
| 0 | Preparation | — | baseline docs in `docs/perf-baseline.md` |
| 1 | Drop unsafe bridge | M0 | no `unsafe { &App(` in src |
| 2 | ExecutorHost + worker_backend | M1 | `grep -c "fn (mut app App)" src/worker_backend_*.v` ↓ 50% |
| 3 | command + feishu decomposition | M1, M2 | `grep -rn "unsafe { nil }" src/` ↓ 8 sites |
| 4 | Logging consolidation | — | no `/tmp/vhttpd_runtime_trace.log` |
| 5 | CI e2e + inproc | — | new jobs in CI matrix |
| 6 | Non-blocking backoff | — | no `time.sleep` ≥ 1s in hot paths |
| 7 | v1 deprecation | — | `@[deprecated]` markers + README section |

**Independent tracks:** M4, M5, M6, M7 can run in parallel. M1 → M2 → M3 must be sequential because they each remove a layer of `App` coupling.

**Target end state:**

- `App` struct holds only `DataPlaneRuntime` + `ControlPlaneRuntime` + `veb` boilerplate; sub-runtimes are separate structs.
- No `unsafe { &App(` in production code.
- No `unsafe { nil }` in `src/command_handlers.v` or `src/admin_server.v`.
- No hardcoded `/tmp` paths.
- One log path through `app.emit`.
- v1 deprecation public; v2 is the default config example.

---

## Cross-References

- `TODO_REFACTOR.md` Phase 2.2 — `App` decomposition (M2, M3)
- `TODO_REFACTOR.md` Phase 3 — memory safety (M1, M3)
- `TODO_REFACTOR.md` Phase 4 — JSON structured log (M4)
- `TODO_REFACTOR.md` Phase 5 — Makefile modularization (out of scope here)
- `CODE_REVIEW_2026_08_06.md` — the diagnostic that produced this plan
