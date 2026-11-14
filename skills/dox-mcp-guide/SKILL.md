---
name: dox-mcp-guide
description: Use when you add an MCP (Model Context Protocol) server to a Dox (Dart) app with dox_mcp. Covers writing tools (McpTool, DTO tools), serving them on a route with auth, signed sessions, and OAuth sign-in routes for MCP clients like Claude.
---

# dox_mcp guide

`dox_mcp` serves an MCP server from a normal Dox route, over the Streamable HTTP transport. MCP clients (Claude, ChatGPT, IDE agents) call your tools. This package serves tools only. It has no MCP resources or prompts.

- Tool arguments are `dox_validation` schemas. Clients see JSON Schema. Every call is checked before your code runs.
- Session ids are signed with `APP_KEY`, so they work on every isolate and after a restart. No store is needed.
- Replies are plain JSON. No SSE stream.

For routes, controllers and app layout, see the `dox-core-guide` skill. For DTO and validation rules, see the `dox-validation-guide` skill.

## Install

Fast way: `dox add mcp`. It adds the package, `lib/config/mcp.dart` (the `McpServer`) and a sample `EchoTool`. It never overwrites a file. It adds no route: mount `mcp` on a route behind your own auth.

```bash
dart pub add dox_mcp
```

There is no provider and no config file. You make one `McpServer` and mount it on a route. `APP_KEY` must be set in `.env` (sessions are signed with it).

## Recipes

### 1. Write a tool

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

`McpTool` members: `name` (unique), `description`, optional `title`, `input` (default: no arguments), `call`. `McpContext` has `request`, `sessionId`, `protocolVersion`, `auth` and `authAs<T>()`.

Results: `McpToolResult.text(String)`, `.error(String)`, `.json(Object?)` (also sets structured content for a map). A result with `isError: true` tells the model the call failed.

### 2. A small tool as a function

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

### 3. A tool that takes a DTO

Extend `McpDtoTool<T>`. The DTO rules are written once. `handle` gets the typed object. `@Describe` explains a field to the model and goes into the JSON Schema. It does not change the checks.

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

`$NewCategoryDto` comes from the code generator: run `dart run build_runner build`. Bad arguments give a tool result with `isError: true` that lists each problem, so the model can fix the call. Async rules like `@Unique` and `@Exists` work too.

### 4. Serve the server on a route

Find the user first, then pass it as `auth`. `scope` ties each session to that user.

```dart
final McpServer mcp = McpServer(
  name: 'my-app',
  version: '1.0.0',
  tools: <McpTool>[AddExpense(), CreateCategory()],
);

Route.match(<String>['GET', 'POST', 'DELETE'], '/mcp/{token}', (DoxRequest req) async {
  User? user = await User().where('mcp_token', req.param['token']).getFirst();
  if (user == null) return response('Invalid token').statusCode(401);
  return mcp.handle(req, auth: user, scope: 'user:${user.id}');
});
```

`McpServer` options: `name`, `version`, `tools` (required), `title`, `instructions`, `sessions`, `allowedOrigins`, `onToolError(tool, error, stack)`. Mount all three methods (`GET`, `POST`, `DELETE`): the server answers `GET` with `405` and `DELETE` ends a session.

### 5. OAuth sign-in for MCP clients

`McpOAuth` lets a client sign in by itself. You give the client only the address (like `https://my.app/mcp`). It does OAuth 2.1 with PKCE (`S256`, `authorization_code`, no client secret, no refresh token). Your app does three things:

1. Implement `McpOAuthTokens`: `Future<String> issue(McpOAuthGrant grant)` makes a token (keep only a hash of it), `Future<Object?> verify(String token)` returns what it stands for (like a user), or null. `issue` may throw `McpOAuthException` (for example `access_denied`).
2. Serve a consent page at `<issuer>/oauth/authorize` (or pass `authorizePage`). It reads `client_id`, `redirect_uri`, `state`, `code_challenge`, `code_challenge_method` and `resource` from the query. The person signs in the way your app always does.
3. Make a route of your own, behind your login, that answers the page. On yes, call `await oauth.approve(subject:, clientId:, redirectUri:, codeChallenge:, state:, resource:)`. It returns the address to send the browser to. On no, call `oauth.deny(clientId:, redirectUri:, state:)`. `oauth.checkClient(clientId, redirectUri)` gives the client for the page and throws when it is wrong.

```dart
final McpOAuth oauth = McpOAuth(
  issuer: 'https://my.app',
  tokens: MyTokens(),
  codes: Cache().store('file'), // all isolates must share it
);

class McpRouter extends Router {
  @override
  void register() {
    oauth.routes(); // discovery, register and token
    Route.match(<String>['GET', 'POST', 'DELETE'], '/mcp', handleMcp);
  }
}

Future<DoxResponse> handleMcp(DoxRequest req) async {
  Object? user = await oauth.authenticate(req); // reads Authorization: Bearer
  if (user == null) return oauth.unauthorized(); // 401 with WWW-Authenticate
  return mcp.handle(req, auth: user, scope: '$user');
}
```

`oauth.routes()` adds `GET /.well-known/oauth-protected-resource` (and the same with `/mcp` after it), `GET /.well-known/oauth-authorization-server`, `POST /oauth/register` and `POST /oauth/token`.

### 6. Sessions

`SignedMcpSessions` is the default. It stores nothing. A new `APP_KEY` ends every session, and clients start a new one by themselves. A signed id can not be ended unless you give a shared cache store:

```dart
McpServer(
  name: 'my-app',
  version: '1.0.0',
  tools: tools,
  sessions: SignedMcpSessions(ended: Cache().store('redis')),
);
```

Use a store all isolates share (file or Redis, not memory). For another kind of session, implement `McpSessions`.

## Gotchas

- The MCP route has no auth of its own. Check who calls before `handle`, and pass `auth` and `scope`.
- A token in the URL (`/mcp/{token}`) ends up in proxy logs. Prefer a header when the client can send one.
- Set `allowedOrigins` when the server runs on a local or private network. A request with another `Origin` gets `403`.
- Two tools with the same `name` throw an `ArgumentError` when you make the `McpServer`.
- Call `oauth.routes()` in a router with no prefix. Clients look for `/.well-known/...` at the root, and the discovery file gives full addresses that do not move with a prefix.
- The `codes` cache must be shared by all isolates (file on one host, Redis on many). The default memory store breaks on many isolates.
- Put the route that calls `oauth.approve` behind CSRF protection, or another site can make a signed-in person say yes.
- On the consent page, show the host of `redirect_uri` and HTML-escape the client name. The client chooses the name.
- A redirect address must be `https`, or `http` on `localhost`, `127.0.0.1` or `[::1]`, with no `#fragment`.
- To revoke an OAuth client, delete its token. There is no refresh token.
- Supported methods: `initialize`, `ping`, `tools/list`, `tools/call`. Others get `-32601`. An unknown tool is JSON-RPC error `-32602`.
- A tool that throws becomes a tool result with `isError: true`. The client gets `Tool failed`, unless `APP_ENV` is `development` or `local`. A tool that wants the model to see a message must return `McpToolResult.error(...)`. `onToolError` gets the full error, for logs.
- `initialize` must be sent alone, not in a batch.
- Protocol versions: `2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05`.
