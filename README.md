# AtpMcp

An [MCP](https://modelcontextprotocol.io) server that exposes
[SystemOnTPTP](https://www.tptp.org/cgi-bin/SystemOnTPTP) theorem provers as
tools for Claude Code and other MCP clients. Built on
[AtpClient](https://hex.pm/packages/atp_client).

## Installation

Install the escript via Hex:

```bash
mix escript.install hex atp_mcp
```

This places the `atp_mcp` binary in `~/.mix/escripts/`. Make sure that directory is on your `PATH`:

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

### `list_provers`

Lists all theorem prover systems currently available on SystemOnTPTP.

### `run_prover`

Submits a TPTP-format problem to a single prover and returns the SZS status.

| Argument         | Type    | Required | Description                                           |
| ---------------- | ------- | -------- | ----------------------------------------------------- |
| `problem`        | string  | yes      | TPTP problem text                                     |
| `system_id`      | string  | yes      | Prover ID (from `list_provers`)                       |
| `time_limit_sec` | integer | no       | Time limit in seconds                                 |
| `raw`            | boolean | no       | Return raw prover output instead of normalized status |

### `compare_provers`

Runs the same problem against multiple provers simultaneously and returns all
results side by side.

| Argument         | Type     | Required | Description                      |
| ---------------- | -------- | -------- | -------------------------------- |
| `problem`        | string   | yes      | TPTP problem text                |
| `system_ids`     | string[] | yes      | List of prover IDs to compare    |
| `time_limit_sec` | integer  | no       | Time limit per prover in seconds |

## Example

Once the MCP server is active, you can ask Claude Code things like:

> "Which provers on SystemOnTPTP can prove this TPTP problem? Compare Vampire,
> E, and Satallax."

Claude will call `compare_provers` directly and report the SZS results.

## Configuration via `config.exs`

SystemOnTPTP connection settings are read from `AtpClient` configuration. To
override the default endpoint or cache behavior, add to your
`config/config.exs`:

```elixir
config :atp_client, :sotptp,
  url: "https://tptp.org/cgi-bin/SystemOnTPTPFormReply",
  default_time_limit_sec: 30
```

See the [AtpClient docs](https://hexdocs.pm/atp_client) for all available
options.

## License

MIT.
