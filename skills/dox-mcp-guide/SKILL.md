---
name: dox-mcp-guide
description: Use when you add an MCP (Model Context Protocol) server to a Dox (Dart) app with dox_mcp. Covers writing tools (McpTool, DTO tools), serving them on a route with auth and scope, asking the user during a tool, and OAuth sign-in for MCP clients like Claude.
---

# dox_mcp guide

`dox_mcp` serves an MCP server from a normal Dox route. MCP clients (Claude, ChatGPT, IDE agents) call your tools. This package serves tools only. It has no MCP resources or prompts.

- It follows the MCP standard `2026-07-28`. Each request stands alone and gets a plain JSON reply. There are no sessions and nothing is stored.
- Tool arguments are `dox_validation` schemas. Clients see JSON Schema. Every call is checked before your code runs.

For routes, controllers and app layout, see the `dox-core-guide` skill. For DTO and validation rules, see the `dox-validation-guide` skill.

## Install

Fast way: `dox add mcp`. It adds the package and runs `dox mcp:install`, which writes `lib/config/mcp.dart` (the `McpServer`) and a sample `EchoTool` in `lib/app/mcp/echo.tool.dart`. It never overwrites a file. It adds no route: mount `mcp` on a route behind your own auth.

```bash
dart pub add dox_mcp
```

There is no provider. You make one `McpServer` (in `lib/config/mcp.dart`) and mount it on a route. `APP_KEY` must be set in `.env` (the server signs data with it).

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

`McpTool` members: `name` (unique), `description`, optional `title` and `annotations`, `input` (default: no arguments), `call`. `McpContext` has `request`, `auth`, `authAs<T>()`, `clientCapabilities`, `clientInfo` and `answer(input)` (see recipe 6).

Results: `McpToolResult.text(String)`, `.error(String)`, `.json(Object?)` (also sets structured content for a map). For images, `McpToolResult(<McpContent>[McpContent.text('...'), McpContent.image(base64, 'image/png')])`.

Errors: return `McpToolResult.error('...')` when the model can fix the call (like a bad id). The model sees the text. A tool that throws gives the client only `Tool failed` (the real text shows only when `APP_ENV` is `development` or `local`). `onToolError` on the server gets the real error, for logs.

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

Find the user first, then pass it as `auth`. `scope` names the user, like the user id.

```dart
final McpServer mcp = McpServer(
  name: 'my-app',
  version: '1.0.0',
  tools: <McpTool>[AddExpense(), CreateCategory()],
  allowedOrigins: <String>['https://my.app'],
  onToolError: (String tool, Object error, StackTrace stack) {
    Logger.danger('MCP tool $tool failed: $error');
  },
);

Route.match(<String>['GET', 'POST', 'DELETE'], '/mcp', (DoxRequest req) async {
  User? user = await findUser(req.header('authorization'));
  if (user == null) return response('Invalid token').statusCode(401);
  return mcp.handle(req, auth: user, scope: 'user:${user.id}');
});
```

`McpServer` options: `name`, `version`, `tools` (required), `title`, `instructions`, `allowedOrigins`, `onToolError(tool, error, stack)`, `requestStateTtl` (default 5 minutes), `requestStateKey` (default: from `APP_KEY`).

### 5. Read the client

Every request says what the client can do, and which client it is.

```dart
McpClientCapabilities? client = context.clientCapabilities;
if (client != null && client.elicitationForm) {
  // the client can show a form
}
String name = context.clientInfo?.name ?? 'unknown';
```

`McpClientCapabilities` has `elicitation`, `elicitationForm`, `elicitationUrl`, `sampling`, `roots`, `extensions` and `has(<String>['sampling', 'tools'])`. `McpClientInfo` has `name`, `version`, `title`, `description`, `websiteUrl`. `clientInfo` is null when the client did not send it. The client says it about itself, so never use it for security.

### 6. Ask the user during a tool

A tool can stop and ask a question. The client shows it and calls the tool again with the answer. The same `static final` input asks and reads. Works in `McpTool.call` and `McpDtoTool.handle`.

```dart
static final McpInput<bool> confirmDelete = McpInput.confirm(
  'Delete this expense?',
);

McpAnswer<bool>? answer = context.answer(confirmDelete);
if (answer == null) {
  return McpToolResult.inputRequired(<McpInput<Object?>>[confirmDelete]);
}
return switch (answer) {
  McpAccepted<bool>(value: true) => _delete(args),
  McpAccepted<bool>() ||
  McpDeclined<bool>() ||
  McpCancelled<bool>() => McpToolResult.text('Cancelled'),
};
```

Inputs: `McpInput.confirm(message)` (`bool`), `.text(message)` (`String`), `.number(message)` (`num`), `.choice(message, Color.values)` (the enum value), `.form(message, NewExpense.schema)` (the DTO object), `.url(message, url)` (`void`).

Answers: `McpAccepted<T>` (with `value`), `McpDeclined<T>`, `McpCancelled<T>`. `McpAnswer` is sealed, so a `switch` must handle all three. Always write the type argument, like `McpDeclined<bool>()`.

`context.answer` is null when there is no answer yet, or when the answer can not be read (a wrong type, or a form that fails the DTO rules). Then ask again.

To ask many things at once, pass a longer list to `inputRequired`. A tool can also ask one question per round: answers of earlier rounds are kept.

