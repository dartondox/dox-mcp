## Unreleased

- New: `McpOAuth`, the OAuth 2.1 sign-in of the MCP spec. Discovery files (RFC 9728, RFC 8414), dynamic client registration with signed client ids (nothing stored), PKCE `S256`, one-time codes in a Dox cache shared by the isolates, `authenticate` for `Authorization: Bearer`, and `unauthorized` with `WWW-Authenticate`. The app gives the consent page and the tokens (`McpOAuthTokens`).
- Use `RequestBody` and `BodyKind` from the public `package:dox_core/dox_core.dart` library. Needs `dox_core` 3.1.1.

## 3.1.0

- First release: `McpServer` (Streamable HTTP, JSON replies), `McpTool` with `dox_validation` input schemas, `McpTool.of`, `McpToolResult`, `McpContext`, and `SignedMcpSessions` (HMAC-signed ids from `APP_KEY`, an optional cache store for ended ids).
