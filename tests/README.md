# vhttpd Test Suite

## Layout

```
tests/
├── e2e/                    # End-to-end / integration tests (shell)
│   ├── run.sh              # Entry point
│   └── smoke_test.sh       # CLI smoke tests (no external deps)
└── README.md
```

## Unit Tests

Unit tests live alongside source code in `src/` because V's module system requires `module main` tests to be in the same directory as the code under test.  They are **auto-discovered** by `make test-fast` via `find src -name '*_test.v'`.

When you add a new `*_test.v` under `src/`, it will be picked up automatically as long as it matches the Makefile filter rules:

- `make test-fast` — all `src/*_test.v` except `inproc_*` and `db_*`
- `make test-inproc` — all `src/inproc_*_test.v` except `*codexbot*`
- `make test-codexbot` — all `src/*codexbot*_test.v`

## E2E Tests

E2E tests are standalone shell scripts that exercise the compiled `vhttpd` binary. They do not require PHP, vslim, or QuickJS.

Run them after `make build`:

```bash
bash tests/e2e/run.sh
```

Or directly:

```bash
bash tests/e2e/smoke_test.sh
```
