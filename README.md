# AtpMcp

An [MCP](https://modelcontextprotocol.io) server that exposes
[AtpClient](https://hex.pm/packages/atp_client)'s four theorem-prover
backends — **SystemOnTPTP**, **StarExec**, **Isabelle**, and **LocalExec** —
as tools for Claude Code and other MCP hosts.

Speaks MCP revision `2025-11-25` over stdio (JSON-RPC 2.0).

## Installation

```bash
mix escript.install hex atp_mcp
```

This places the `atp_mcp` binary in `~/.mix/escripts/`. Make sure that
directory is on your `PATH`:

```bash
export PATH="$HOME/.mix/escripts:$PATH"
```

## Configuration

Add the server to your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "atp": {
      "command": "atp_mcp"
    }
  }
}
```

For Claude Code, also approve it in `.claude/settings.json`:

```json
{
  "enabledMcpjsonServers": ["atp"]
}
```

## Tools

### Cross-backend (unified `AtpClient.Backend`)

#### `list_backends`

Lists every backend the server exposes (`sotptp`, `isabelle`, `local_exec`,
`starexec`) with its human-readable label.

#### `describe_szs`

Returns a text reference for the
[SZS Ontology](https://tptp.org/UserDocs/SZSOntology/) — the vocabulary
every prover verdict is reported in. Enumerates each Success status
(`Theorem`, `Unsatisfiable`, `Satisfiable`, `CounterSatisfiable`,
`ContradictoryAxioms`, `Equivalent`, `Tautology`, …) and NoSuccess status
(`GaveUp`, `Timeout`, `ResourceOut`, `MemoryOut`, `Forced`, `Inappropriate`,
`InputError`, …) with a short gloss so an agent can decide what a verdict
means without leaving the MCP session. Takes no arguments.

#### `verify_backend`

Probes a backend's configuration and reachability. Returns `OK` or a
descriptive error.

| Argument  | Type   | Required | Description                                                       |
| --------- | ------ | -------- | ----------------------------------------------------------------- |
| `backend` | string | yes      | `sotptp` \| `isabelle` \| `local_exec` \| `starexec`              |

Backend-specific override keys (`base_url`, `password`, `binary`, …) are
forwarded through to the backend's `verify/1`.

#### `query_backend`

Submits a TPTP-format problem to any backend through the unified
`c:AtpClient.Backend.query/2` entry point and returns an SZS Ontology
verdict (`Theorem`, `Unsatisfiable`, `Satisfiable`, `CounterSatisfiable`,
`GaveUp`, `Timeout`, `ResourceOut`, …). Call `describe_szs` for the full
vocabulary.

| Argument         | Type    | Required | Description                                                       |
| ---------------- | ------- | -------- | ----------------------------------------------------------------- |
| `backend`        | string  | yes      | `sotptp` \| `isabelle` \| `local_exec` \| `starexec`              |
| `problem`        | string  | yes      | TPTP problem text                                                 |
| `time_limit_sec` | integer | no       | Applied by backends that honour it (`sotptp`)                     |
| `raw`            | boolean | no       | Return raw backend output where the backend supports it           |

Per-backend overrides are passed through (e.g. `binary` for `local_exec`,
`session`/`host`/`port` for `isabelle`, `base_url` for `starexec`).

### SystemOnTPTP

#### `list_provers`

Lists every theorem prover system available on SystemOnTPTP.

#### `run_prover`

Submits a TPTP problem to a specific prover and returns its SZS status.

| Argument         | Type    | Required | Description                                           |
| ---------------- | ------- | -------- | ----------------------------------------------------- |
| `problem`        | string  | yes      | TPTP problem text                                     |
| `system_id`      | string  | yes      | Prover ID (from `list_provers`)                       |
| `time_limit_sec` | integer | no       | Time limit in seconds                                 |
| `raw`            | boolean | no       | Return raw prover output instead of normalized status |

#### `compare_provers`

Runs the same problem against multiple provers simultaneously and returns
all results side by side.

| Argument         | Type     | Required | Description                      |
| ---------------- | -------- | -------- | -------------------------------- |
| `problem`        | string   | yes      | TPTP problem text                |
| `system_ids`     | string[] | yes      | List of prover IDs to compare    |
| `time_limit_sec` | integer  | no       | Time limit per prover in seconds |

### Isabelle

#### `prove_isabelle`

Submits a **hand-written** Isabelle/HOL theory to a configured Isabelle
server. The theory text is written into the configured shared directory and
processed via `use_theories`. For TPTP/THF problems, use `query_backend`
with `backend: "isabelle"` instead — that routes through `query_tptp`.

| Argument      | Type    | Required | Description                                            |
| ------------- | ------- | -------- | ------------------------------------------------------ |
| `theory`      | string  | yes      | Isabelle theory text (full or body only)               |
| `theory_name` | string  | yes      | Theory name (also used as the `.thy` filename)         |
| `session`     | string  | no       | Override the Isabelle session name                     |
| `host`        | string  | no       | Override the Isabelle host                             |
| `port`        | integer | no       | Override the Isabelle port                             |
| `timeout_ms`  | integer | no       | Overall `use_theories` timeout in milliseconds         |
| `raw`         | boolean | no       | Return the raw `use_theories` payload                  |

### Diagnostics

#### `lint_problem`

Runs syntax and type diagnostics on a TPTP problem. By default combines the
in-process structural checker with TPTP4X on SystemOnTPTP; pass
`backends: ["local"]` for the cheap pass only.

| Argument   | Type     | Required | Description                                             |
| ---------- | -------- | -------- | ------------------------------------------------------- |
| `problem`  | string   | yes      | TPTP problem text                                       |
| `backends` | string[] | no       | Subset of `["local", "tptp4x"]`; default runs both      |

## Example

Once the MCP server is active, you can ask Claude Code things like:

> "Which provers on SystemOnTPTP can prove this TPTP problem? Compare
> Vampire, E, and Satallax."

Claude will call `compare_provers` directly and report the SZS results.

> "Run this problem against my local E build, then sanity-check it on
> SystemOnTPTP."

Claude will call `query_backend` twice — once with `backend: "local_exec"`,
once with `backend: "sotptp"` — and compare the verdicts.

## Configuration via `config.exs`

Backend connection settings are read from `AtpClient` configuration:

```elixir
config :atp_client, :sotptp,
  url: "https://tptp.org/cgi-bin/SystemOnTPTPFormReply",
  default_time_limit_sec: 30

