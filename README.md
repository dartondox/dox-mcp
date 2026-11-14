# dox_mcp

A [Model Context Protocol](https://modelcontextprotocol.io) (MCP) server for the [Dox](https://dartondox.dev) framework.

It serves tools to MCP clients (Claude, ChatGPT, IDE agents) over the Streamable HTTP transport, from a normal Dox route.

- Tool arguments are `dox_validation` schemas: clients see them as JSON Schema, and every call is checked before your code runs.
- Session ids are signed with `APP_KEY`, so a session made on one isolate works on every isolate, and after a restart. No store is needed.
- Replies are plain JSON. No SSE stream is needed for tools.

## Install

```bash
dart pub add dox_mcp
```

## Use

Write a tool:

```dart
import 'package:dox_core/dox_core.dart';
import 'package:dox_mcp/dox_mcp.dart';

class AddExpense extends McpTool {
  @override
  String get name => 'add_expense';

  @override
  String get description => 'Record an expense. Amount is in dollars.';

  @override
  ObjectSchema get input => v.object(<String, Schema<Object?>>{
    'amount': v.num().positive().describe('Amount, like 12.50.'),
    'note': v.string().max(500).optional(),
  });

  @override
  Future<McpToolResult> call(Map<String, dynamic> args, McpContext context) async {
    User user = context.authAs<User>();
    // ... save it
    return McpToolResult.text('Recorded ${args['amount']} for ${user.email}.');
  }
}
```

Serve it on a route. Find the user first (from a token, a header or the URL), and pass it as `auth`. `scope` ties each session to that user:

```dart
final McpServer mcp = McpServer(
  name: 'my-app',
  version: '1.0.0',
  tools: <McpTool>[AddExpense()],
);

Route.match(<String>['GET', 'POST', 'DELETE'], '/mcp/{token}', (DoxRequest req) async {
  User? user = await User().where('mcp_token', req.param['token']).getFirst();
  if (user == null) return response('Invalid token').statusCode(401);
  return mcp.handle(req, auth: user, scope: 'user:${user.id}');
});
```

A small tool can be a function:

```dart
McpTool.of(
  name: 'echo',
  description: 'Say the text back.',
  input: v.object(<String, Schema<Object?>>{'text': v.string()}),
  handler: (Map<String, dynamic> args, McpContext context) {
    return McpToolResult.text(args['text'] as String);
  },
);
```

## Tools that take a DTO

A tool can take a `@Dto` class as its input. Extend `McpDtoTool<T>`. The rules of the DTO (like `@Length` and `@HexColor`) are written once, and `handle` gets the typed object, not a map.

Use `@Describe` on a field to explain it to the model. It goes into the JSON Schema as `description`. It does not change the checks.

```dart
@Dto()
class NewCategory {
  @Describe('The category name, like Food.')
  @Length(min: 1, max: 50)
  final String name;

  @Describe('A color, like #1a2b3c.')
  @HexColor()
  final String color;

  const NewCategory({required this.name, required this.color});

  static const DtoSchema<NewCategory> schema = $NewCategoryDto;
}

class CreateCategory extends McpDtoTool<NewCategory> {
  @override
  String get name => 'create_category';

  @override
  String get description => 'Add a category.';

  @override
  DtoSchema<NewCategory> get dto => NewCategory.schema;

  @override
  Future<McpToolResult> handle(NewCategory input, McpContext context) async {
    // ... save it
    return McpToolResult.text('Added ${input.name}.');
  }
}
```

- `tools/list` sends the JSON Schema of the DTO (`toJsonSchema()`) as `inputSchema`.
- The arguments are checked like a DTO in a controller, with async rules like `@Unique` and `@Exists` too.
- Bad arguments are a tool result with `isError: true`, not a JSON-RPC error. The text lists each problem, so the model can fix the call:

```text
Input validation error: Invalid arguments for tool create_category: name: The name is required; color: The color must be a hex color like #1a2b3c
```

## What the server answers

| Request | Answer |
| --- | --- |
| `POST` `initialize` | `200` with the server info and an `Mcp-Session-Id` header |
| `POST` a request with a valid `Mcp-Session-Id` | `200` with the JSON-RPC response (a list for a batch) |
| `POST` only notifications or responses | `202`, no body |
| `POST` with no session id | `400` |
| `POST` with an unknown or ended session id, or one of another `scope` | `404`, so the client starts a new session |
| `POST` with an unsupported `MCP-Protocol-Version` header | `400` |
| `POST` with another `Content-Type` than JSON | `415` |
| `GET` | `405`: there is no server-to-client stream |
| `DELETE` with a session id | `200`, the session ends |

Methods: `initialize`, `ping`, `tools/list`, `tools/call`. Others get `-32601 Method not found`.

- An unknown tool is a JSON-RPC error (`-32602`).
- Bad arguments are a tool result with `isError: true` and the problems, so the model can fix them.
- A tool that throws gives a tool result with `isError: true`. The client gets `Tool failed`, unless `APP_ENV` is `development` or `local`. A tool that wants the model to see a message must return `McpToolResult.error(...)`. `onToolError` gets the full error, for logs.

Protocol versions: `2025-11-25`, `2025-06-18`, `2025-03-26` and `2024-11-05`. A client that asks for another one gets the newest.

## Sessions

`SignedMcpSessions` (the default) makes ids like `<random>.<signature>`. The signature is HMAC-SHA256 of the random part and the `scope`, with a key made from `APP_KEY` (label `dox:mcp`).

- Every isolate, and every server with the same `APP_KEY`, can check an id. Nothing is stored.
- A new `APP_KEY` ends every session. Clients start a new one by themselves.
- A signed id cannot be ended by itself. To refuse ended ids, give a cache store: `SignedMcpSessions(ended: Cache().store('redis'))`. Use a store that all isolates share (file or Redis, not memory).

For another kind of session, implement `McpSessions`.

## OAuth sign-in

`McpOAuth` lets a client sign in by itself. You give the client only the address, like `https://my.app/mcp`. This is the sign-in of the MCP spec (OAuth 2.1 with PKCE).

`dox_mcp` does the OAuth part. Your app does three things:

1. **Tokens.** Implement `McpOAuthTokens`: `issue` makes a token for a grant, `verify` gives what a token stands for (like the user id), or null. You choose the table and how a token is revoked. Keep only a hash of it.
2. **The consent page.** At `<issuer>/oauth/authorize` (or `authorizePage:`). It reads `client_id`, `redirect_uri`, `state`, `code_challenge`, `code_challenge_method` and `resource` from the query. The person signs in there the way your app always does.
3. **The yes.** Your page calls your own route, with your own login. That route calls `oauth.approve(subject: ...)` and gives the page the address to send the browser to. On no, `oauth.deny(...)`. `oauth.checkClient(...)` gives the client's name for the page.

On the consent page:

- Show the host of `redirect_uri`, so the person sees where they are sent.
- HTML-escape the client name. The client chooses it, so it can hold any text.

```dart
final McpOAuth oauth = McpOAuth(
  issuer: 'https://my.app',
  tokens: MyTokens(),
  codes: Cache().store('file'), // shared by the isolates
);

class McpRouter extends Router {
  @override
  void register() {
    oauth.routes(); // discovery, register, token
    Route.match(<String>['GET', 'POST', 'DELETE'], '/mcp', handleMcp);
  }
}

Future<DoxResponse> handleMcp(DoxRequest req) async {
  Object? user = await oauth.authenticate(req); // Authorization: Bearer
  if (user == null) return oauth.unauthorized(); // 401 + WWW-Authenticate
  return mcp.handle(req, auth: user, scope: '$user');
}
```

| Route | What it does |
| --- | --- |
| `GET /.well-known/oauth-protected-resource` (also with `/mcp` after it) | Names the MCP address and the issuer (RFC 9728). |
| `GET /.well-known/oauth-authorization-server` | The endpoints (RFC 8414). PKCE `S256` only, `authorization_code` only, no client secret. |
| `POST /oauth/register` | Dynamic client registration (RFC 7591). Nothing is stored: the `client_id` is the name and redirect addresses, signed with `APP_KEY` (label `dox:mcp-oauth`). |
| `POST /oauth/token` | Swaps a code for a token. Form or JSON body. The code works once and for `codeTtl` (1 minute). The client, the redirect address and the PKCE verifier must match. Answers `no-store`. An unknown `client_id` gets `401` with `invalid_client`. |

Rules:

- A redirect address must be `https`, or `http` on `localhost`, `127.0.0.1` or `[::1]`. No `#fragment`. At most 2048 characters (`McpOAuth.maxRedirectUriLength`).
- A `code_verifier` must be 43 to 128 characters of `A-Z a-z 0-9 - . _ ~` (RFC 7636). Other verifiers get `invalid_request`. A `code_challenge` must be 43 base64url characters.
- The codes live in `codes`, a Dox cache. Use a store that all isolates share (file on one host, Redis on many). Each code is taken under a lock, so two isolates cannot both swap it.
- The public routes answer any origin (CORS `*`) and read no cookie. They skip the app's CORS list.
- `issue` may throw `McpOAuthException` (like `access_denied` for too many clients). The client gets it from the token endpoint.
- There is no refresh token. The app revokes a client by deleting its token.

## Security

- Check who calls before `handle`: the MCP route has no auth of its own. `McpOAuth` is one way.
- `allowedOrigins` stops browser pages on other sites (DNS rebinding). Set it when the server runs on a local or private network.
- Keep tokens out of logs. A token in the URL ends up in proxy logs, so prefer a header when your clients can send one.
