# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] — 2026-06-26

### Added

- Multi-backend support via the unified `AtpClient.Backend` contract.
  Three cross-backend tools that work against any registered backend:
  - `list_backends` — enumerate registered backends with their labels.
  - `verify_backend` — probe a backend's configuration and reachability.
  - `query_backend` — submit a TPTP problem to any backend (`sotptp`,
    `isabelle`, `local_exec`, `starexec`) and get a normalized SZS
    result.
- `prove_isabelle` tool for hand-written Isabelle/HOL theories, wrapping
  `AtpClient.Isabelle.query/3`.
- `lint_problem` tool exposing `AtpClient.Lint.analyze/2`. Defaults to
  both the in-process structural checker and TPTP4X; selectable via
  `backends: ["local"]` / `["tptp4x"]`.
- `AtpMcp.Runtime` — GenServer driving the MCP protocol loop. Owns
  stdout, runs each `tools/call` in its own monitored Task, and serves
  as the single point where new asynchronous behaviour is added.
- Cancellation support via `notifications/cancelled`. The runtime kills
  the in-flight Task; each backend tears down its upstream work in
  response:
  - LocalExec — `Port` closure SIGKILLs the prover binary.
  - StarExec — cancel-guard issues `DELETE` against the remote job.
  - Isabelle — session is dropped, aborting any in-flight `use_theories`.
  - SystemOnTPTP — local connection closes; remote prover continues to
    its `:time_limit_sec` (SOTPTP has no remote-cancel endpoint).
- Progress notifications when `_meta.progressToken` is set. Heartbeat
  every `:heartbeat_ms` (default 5000ms) while a call is in flight;
  configurable via `config :atp_mcp, heartbeat_ms: …`.

### Changed

- MCP protocol revision bumped from `2024-11-05` to `2025-11-25`.
- `:atp_client` dependency bumped from Hex `~> 0.2` to `~> 0.3` for the
  unified backend contract and cancellation API.
- Minimum Elixir version raised to `~> 1.20`.
- Test mock surface split per backend: `AtpMcp.Backends.SystemOnTptp`,
  `Isabelle`, `LocalExec`, `StarExec`, `Lint` replace the single
  `AtpMcp.AtpBehaviour`.
- Internal restructure: `dispatch/1` replaced by pure `classify/1` +
  `execute_tool/2`. The synchronous `handle_rpc/1` path is retained for
  tests; the asynchronous `AtpMcp.Runtime.deliver/1` path drives the
  escript at runtime.

### Documentation

- Forward note in module and README about the experimental MCP Tasks
  primitive and how it maps onto long-running ATP invocations.
- Per-backend cancellation semantics documented honestly (including
  SystemOnTPTP's lack of remote cancellation).

## [0.1.1] — 2026-05-19

### Added

- Initial MCP stdio server wrapping `AtpClient.SystemOnTptp` only.
- Three tools: `list_provers`, `run_prover`, `compare_provers`.
- JSON-RPC 2.0 framing with `initialize`, `ping`, `tools/list`,
  `tools/call`, and silent acknowledgement of `notifications/initialized`.
- Declared MCP protocol revision `2024-11-05`.

[0.2.0]: https://github.com/jcschuster/AtpMcp/releases/tag/v0.2.0
[0.1.1]: https://github.com/jcschuster/AtpMcp/releases/tag/v0.1.1