config :atp_client, :isabelle,
  host: "isabelle.example.org",
  port: 9999,
  password: System.get_env("ISABELLE_PASSWORD"),
  local_dir: "/shared/problems",
  session: "HOL"

config :atp_client, :local_exec,
  binary: "eprover",
  args: ["--auto", "--tstp-format", "--cpu-limit=10"],
  cpu_timeout_s: 10

config :atp_client, :starexec,
  base_url: "https://starexec.example.org/starexec",
  username: System.get_env("STAREXEC_USER"),
  password: System.get_env("STAREXEC_PASS")
```

See the [AtpClient docs](https://hexdocs.pm/atp_client) for the full
configuration surface.

## Cancellation and progress

Long-running tool calls run inside their own Task. The MCP host can:

- Send `notifications/cancelled` with the in-flight request id to abort
  a call. Each `AtpClient` backend tears down its upstream work on
  caller death:
  - **LocalExec** SIGKILLs the prover binary via `Port` closure.
  - **StarExec** issues `DELETE` against the remote job.
  - **Isabelle** drops the session, which aborts the in-flight
    `use_theories` task on the server.
  - **SystemOnTPTP** closes the local connection, but the remote prover
    runs to its `:time_limit_sec` — SOTPTP has no remote-cancel
    endpoint.
- Set `_meta.progressToken` on `tools/call` to receive periodic
  `notifications/progress` frames while the call is in flight. The
  heartbeat fires every five seconds by default; override via:

  ```elixir
  config :atp_mcp, heartbeat_ms: 10_000
  ```

## Forward note: MCP experimental Tasks primitive

The `2025-11-25` MCP revision incubates an experimental **Tasks** primitive
(call-now / fetch-later, with a task handle for status polling and deferred
result retrieval). That maps onto ATP workflows almost exactly. When the
primitive stabilises, the long-running tools here should grow a
task-returning variant, and a StarExec-style `submit_job` / `await_job`
pair becomes natural to add.

## License

MIT.
