# AtpMcp

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.23044595.svg)](https://doi.org/10.5281/zenodo.23044595)

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img alt="AtpMcp" src="assets/logo-light.svg" height="72">
  </picture>
</p>

An [MCP](https://modelcontextprotocol.io) server that exposes
[AtpClient](https://hex.pm/packages/atp_client)'s four theorem-prover
backends — **SystemOnTPTP**, **StarExec**, **Isabelle**, and **LocalExec** —
as tools for Claude Code and other MCP hosts.

Speaks MCP revision `2026-07-28` over stdio (JSON-RPC 2.0), and only that
revision: clients that need the `initialize` handshake (`2025-11-25` and
earlier) are rejected.

## Quick start with Docker

The image bundles the server, Erlang, and the E prover, so the only
prerequisite is Docker. Add the server to your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "atp": {
      "command": "docker",
      "args": ["run", "-i", "--rm", "ghcr.io/jcschuster/atp_mcp:latest"]
    }
  }
}
```

That gives you SystemOnTPTP (every prover on tptp.org) and a local E
(`query_backend` with `backend: "local_exec"`) with no configuration.

For Isabelle as well, use the `latest-isabelle` tag (amd64, a few GB; the
container needs a few GB of RAM for the HOL session). The server starts
Isabelle itself on the first Isabelle call, which takes up to a minute;
later calls in the same session reuse it.

To configure the server, mount your project at `/work`, where it looks for
[`atp_mcp.exs`](#configuration), and forward the environment variables
the file reads:

```json
{
  "mcpServers": {
    "atp": {
      "command": "docker",
      "args": [
        "run",
        "-i",
        "--rm",
        "-v",
        "${PWD}:/work:ro",
        "-e",
        "STAREXEC_USER",
        "-e",
        "STAREXEC_PASS",
        "ghcr.io/jcschuster/atp_mcp:latest"
      ],
      "env": { "STAREXEC_USER": "me", "STAREXEC_PASS": "…" }
    }
  }
}
```

For Claude Code, also approve the server in `.claude/settings.json`:

```json
{
  "enabledMcpjsonServers": ["atp"]
}
```

To build the images yourself:

```bash
docker build -t atp_mcp .                             # SystemOnTPTP + E
docker build -t atp_mcp:isabelle --target isabelle .  # + Isabelle/HOL
```

## Installing the escript

Without Docker, install the escript (Elixir 1.20 / OTP 29):

```bash
mix escript.install hex atp_mcp
export PATH="$HOME/.mix/escripts:$PATH"
```

and use `"command": "atp_mcp"` in `.mcp.json`. Local backends then use
whatever is on your `PATH`: `eprover` for `local_exec`, `isabelle` for the
Isabelle backend.

## Configuration

The escript does not read your project's `config/*.exs`. It reads one
config file at startup, the first of:

1. `atp_mcp --config PATH`;
2. the `ATP_MCP_CONFIG` environment variable;
3. `atp_mcp.exs` in the working directory — for an MCP host, the project
   root (`/work` in the container).

The file is ordinary Elixir `Config`, evaluated at startup, so read
secrets from the environment rather than writing them into it:

```elixir
# atp_mcp.exs
import Config

config :atp_client, :sotptp,
  default_system: "Vampire",       # a bare name runs the latest version
  default_time_limit_sec: 30

config :atp_client, :local_exec,
  binary: "vampire",
  args: ["--mode", "casc", "-t", "30"],
  cpu_timeout_s: 30

config :atp_client, :starexec,
  base_url: "https://starexec.example.org/starexec",
  username: System.get_env("STAREXEC_USER"),
  password: System.get_env("STAREXEC_PASS")
```

Without any configuration:

- **SystemOnTPTP** uses tptp.org and the latest `E`.
- **LocalExec** runs `eprover --auto --tstp-format --cpu-limit=30` if
  `eprover` is on `PATH`.
- **Isabelle** starts a resident server named `atp_mcp` on a free port if
  `isabelle` is on `PATH`, or reuses one that is already running. Outside a
  container that server outlives the MCP process, so later sessions skip
  the startup cost. Stop it with `isabelle server -n atp_mcp -x`. To use a
  server you run yourself, configure it instead:

  ```elixir
  config :atp_client, :isabelle,
    host: "isabelle.example.org",
    port: 9999,
    password: System.get_env("ISABELLE_PASSWORD")
  ```

  and set `config :atp_mcp, isabelle_autostart: false` to rule out a local
  one.

- **StarExec** has no defaults; it needs `base_url`, `username`, and
  `password`.

See the [AtpClient docs](https://hexdocs.pm/atp_client) for every setting.

### Checking the setup

`atp_mcp doctor` prints, for each backend, the settings it resolved to and
whether it is reachable. Run it the way your MCP host runs the server:

```console
$ docker run --rm -v "$PWD:/work:ro" ghcr.io/jcschuster/atp_mcp doctor
atp_mcp 0.8.0
config file: /work/atp_mcp.exs

sotptp - SystemOnTPTP
  url: "https://tptp.org/cgi-bin/SystemOnTPTPFormReply"
  default_system: "Vampire"
  default_time_limit_sec: 30
  check: OK
…
```

Name backends to check only those (`atp_mcp doctor sotptp local_exec`). It
exits with status 1 if any check fails, and passwords are shown only as set
or unset.

## Tools

### Cross-backend (unified `AtpClient.Backend`)

#### `list_backends`

Lists every backend the server exposes (`sotptp`, `isabelle`, `local_exec`,
`starexec`) with its human-readable label.

#### `describe_szs`

Returns a text reference for the
[SZS Ontology](https://szs.tptp.org) — the vocabulary every prover verdict
is reported in. Lists every Success status (`Theorem`, `Unsatisfiable`,
`Satisfiable`, `CounterSatisfiable`, `ContradictoryAxioms`, …) and NoSuccess
status (`GaveUp`, `Timeout`, `ResourceOut`, `MemoryOut`, `Forced`,
`InputError`, …) with its mnemonic and definition, so an agent can decide
what a verdict means without leaving the MCP session. Generated from
`Tptp.Szs.Ontology`, the table verdicts are read against. Takes no
arguments.

#### `verify_backend`

Probes a backend's configuration and reachability. Returns `OK` or a
descriptive error.

| Argument  | Type   | Required | Description                                          |
| --------- | ------ | -------- | ---------------------------------------------------- |
| `backend` | string | yes      | `sotptp` \| `isabelle` \| `local_exec` \| `starexec` |

Backend-specific override keys (`base_url`, `password`, `binary`, …) are
forwarded through to the backend's `verify/1`.

#### `query_backend`

Submits a TPTP-format problem to any backend through the unified
`c:AtpClient.Backend.query/2` entry point and returns an SZS Ontology
verdict (`Theorem`, `Unsatisfiable`, `Satisfiable`, `CounterSatisfiable`,
`GaveUp`, `Timeout`, `ResourceOut`, …). Call `describe_szs` for the full
vocabulary.

| Argument         | Type    | Required | Description                                                    |
| ---------------- | ------- | -------- | -------------------------------------------------------------- |
| `backend`        | string  | yes      | `sotptp` \| `isabelle` \| `local_exec` \| `starexec`           |
| `problem`        | string  | yes      | TPTP problem text                                              |
| `time_limit_sec` | integer | no       | Applied by backends that honour it (`sotptp`)                  |
| `raw`            | boolean | no       | Return the system's verbatim output instead of the SZS verdict |

Per-backend overrides are passed through (e.g. `binary` for `local_exec`,
`timeout_ms` for `isabelle`, `base_url` for `starexec`, and `system` — the
SystemOnTPTP name of the prover behind a `local_exec` binary or a `starexec`
solver, for reading its output).

### SystemOnTPTP

#### `list_provers`

Lists every theorem prover system available on SystemOnTPTP.

#### `run_prover`

Submits a TPTP problem to a specific prover and returns its SZS status.

| Argument         | Type    | Required | Description                                                                      |
| ---------------- | ------- | -------- | -------------------------------------------------------------------------------- |
| `problem`        | string  | yes      | TPTP problem text                                                                |
| `system_id`      | string  | yes      | Prover ID from `list_provers`, or a bare name (`Vampire`) for the latest version |
| `time_limit_sec` | integer | no       | Time limit in seconds                                                            |
| `raw`            | boolean | no       | Return the prover's verbatim output instead of the SZS verdict                   |

#### `compare_provers`

Runs the same problem against multiple provers simultaneously and returns
all results side by side, one row per requested system in the order given.
A bare name shows the version it ran:

```
Vampire (Vampire---5.0.1): CounterSatisfiable
E---3.5.1: CounterSatisfiable
Nope: not a system on SystemOnTPTP (see list_provers)
```

| Argument         | Type     | Required | Description                         |
| ---------------- | -------- | -------- | ----------------------------------- |
| `problem`        | string   | yes      | TPTP problem text                   |
| `system_ids`     | string[] | yes      | Prover IDs or bare names to compare |
| `time_limit_sec` | integer  | no       | Time limit per prover in seconds    |

### Isabelle

#### `prove_isabelle`

Submits a **hand-written** Isabelle/HOL theory to a configured Isabelle
server. The theory text is written into the configured shared directory and
processed via `use_theories`. For TPTP/THF problems, use `query_backend`
with `backend: "isabelle"` instead — that routes through `prove_tptp`.
Session, host, port, and password come from configuration only.

| Argument      | Type    | Required | Description                                           |
| ------------- | ------- | -------- | ----------------------------------------------------- |
| `theory`      | string  | yes      | Isabelle theory text (full or body only)              |
| `theory_name` | string  | yes      | Theory name (also used as the `.thy` filename)        |
| `timeout_ms`  | integer | no       | Overall `use_theories` timeout in milliseconds        |
| `raw`         | boolean | no       | Return Isabelle's message text instead of the verdict |

### Diagnostics

#### `lint_problem`

Runs syntax and type diagnostics on a TPTP problem. By default combines the
in-process [`tptp`](https://hex.pm/packages/tptp) linter (`Tptp.analyze/2`)
with TPTP4X on SystemOnTPTP; pass `backends: ["local"]` for the cheap pass
only. TPTP4X is skipped when the local pass already found an error. Each
finding is reported as `line:column [severity] (source) message [code]`,
with the linter's hint where it gives one, followed by the declared symbols
and their types:

```
2:8 [warning] (tptp) "axim" is not a TPTP formula role [TPTP0401]
    hint: expected one of axiom, hypothesis, definition, …
2:12 [error] (tptp4x) Invalid role, exiting [TPTP4X]

Symbols:
  plus : $i > $i (declared at 1:14)
```

| Argument   | Type     | Required | Description                                        |
| ---------- | -------- | -------- | -------------------------------------------------- |
| `problem`  | string   | yes      | TPTP problem text                                  |
| `backends` | string[] | no       | Subset of `["local", "tptp4x"]`; default runs both |

## Example

Once the MCP server is active, you can ask Claude Code things like:

> "Which provers on SystemOnTPTP can prove this TPTP problem? Compare
> Vampire, E, and Satallax."

Claude will call `compare_provers` directly and report the SZS results.

> "Run this problem against my local E build, then sanity-check it on
> SystemOnTPTP."

Claude will call `query_backend` twice — once with `backend: "local_exec"`,
once with `backend: "sotptp"` — and compare the verdicts.

## Agent skill

[`skills/atp-mcp/SKILL.md`](https://github.com/jcschuster/AtpMcp/blob/main/skills/atp-mcp/SKILL.md) is an
[Agent Skill](https://agentskills.io) that teaches an agent to use these
tools: the TPTP dialects and which provers accept them, a lint-then-prove
workflow, and what each SZS verdict lets it conclude. It also lists tasks
where a prover helps, such as autoformalisation, checking proofs, and
finding counterexamples, so agents reach for the tools unprompted. To use
it with Claude Code, copy the directory into `.claude/skills/` in your
project or `~/.claude/skills/`.

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

## Forward note: MCP Tasks extension

MCP **Tasks** (call now, fetch later through a task handle) fit ATP
workflows almost exactly. Revision `2026-07-28` moved them out of the core
protocol into the official extension `io.modelcontextprotocol/tasks`. Once
MCP hosts support the extension, the long-running tools here should return
tasks, which would also make a StarExec-style `submit_job` / `await_job`
pair natural.

## License

MIT.
