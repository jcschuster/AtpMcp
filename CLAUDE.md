# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
mix escript.build          # compile the atp_mcp escript binary
mix escript.install . --force  # install the built escript to ~/.mix/escripts/
mix docs                   # generate ExDoc HTML docs
mix credo --all            # lint
mix dialyzer               # type checking
```

There is no test suite. Manual integration testing is done by piping JSON-RPC 2.0 messages to the binary:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ./atp_mcp
```

## Architecture

This is a single-module escript (`lib/atp_mcp.ex`). There are no supervision trees, GenServers, or processes — it is purely functional.

**Data flow:**

```
stdin (newline-delimited JSON-RPC 2.0)
  → process_line/1    (trim, decode JSON)
  → dispatch/1        (pattern match on "method")
  → call_tool/2       (delegate to AtpClient)
  → Jason.encode!     (serialize response)
  → stdout
```

**Key boundaries:**
- `AtpMcp` owns the MCP protocol (JSON-RPC framing, tool schemas, SZS result formatting).
- `AtpClient.SystemOnTptp` owns all HTTP communication with SystemOnTPTP — never call the TPTP endpoint directly.
- Tool schemas (`tool_schemas/0`) and tool dispatch (`call_tool/2`) must stay in sync whenever tools are added or changed.

**MCP protocol notes:**
- Notifications (no `"id"` field) must return `nil` — not an error response.
- The protocol version is `"2024-11-05"`.
- All tool results are wrapped as `%{content: [%{type: "text", text: ...}]}`.
