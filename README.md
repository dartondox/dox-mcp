# dox_mcp

A [Model Context Protocol](https://modelcontextprotocol.io) (MCP) server for the [Dox](https://dartondox.dev) framework.

It lets AI clients like Claude, ChatGPT and IDE agents call tools in your app, from a normal Dox route.

- It follows the MCP standard `2026-07-28`. Each request stands alone and gets a plain JSON reply. There are no sessions and nothing is stored.
- Tool arguments are `dox_validation` schemas. Clients see them as JSON Schema, and every call is checked before your code runs.
- A tool can stop and ask the user a question.
- Clients can sign in by themselves with OAuth.

The full guide is on the docs site: [dartondox.dev/latest/packages/mcp](https://dartondox.dev/latest/packages/mcp/).

## Install

In a Dox app, run:

```bash
dox add mcp
```

It adds the package and runs `dox mcp:install`. That command writes `lib/config/mcp.dart` with an `McpServer`, and a sample tool. It never overwrites a file.

Or add only the package:

```bash
dart pub add dox_mcp
```

`APP_KEY` must be set in `.env`.

## Make a tool

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
  Future<McpToolResult> call(
    Map<String, dynamic> args,
    McpContext context,
  ) async {
    User user = context.authAs<User>();
    // ... save it
    return McpToolResult.text('Recorded ${args['amount']} for ${user.email}.');
  }
}
```

A small tool can be a function, with `McpTool.of`. A tool can also take a `@Dto` class as its input, with `McpDtoTool<T>`.

Return `McpToolResult.error('...')` for an error the model can fix. If a tool throws, the client only gets `Tool failed`, and `onToolError` on the server gets the real error.

## Add the route

Find the user first, then pass it as `auth`. An app with users must also pass `scope`, like the user id:

```dart
final McpServer mcp = McpServer(
  name: 'my-app',
  version: '1.0.0',
  tools: <McpTool>[AddExpense()],
  allowedOrigins: <String>['https://my.app'],
);

Route.match(<String>['GET', 'POST', 'DELETE'], '/mcp', (DoxRequest req) async {
  User? user = await findUser(req.header('authorization'));
  if (user == null) return response('Invalid token').statusCode(401);
  return mcp.handle(req, auth: user, scope: 'user:${user.id}');
});
```

`allowedOrigins` stops web pages on other sites from calling the server in a browser.

## Ask the user during a tool

A tool can ask a question, like "Delete this expense?". The client shows it, then calls the tool again with the answer:

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

| Input | Answer |
| --- | --- |
| `McpInput.confirm(message)` | `bool` |
| `McpInput.text(message)` | `String` |
| `McpInput.number(message)` | `num` |
| `McpInput.choice(message, Color.values)` | the enum value |
| `McpInput.form(message, NewExpense.schema)` | the `@Dto` object (flat fields only, no async rules) |
| `McpInput.url(message, url)` | nothing: the user agreed to open the page |

The answers are signed and expire after 5 minutes (`requestStateTtl`). For a kind of input that is not in the table, extend `McpCustomInput<T>`.

## OAuth sign-in

With `McpOAuth`, you give the client only the address, like `https://my.app/mcp`. The client signs the user in by itself. Your app makes the tokens (`McpOAuthTokens`) and shows the consent page.

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
  User? user = await oauth.authenticate(req) as User?;
  if (user == null) return oauth.unauthorized();
  return mcp.handle(req, auth: user, scope: 'user:${user.id}');
}
```

A client names itself with a client metadata document: its `client_id` is an `https` address of a JSON file. `dox_mcp` loads and checks the file. Options limit this: `allowedClientHosts` (load client documents from these hosts only; it does not block clients that register at `POST /oauth/register`), `maxClientFetches` (how many files one isolate loads at the same time) and `maxClientFetchesPerHost`. On the consent page, use `await oauth.verifyClient(...)` and show `client.host` next to the client name.

See the [full guide](https://dartondox.dev/latest/packages/mcp/#signing-in-with-oauth) for the tokens and the consent page.

## Details

- The server has tools only. It has no MCP resources, prompts or streams.
- Older clients (MCP `2025-11-25` and before) still work on the same route, with no change in your app.
