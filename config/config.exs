import Config

# stdout is the MCP channel: a log line there is a malformed JSON-RPC frame
# that the client drops or chokes on. An escript's default Logger handler
# writes to stdout, and its type cannot be changed once the handler runs,
# so it is set here, at build time.
config :logger, :default_handler, config: [type: :standard_error]