For a kind of input this package does not have, extend `McpCustomInput<T>`: `method`, `capability` (a path like `<String>['roots']`), `toJson()` (the request params) and `parse(result)`. It is the only place with a raw map.

### 7. OAuth sign-in for MCP clients

`McpOAuth` lets a client sign in by itself. You give the client only the address (like `https://my.app/mcp`). It does OAuth 2.1 with PKCE (no client secret, no refresh token). Your app does three things:

1. Implement `McpOAuthTokens`: `Future<String> issue(McpOAuthGrant grant)` makes a token (keep only a hash of it), `Future<Object?> verify(String token)` returns what it stands for (like a user), or null. `grant` has `subject`, `client` and `redirectUri`. `issue` may throw `McpOAuthException` (for example `access_denied`).
2. Serve a consent page at `<issuer>/oauth/authorize` (or pass `authorizePage`). It reads `client_id`, `redirect_uri`, `state`, `code_challenge`, `code_challenge_method` and `resource` from the query. The person signs in the way your app always does. `await oauth.verifyClient(clientId, redirectUri)` gives the client (`id`, `name`, `host`, `redirectUris`) for the page and throws when it is wrong. Show `client.host` next to the name: the client chooses its name, not its host.
3. Make a route of your own, behind your login, that answers the page. On yes, call `await oauth.approve(subject:, clientId:, redirectUri:, codeChallenge:, codeChallengeMethod:, state:, resource:)`. On no, call `await oauth.denyClient(clientId:, redirectUri:, state:)`. Both return the address to send the browser to.

```dart
final McpOAuth oauth = McpOAuth(
  issuer: 'https://my.app',
  tokens: McpTokens(),
  codes: Cache().store('redis'), // all isolates must share it
);

class McpRouter extends Router {
  @override
  void register() {
    oauth.routes();
    Route.match(<String>['GET', 'POST', 'DELETE'], '/mcp', handleMcp);
  }
}

Future<DoxResponse> handleMcp(DoxRequest req) async {
  User? user = await oauth.authenticate(req) as User?; // Authorization: Bearer
  if (user == null) return oauth.unauthorized(); // 401 with WWW-Authenticate
  return mcp.handle(req, auth: user, scope: 'user:${user.id}');
}
```

A client names itself with a client metadata document: its `client_id` is an `https` address of a JSON file with its name and redirect addresses. `dox_mcp` loads the file (small files, public hosts only, no redirects) and checks it. The app registers and stores nothing. Two options limit the loads:

- `allowedClientHosts: <String>{'claude.ai'}`: load client documents from these hosts only. The default (`null`) accepts any public host. It does not block clients that register at `POST /oauth/register`.
- `maxClientFetches` (default 8): how many documents one isolate loads at the same time. Past it, a new client is refused at once.
- `maxClientFetchesPerHost` (default 2) and `McpOAuthHttpFetcher(maxFetchesPerAddress:)` (default 2): one slow host or IP can not take all the slots.

Tests pass `clientFetcher:` (an `McpOAuthClientFetcher`) to give fake documents without the network.

## Gotchas

- The MCP route has no auth of its own. Check who calls before `handle`, and pass `auth` and `scope`.
- Apps with users MUST pass `scope` to `handle` (like the user id). The signed answers of a question are bound to it. Without it, one user can send the answers of another user.
- Mount the route with `GET`, `POST` and `DELETE`. New clients only use `POST`. Older clients (MCP `2025-11-25` and before) use the others, and they work on the same route with no app change.
- A token in the URL ends up in proxy logs. Prefer the `Authorization` header.
- Set `allowedOrigins` to your own sites. A request with another `Origin` gets `403`. A request with no `Origin` is always allowed. When it is not set, the server writes a warning once.
- Two tools with the same `name` throw an `ArgumentError` when you make the `McpServer`.
- A tool that asks the user runs two times (or more). Do the risky work only after the answer.
- The answers of a question are signed, and work only for the same `scope`, tool and arguments, for `requestStateTtl` (5 minutes). They can be sent again until they expire, so a tool that must run once (like a payment) checks that itself.
- `McpInput.form` throws an `ArgumentError` for a DTO with a nested object or list (lists of enum values are fine), and for a DTO with async rules like `@Unique`. Check those in the tool.
- Never ask for a password or a key with a form. Use `McpInput.url`. `McpAccepted` for a URL only means the user agreed to open it, so check the result in the database. Never put a secret in the URL.
- Two inputs with the same question in one `inputRequired` list throw an `ArgumentError`. An empty list throws too.
- A question the client can not show gets an error that names the missing capability. Check `context.clientCapabilities` first if the tool can work without the question.
- Call `oauth.routes()` in a router with no prefix. Clients look for `/.well-known/...` at the root.
- The `codes` cache must be shared by all isolates (file on one host, Redis on many). The memory store breaks on many isolates.
- Put the route that calls `oauth.approve` behind your login and CSRF protection, or another site can make a signed-in person say yes.
- On the consent page, show the host of `client_id` and of `redirect_uri`, and HTML-escape the client name. The client chooses the name.
- Use the async `verifyClient` and `denyClient`, not `checkClient` and `deny`. The sync ones can not wait for a metadata document, so they throw `invalid_client` until it is in memory.
- A redirect address must be `https`, or `http` on `localhost`, `127.0.0.1` or `[::1]`, with no `#fragment`. For a client with a metadata document, the port of an `http` address on the same computer may differ.
- To revoke an OAuth client, delete its token. There is no refresh token.
