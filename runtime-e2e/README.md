# Runtime End-to-End Tests — Codex plugin

Tests in this directory MUST invoke the plugin through Codex's runtime — installed via the manifest path, loaded by Codex, and triggered through Codex's tool/skill dispatch. Importing the plugin's TypeScript modules directly is not a runtime test — that's a unit test, which lives under `tests/`.

If Codex can't expose your feature yet, the feature isn't ready to ship.

## Why this directory exists

A May 3, 2026 audit found multiple AxonFlow capabilities (audit search, decision explain, override CRUD) where the platform endpoint and SDK method existed for months but no plugin tool/skill ever wired them up. Users running Codex with the AxonFlow plugin could not reach the capability. The fix: every user-facing AxonFlow feature exposed via this plugin must have a test in this directory that invokes through Codex's runtime.

The single rule:

> **If a user cannot reach the feature from their runtime, we did not ship a feature, we shipped a library.**

See `axonflow-business-docs/engineering/E2E_EXAMPLES_TESTING_WORKFLOW.md` Policy section for the full methodology.

## What "runtime" means here

The runtime is the Codex CLI plugin host. A test must:

- Install the plugin via Codex's manifest install path — not by symlinking from a relative source path.
- Load it inside a real Codex session.
- Trigger the capability through Codex's surface — registered tool, skill invocation, or hook — rather than importing the plugin's TypeScript classes.

If a test imports from `src/` and calls the AxonFlow client class, it is a unit test or an integration test against the AxonFlow stack. That belongs under `tests/`, not here.

## Layout

```
runtime-e2e/
  README.md                    # this file
  <feature-name>/              # one folder per feature
    test.sh                    # bash runner; invokes through codex
    README.md                  # 5 lines: prereqs, what it asserts, how to run
```

## Running

Each test folder has its own README with prereqs and run instructions. Most tests assume:

- An AxonFlow community-saas-style stack is reachable (default endpoint or via env var).
- A working Codex CLI installed and on `$PATH`.
- The plugin is built locally so the manifest install path can resolve it.

## Adding a test

1. Confirm you can invoke the feature through Codex — install the plugin, then trigger via tool/skill/hook. If you can't, the answer is to fix the plugin's tool/skill registration, not to write a TypeScript-import test.
2. Create the folder, write `test.sh` and `README.md`.
3. Update `axonflow-business-docs/engineering/FEATURE_RUNTIME_COVERAGE.md` to mark the new green cell under the Codex column.
4. Reference the test in the PR that wires the feature.
