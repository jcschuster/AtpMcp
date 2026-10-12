# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.0] - 2026-10-12

AtpMcp now runs on AtpClient 0.7 and [`tptp`](https://hex.pm/packages/tptp),
and needs no launcher script: the escript reads a config file at startup,
starts Isabelle itself, and checks its own setup with `atp_mcp doctor`. A
Docker image bundles it with E and, optionally, Isabelle/HOL.

### Upgrading

- A setup that injected configuration through `ERL_FLAGS=-config …` (as
  the PAAR'26 launcher did) keeps working; move it to `atp_mcp.exs` to
  drop the launcher. A launcher that starts its own Isabelle server and
  configures its password is unaffected; without one, AtpMcp now starts
  its own.
- `raw: true` returns what the system printed. For `prove_isabelle` that
  is Isabelle's message text, no longer the inspected `use_theories` map.
- `lint_problem` output gains diagnostic codes and hints, and the
  `Symbols:` section lists only declared symbols, as
  `name : type (declared at line:col)`.
- Statuses whose SZS name is not a plain camelization now print correctly
  (`OSError`, not `OsError`); a client matching the old spelling must
  update.

### Added

- **Docker image.** A `Dockerfile` with two targets: the default image
  (SystemOnTPTP plus a local E) and `isabelle` (plus Isabelle/HOL).
  `.github/workflows/docker.yml` publishes both to
  `ghcr.io/<owner>/atp_mcp` on `v*` tags.
- **Runtime config file.** The escript reads `--config PATH`,
  `$ATP_MCP_CONFIG`, or `./atp_mcp.exs` at startup (`AtpMcp.Settings`).
  This replaces the `sys.config`/`ERL_FLAGS` injection a launcher script
  needed before. With no file, `local_exec` defaults to E when `eprover`
  is on `PATH`.
- **Isabelle auto-start.** With no Isabelle password configured and
  `isabelle` on `PATH`, `AtpMcp.IsabelleSession` starts (or reuses) a
  resident server named `atp_mcp`. Opt out with
  `config :atp_mcp, isabelle_autostart: false`.
- **`atp_mcp doctor [BACKEND…]`** prints each backend's resolved
  settings (passwords redacted) and its `verify/1` result, and exits with
  status 1 on any failure. Also `--help` and `--version`.
- `run_prover` and `compare_provers` accept bare system names
  (`"Vampire"`) for the latest version, via AtpClient 0.7.1.

### Changed

- `compare_provers` labels each row with the system as requested and, for
  a bare name, the version that ran (`Vampire (Vampire---5.0.1):
  CounterSatisfiable`). Failures read as text, not Elixir terms: an
  unknown system is `Nope: not a system on SystemOnTPTP (see
  list_provers)`, where 0.5 printed `no result returned` and dropped the
  systems after it. `run_prover` reports an unknown system the same way.
- `:atp_client` bumped from `~> 0.6` to `~> 0.7.1`, which brings in
  [`tptp`](https://hex.pm/packages/tptp) `~> 0.1.3`. Every backend now
  returns an `AtpClient.Result`; verdicts are rendered with
  `Tptp.Szs.Ontology.name/1`, so names that are not a plain camelization
  now come out right (`OSError`, `CPUTimeout`, `WCTimeout`, not `OsError`,
  `CpuTimeout`, `WcTimeout`).
- `raw: true` now returns the system's verbatim output (`Result.output`)
  on every backend and is no longer forwarded to AtpClient, which rejects
  it since 0.7. For `prove_isabelle` this is Isabelle's message text in
  place of the inspected `use_theories` payload.
- `lint_problem` runs on `tptp`: the local pass is `Tptp.analyze/2`, the
  remote pass `AtpClient.Analyzer.Tptp4x`. Each finding now carries its
  diagnostic code (`TPTP0401`, `TPTP4X`, …) and, where the linter gives
  one, a hint. The remote pass reports `tptp4x skipped` instead of
  passing silently when the local pass found errors. `Symbols:` lists
  declared symbols with their canonical type.
- `describe_szs` is generated from `Tptp.Szs.Ontology` at compile time,
  so it covers the full Success and NoSuccess ontologies with each
  status's mnemonic and the definition from the SZS page, and cannot
  drift from the statuses the tools report.

### Removed

- `AtpMcp.Backends.Lint`; tests inject the remote lint pass as a
  `Tptp.Analyzer` via `config :atp_mcp, :tptp4x`.

### Fixed

- Logger output went to stdout, the MCP channel, where any warning from
  Req, Finch, or Isabelle became a malformed JSON-RPC frame. It now goes
  to stderr.

## [0.5.2] - 2026-09-29

### Added

- Citation metadata: `CITATION.cff` and `.zenodo.json` for archiving releases on Zenodo; no functional changes.

## [0.4.0] — 2026-07-01

### Added

- `describe_szs` tool that returns the SZS Ontology
  (https://tptp.org/UserDocs/SZSOntology/) as inline text — Success vs
  NoSuccess split, per-status glosses (Theorem vs Unsatisfiable vs
  CounterSatisfiable, GaveUp vs Timeout vs ResourceOut, …), and a note
  on the CamelCase pass-through for future SZS additions. Agents driving
  the MCP server can now look up what a verdict means without leaving
  the session.

### Changed

- `:atp_client` dependency bumped from Hex `~> 0.4` to `~> 0.5`. Verdict
  atoms now come from `AtpClient.ResultNormalization` and follow the
  SZS Ontology verbatim (snake_case of the SZS name):
  - Old ad-hoc tags `:thm`, `:sat`, `:csat`, `:out_of_resources`, and
    `:interrupted` are gone; use `:theorem`, `:satisfiable`,
    `:counter_satisfiable`, `:resource_out`, and `:forced` instead.
  - Twelve additional Success statuses are now recognised — including
    `:unsatisfiable`, `:contradictory_axioms`, `:equivalent`,
    `:tautology`, `:tautologous_conclusion`, `:weaker_conclusion`,
    `:no_consequence`, and the `counter_*` family.
  - Additional NoSuccess statuses `:unknown`, `:incomplete`,
    `:memory_out`, `:user`, `:inappropriate`, `:error`, and
    `:input_error` are surfaced.
- Rendered verdict labels now match SZS names exactly. Notable label
  changes: `Countersatisfiable` → `CounterSatisfiable`,
  `Out of resources` → `ResourceOut`, `Gave up` → `GaveUp`,
  `Interrupted` → `Forced`. Unrecognised-but-well-formed SZS names pass
  through as CamelCase (e.g. `:equivalent_theorem` → `EquivalentTheorem`)
  so future SZS additions render without a code change.
- Tool descriptions for `query_backend`, `run_prover`, and
  `compare_provers` name the SZS verdict vocabulary and cross-reference
  `describe_szs`.

## [0.3.0] — 2026-06-29

### Changed

- `:atp_client` dependency bumped from Hex `~> 0.3` to `~> 0.4`. AtpMcp's
  public surface is unchanged; the upgrade pulls in upstream correctness
  fixes that flow through transparently:
  - Isabelle multi-lemma jobs no longer mis-bucket Sledgehammer / Nitpick
    output across message boundaries (e.g. `Nitpick found a model` next
    to `Nitpick found no counterexample` no longer collapses to `:csat`;
    `by <tactic>` failing on a `False` goal is no longer reported as
    `:thm`). Per-lemma verdicts are now classified message-by-message
    against body-line ranges.
  - `pos.file` filtering drops phantom lemma rows from the bundled
    `TPTP.thy` and other transitively imported theories.
  - Sledgehammer / Nitpick verdicts carry the lemma name from the source
    body instead of surfacing as `name: nil`.

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
- Test mock surface split per backend: `AtpMcp.Backends.{SystemOnTptp,
  Isabelle, LocalExec, StarExec, Lint}` replace the single
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

[Unreleased]: https://github.com/jcschuster/AtpMcp/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/jcschuster/AtpMcp/releases/tag/v0.6.0
[0.5.2]: https://github.com/jcschuster/AtpMcp/releases/tag/v0.5.2
[0.4.0]: https://github.com/jcschuster/AtpMcp/releases/tag/v0.4.0
[0.3.0]: https://github.com/jcschuster/AtpMcp/releases/tag/v0.3.0
[0.2.0]: https://github.com/jcschuster/AtpMcp/releases/tag/v0.2.0
[0.1.1]: https://github.com/jcschuster/AtpMcp/releases/tag/v0.1.1
