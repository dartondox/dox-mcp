## Unreleased

- New: support for MCP protocol `2026-07-28`, next to the older versions on the same route. App code does not change. A `2026-07-28` request carries its version in `_meta` and needs no `initialize` and no session. The server answers `server/discover`, checks the `MCP-Protocol-Version`, `Mcp-Method` and `Mcp-Name` headers against the body, and adds `resultType` and the server info to each result. Old clients that send `initialize` work the same as before.
- New: `McpContext.clientCapabilities` and `McpContext.clientInfo`, sent by `2026-07-28` clients. Null for older clients. `McpContext.sessionId` is `''` for `2026-07-28` clients.
- New: `McpServer.statelessProtocolVersions` and `McpServer.supportedProtocolVersions`, and the error codes `JsonRpcCode.headerMismatch` (`-32020`) and `JsonRpcCode.unsupportedProtocolVersion` (`-32022`).
- New: a tool can ask the user a question during a call (multi round-trip requests of protocol `2026-07-28`). Return `McpToolResult.inputRequired(<McpInput<Object?>>[input])` and read the answer with `context.answer(input)`. The answer is `McpAccepted`, `McpDeclined` or `McpCancelled`. Inputs: `McpInput.confirm`, `text`, `number`, `choice` (an enum), `form` (a flat `@Dto`), `url`, and `McpCustomInput` for other kinds. Works in `McpTool` and `McpDtoTool`.
- The server only asks what the client can answer. Else it sends `-32021` (`JsonRpcCode.missingRequiredClientCapability`) with `400`. The `requestState` is signed with a key from `APP_KEY` (label `dox:mcp-state`) and works only for the same `scope`, tool and arguments, for 5 minutes. New `McpServer` options: `requestStateTtl` and `requestStateKey`. An old client gets an error result that says it must speak `2026-07-28`.
- New: `McpClientCapabilities.elicitationForm`, `elicitationUrl` and `has(path)`.
- New: OAuth client metadata documents (CIMD), the way the MCP spec `2026-07-28` asks clients to register. A `client_id` that is an `https` address is loaded from that address and checked (draft-ietf-oauth-client-id-metadata-document). The server file now says `client_id_metadata_document_supported: true`. `POST /oauth/register` still works for older clients, and signed client ids do not change.
- New: `McpOAuth.findClient`, `verifyClient` and `denyClient`. They are async and know both kinds of clients. `approve` and the token route use them. `client` knows signed clients only.
- `checkClient` and `deny` also know document clients, so a consent page from 3.2.1 keeps working. They are not async: if the document is not in memory, they start the load and throw `invalid_client`. A new try a moment later works.
- New: `McpOAuthClient.host`, the host of a document `client_id` (null for a signed client). Show it on the consent page next to the name.
- Failed document loads are kept for 1 minute (`McpOAuth.clientFailureAge`), per address. A host that does not answer is skipped for 1 minute, per host and port (`McpOAuthFetchException.hostFailed`). When the host gives no answer (timeout, no connection, `5xx`), the old document stays in use for 1 more hour (`McpOAuth.clientStaleAge`). When all slots are busy, for 5 more minutes (`McpOAuth.clientBusyStaleAge`). A real answer (like `404`, or a changed document) replaces it at once.
- A `no-store` document is kept for 1 minute for `checkClient` and `deny` only (`McpOAuth.clientHandOffAge`).
- New: `McpOAuthHttpFetcher(maxFetchesPerAddress:)` (default 2): at most 2 loads to one IP address at the same time. Past it, the fetcher throws `McpOAuthFetchBusyException`, which is not kept as a failure. New: `McpOAuthAddressSlots`.
- New `McpOAuth` option `maxClientFetchesPerHost` (default 2): how many document loads can go to one host and port at the same time.
- New: a batch (protocols before `2026-07-28`) can have at most 50 messages (`McpServer.maxBatchSize`). A bigger batch gets `400` with `-32600` (Invalid Request), and no message in it runs.
- New `McpOAuth` options: `allowedClientHosts` (only load documents from these hosts; default: any public host), `clientCacheMaxAge` (default 5 minutes), `maxClientFetches` (default 8: how many documents each isolate loads at the same time; past it, a new address gets `invalid_client` at once, with no wait) and `clientFetcher` (a `McpOAuthClientFetcher`; tests give fake documents).
- The default fetcher (`McpOAuthHttpFetcher`) guards against SSRF: `https` only, public addresses only (it connects to the address it checked), no redirects, short timeouts, at most 5 KB, JSON only. A failure gives `invalid_client` and never shows the inside error.
- New: `McpServer` writes a warning to stderr once when `allowedOrigins` is not set. Without it, any website can call the server from a browser (DNS rebinding). The default does not change.

## 3.2.1

- Fix: a tool that throws no longer sends the error text to the MCP client in production. The text can hold hosts, SQL or passwords. The client now gets `Tool failed`. The full error text is still shown when `APP_ENV` is `development` or `local`, the same rule as the Dox web responses. `onToolError` always gets the full error. An error that a tool returns on purpose with `McpToolResult.error(...)` is sent as it is.

## 3.2.0

- New: `dox add mcp` (the `mcp:install` command). It adds `lib/config/mcp.dart` with the `McpServer` and a sample `EchoTool`. It never overwrites a file. New dependency: `dox_annotation`.
- Ships an AI agent skill (dox-mcp-guide). Install it in your app with `dart run skills@ get`.
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
