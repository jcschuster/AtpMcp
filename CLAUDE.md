# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
mix test                   # unit tests (backends are Mox mocks; no network)
mix escript.build          # compile the atp_mcp escript binary
mix escript.install . --force  # install the built escript to ~/.mix/escripts/
mix docs                   # generate ExDoc HTML docs
mix credo --all            # lint
mix dialyzer               # type checking
docker build -t atp_mcp .                             # image: SystemOnTPTP + E
docker build -t atp_mcp:isabelle --target isabelle .  # image: + Isabelle/HOL
```

There is no `.formatter.exs`; format files explicitly (`mix format lib/atp_mcp.ex …`).

Manual integration testing pipes JSON-RPC 2.0 messages to the binary, or checks the
setup with the doctor:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ./atp_mcp
./atp_mcp doctor sotptp local_exec
```

## Architecture

```
stdin (newline-delimited JSON-RPC 2.0)
  → AtpMcp.Runtime     (GenServer; owns stdout; one Task per tools/call)
  → AtpMcp.classify/1  (pattern match on "method")
  → AtpMcp.execute_tool/2 → call_tool/2 (delegate to AtpClient / tptp)
  → Jason.encode!      (serialize response)
  → stdout
```

- `AtpMcp` — CLI (`main/1`: serve, `doctor`, `--config`), MCP protocol, tool
  schemas, result formatting.
- `AtpMcp.Runtime` — the only writer to stdout; cancellation and progress.
- `AtpMcp.Settings` — loads `--config` / `$ATP_MCP_CONFIG` / `./atp_mcp.exs` into
  the application env at startup and applies defaults (E for `local_exec`).
- `AtpMcp.IsabelleSession` — one long-lived Isabelle session; starts a resident
  server `atp_mcp` when no password is configured.
- `AtpMcp.Doctor` — the `atp_mcp doctor` report.
- `AtpMcp.Backends` — behaviours the tests mock.

**Key boundaries:**
- `AtpMcp` owns the MCP protocol (JSON-RPC framing, tool schemas, SZS result formatting).
- `AtpClient` backends own all prover communication — never call SystemOnTPTP, StarExec,
  or Isabelle directly. `tptp` owns parsing, linting, and the SZS ontology.
- Tool schemas (`tool_schemas/0`) and tool dispatch (`call_tool/2`) must stay in sync
  whenever tools are added or changed.
- AtpClient validates options and raises on unknown keys, so `opts_from/2` forwards
  only whitelisted keys per backend.

**MCP protocol notes:**
- stdout is the protocol channel: never print to it outside `AtpMcp.Runtime`. Logger
  goes to stderr (`config/config.exs`, build time — it cannot be changed at runtime).
- Notifications (no `"id"` field) must return `nil` — not an error response.
- The protocol version is `"2025-11-25"`.
- Tool results are `%{content: [%{type: "text", text: ...}]}`, with `isError: true`
  for tool-level failures.

## Releasing

Bump `@version` in `mix.exs`, `version`/`date-released` in `CITATION.cff`, `version`
in `.zenodo.json`, and date the CHANGELOG section. A `v*` tag publishes the Docker
images (`.github/workflows/docker.yml`).
