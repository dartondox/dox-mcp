## Unreleased

- Fix: the token route gives `invalid_grant` when the lock of a code times out, also when the cache throws `LockTimeoutException` on a lock timeout. Before, that gave a `500`.
- Fix: the token route answered `400` for `invalid_client`. RFC 6749 (5.2) asks for `401`, and for a `WWW-Authenticate` header when the client sent an `Authorization` header. Now it answers `401`, and adds `WWW-Authenticate` with the scheme the client used. The body is the same.
- A code now expires exactly after `codeTtl`. Before, only the cache TTL ended it, so it depended on the cache store.
- New: `McpOAuth(now:)`, an optional function that gives the time. Default: `DateTime.now`. Tests can pass a fake clock.

## 3.1.2

- New: `McpDtoTool<T>`, a tool that takes a `@Dto` class as its input. `inputSchema` comes from the DTO, so `@Describe` texts show up. The arguments are checked like a DTO in a controller (async rules too), and `handle` gets the typed object. Bad arguments are a tool result with `isError: true` that lists each problem.
- New: `McpToolResult.invalidArguments(tool, issues)`, the error result for bad arguments.
- Fix: a `code_verifier` with non-ASCII characters made the token route crash with a 500. Now a verifier must be 43 to 128 characters of `A-Z a-z 0-9 - . _ ~` (RFC 7636). Other verifiers get `invalid_request`.
- `approve` now checks that `code_challenge` is 43 base64url characters, the shape of an S256 challenge.
- A redirect address at registration may be at most 2048 characters (`McpOAuth.maxRedirectUriLength`). Longer ones get `invalid_redirect_uri`.
- Docs: the consent page must show the redirect host and HTML-escape the client name.

## 3.1.1

- New: `McpOAuth`, the OAuth 2.1 sign-in of the MCP spec. Discovery files (RFC 9728, RFC 8414), dynamic client registration with signed client ids (nothing stored), PKCE `S256`, one-time codes in a Dox cache shared by the isolates, `authenticate` for `Authorization: Bearer`, and `unauthorized` with `WWW-Authenticate`. The app gives the consent page and the tokens (`McpOAuthTokens`).
- Use `RequestBody` and `BodyKind` from the public `package:dox_core/dox_core.dart` library. Needs `dox_core` 3.1.1.

## 3.1.0

- First release: `McpServer` (Streamable HTTP, JSON replies), `McpTool` with `dox_validation` input schemas, `McpTool.of`, `McpToolResult`, `McpContext`, and `SignedMcpSessions` (HMAC-signed ids from `APP_KEY`, an optional cache store for ended ids).
