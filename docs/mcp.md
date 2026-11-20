---
icon: lucide/bot
---

# MCP

`dox_mcp` lets AI clients like Claude, ChatGPT and IDE agents call tools in your app, with the [Model Context Protocol](https://modelcontextprotocol.io) (MCP).

A tool is an action the AI can call, like "add an expense". You write the tool in Dart and serve it from a normal Dox route.

The server follows the MCP standard `2026-07-28`. Each request stands alone and gets a plain JSON reply. There are no sessions and nothing is stored, so every isolate and every server can answer any request.

## Setup

Run:

```bash
dox add mcp
```

It adds the package and runs `dox mcp:install`. That command writes `lib/config/mcp.dart` with an `McpServer`, and a sample tool in `lib/app/mcp/echo.tool.dart`. It never overwrites a file, so it is safe to run twice.

To set it up by hand, add the package and write those two files yourself:

```bash
dart pub add dox_mcp
```

`APP_KEY` must be set in `.env`. The server signs data with it.

## Making a tool

A tool extends `McpTool`. It has a `name`, a `description` for the model, an `input` schema and a `call` method that does the work:

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
    // ... save it
    return McpToolResult.text('Recorded ${args['amount']}.');
  }
}
```

The `input` is a [validation](https://dartondox.dev/latest/packages/validation/) schema. The client sees it as JSON Schema, and every call is checked before `call` runs. Use `describe` to explain a field to the model.

### Small tools

A small tool can be a function. Use `McpTool.of`:

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

### Tools that take a DTO

If you already have a [`@Dto`](https://dartondox.dev/latest/the-basic/dto/) class, a tool can use it as its input. Extend `McpDtoTool<T>`. You write the rules once, and `handle` gets the typed object, not a map:

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

`@Describe` explains a field to the model. The arguments are checked like a DTO in a controller, also with async rules like `@Unique` and `@Exists`.

## Tool results

A tool returns an `McpToolResult`. Pick the one that fits.

### Text

`McpToolResult.text` sends one text:

```dart
return McpToolResult.text('Recorded 12.50.');
```

### JSON

`McpToolResult.json` sends a value as JSON text. A map is also sent as structured content, for clients that read it:

```dart
return McpToolResult.json(<String, dynamic>{'id': 7, 'amount': 12.5});
```

### Images

For other content, pass a list of `McpContent` items:

```dart
return McpToolResult(<McpContent>[
  McpContent.text('The chart of this month:'),
  McpContent.image(base64Png, 'image/png'),
]);
```

## Errors

There are two kinds of errors. One is for the model, and one is for you.

### Errors the model can fix

Return `McpToolResult.error` when the model can try again, like after a bad id. The model sees the text:

```dart
return McpToolResult.error('No expense has id 7.');
```

Bad arguments work the same way, and you write no code for them. The model gets one line with each problem:

```text
Input validation error: Invalid arguments for tool create_category: name: The name is required; color: The color must be a hex color like #1a2b3c
```

### Errors in your code

If a tool throws, the client only gets `Tool failed`. The real error can hold things like SQL or host names, so it is shown only when `APP_ENV` is `development` or `local`.

Set `onToolError` on the server to log the real error:

```dart
McpServer(
  name: 'my-app',
  version: '1.0.0',
  tools: <McpTool>[AddExpense()],
  onToolError: (String tool, Object error, StackTrace stack) {
    Logger.danger('MCP tool $tool failed: $error');
  },
);
```

## Adding the route

Make one `McpServer` with your tools:

```dart
final McpServer mcp = McpServer(
  name: 'my-app',
  version: '1.0.0',
  tools: <McpTool>[AddExpense(), CreateCategory()],
);
```

Then call `handle` from a route:

```dart
Route.match(<String>['GET', 'POST', 'DELETE'], '/mcp', (DoxRequest req) {
  return mcp.handle(req);
});
```

This route is open to everyone. That is fine for a public server with no users. Every other app must check who calls first.

### Checking who calls

The MCP route has no auth of its own. Find the user before `handle`, then pass two things:

- `auth`: the user. A tool reads it with `context.authAs<User>()`.
- `scope`: a text that names the user, like the user id.

```dart
Route.match(<String>['GET', 'POST', 'DELETE'], '/mcp', (DoxRequest req) async {
  User? user = await findUser(req.header('authorization'));
  if (user == null) return response('Invalid token').statusCode(401);
  return mcp.handle(req, auth: user, scope: 'user:${user.id}');
});
```

An app with users must always pass `scope`. The server binds the data it signs to the scope. Without it, one user can send data that was signed for another user.

In a tool, read the user back:

```dart
User user = context.authAs<User>();
```

To let clients sign in by themselves, use [OAuth](#signing-in-with-oauth).

## Reading the client

Sometimes a tool wants to know what the client can do, or which client it is. Every request carries this, and the tool reads it from the `context`.

### What the client can do

`context.clientCapabilities` says what the client supports:

```dart
McpClientCapabilities? client = context.clientCapabilities;
if (client != null && client.elicitationForm) {
  // the client can show a form to the user
}
```

It has `elicitation`, `elicitationForm`, `elicitationUrl`, `sampling`, `roots` and `extensions`. For anything else, `has` checks a path, like `client.has(<String>['sampling', 'tools'])`.

### Which client it is

`context.clientInfo` gives the name and version of the client. It is `null` when the client did not send it:

```dart
String name = context.clientInfo?.name ?? 'unknown';
```

The client says this about itself, so never use it for security.

## Asking the user

A tool can stop and ask the user a question, like "Delete this expense?". The client shows the question, then calls the tool again with the answer. Use it before a risky action, or when the tool needs one more value.

Make the question once, in a `static final` field. The same object asks the question and reads the answer:

```dart
class DeleteExpense extends McpTool {
  static final McpInput<bool> confirmDelete = McpInput.confirm(
    'Delete this expense?',
  );

  // name, description, input ...

  @override
  Future<McpToolResult> call(
    Map<String, dynamic> args,
    McpContext context,
  ) async {
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
  }
}
```

The tool runs two times. The first time there is no answer, so it asks. The second time `context.answer` gives the answer. It works the same in `McpDtoTool.handle`.

The server keeps nothing between the two calls. The answers are signed, they only work for the same user, tool and arguments, and they expire after 5 minutes. Change the time with `requestStateTtl` on the `McpServer`.

### Reading the answer

`context.answer` gives `null` when there is no answer yet. Then return `McpToolResult.inputRequired`. Else the answer is one of three classes, and a `switch` makes you handle all of them:

- `McpAccepted<T>`: the user answered. `value` holds the answer.
- `McpDeclined<T>`: the user said no.
- `McpCancelled<T>`: the user closed the question.

### Yes or no

`McpInput.confirm` asks a yes or no question. The answer is a `bool`:

```dart
static final McpInput<bool> confirmDelete = McpInput.confirm(
  'Delete this expense?',
);
```

### Text

`McpInput.text` asks for one line of text. The answer is a `String`:

```dart
static final McpInput<String> askNote = McpInput.text('Add a note:');
```

### Number

`McpInput.number` asks for a number. The answer is a `num`:

```dart
static final McpInput<num> askAmount = McpInput.number('How much was it?');
```

### Choice

`McpInput.choice` lets the user pick one value of an enum. The answer is the enum value:

```dart
enum Color { red, green, blue }

static final McpInput<Color> askColor = McpInput.choice(
  'Pick a color:',
  Color.values,
);
```

### Form

`McpInput.form` asks for many fields at once, from a `@Dto` class. The answer is the DTO object, checked by its rules:

```dart
static final McpInput<NewExpense> askExpense = McpInput.form(
  'New expense',
  NewExpense.schema,
);
```

A form only has flat fields: text, numbers, booleans, enums and lists of enum values. So the DTO can not have a nested object, and it can not have async rules like `@Unique`. Check those in the tool.

Never ask for a password or a key in a form. Use a URL for that.

### URL

`McpInput.url` sends the user to a page, like a sign-in to another service. Use it for things that must not pass through the client:

```dart
static final McpInput<void> connectBank = McpInput.url(
  'Connect your bank account.',
  'https://my.app/bank/connect',
);
```

`McpAccepted` only means the user agreed to open the page. It does not mean they finished it, so check that in your database. Never put a secret in the URL.

### Many questions

To ask many things at once, pass a longer list. Read each answer with its own input:

```dart
McpAnswer<String>? note = context.answer(askNote);
McpAnswer<num>? amount = context.answer(askAmount);
if (note == null || amount == null) {
  return McpToolResult.inputRequired(<McpInput<Object?>>[askNote, askAmount]);
}
```

A tool can also ask one question per round. Answers of earlier rounds are kept.

### Custom inputs

MCP may get new kinds of input that `dox_mcp` does not have yet. For these, extend `McpCustomInput<T>`. Give the `method`, the `capability` the client needs, the request as `toJson`, and `parse` to read the result:

```dart
class ListRoots extends McpCustomInput<List<String>> {
  @override
  String get method => 'roots/list';

  @override
  List<String> get capability => <String>['roots'];

  @override
  Map<String, Object?> toJson() {
    return <String, Object?>{};
  }

  @override
  List<String> parse(Map<String, Object?> result) {
    return <String>[
      for (Object? root in result['roots']! as List<Object?>)
        (root! as Map<String, Object?>)['uri']! as String,
    ];
  }
}
```

Use it like any other input, with `context.answer` and `McpToolResult.inputRequired`.

## Signing in with OAuth

With `McpOAuth`, you give the client only the address, like `https://my.app/mcp`. The client finds the rest and signs the user in. This is the sign-in the MCP standard asks for: OAuth 2.1 with PKCE.

`dox_mcp` does the OAuth part. Your app makes the tokens and shows the consent page.

### Tokens

Implement `McpOAuthTokens`. `issue` makes a token after the user said yes. `verify` gives what a token stands for, like the user, or `null`. You choose the table. Keep only a hash of the token:

```dart
class McpTokens extends McpOAuthTokens {
  @override
  Future<String> issue(McpOAuthGrant grant) async {
    String token = newRandomToken(); // your own long random text
    // ... save Hash.sha256(token) for the user grant.subject
    return token;
  }

  @override
  Future<Object?> verify(String token) async {
    // ... find the user of this token, or return null
    return null;
  }
}
```

There is no refresh token. To revoke a client, delete its token.

### Routes

Make an `McpOAuth` and call `routes` in a router with no prefix. Then check the token on the MCP route:

```dart
final McpOAuth oauth = McpOAuth(
  issuer: 'https://my.app',
  tokens: McpTokens(),
  codes: Cache().store('redis'),
);

class McpRouter extends Router {
  @override
  void register() {
    oauth.routes();
    Route.match(<String>['GET', 'POST', 'DELETE'], '/mcp', handleMcp);
  }
}

Future<DoxResponse> handleMcp(DoxRequest req) async {
  Object? user = await oauth.authenticate(req);
  if (user == null) return oauth.unauthorized();
  return mcp.handle(req, auth: user, scope: '$user');
}
```

`authenticate` reads the `Authorization: Bearer` header and calls your `verify`. `unauthorized` answers `401` and tells the client where to sign in.

The `codes` option is a [cache store](https://dartondox.dev/latest/packages/cache/) for the one-time codes. All isolates must share it, so use `file` on one server, or `redis` on many.

### The consent page

The client sends the browser to `<issuer>/oauth/authorize`. This page is yours. The person signs in there the way your app always does, and then says yes or no. The page gets `client_id`, `redirect_uri`, `state`, `code_challenge` and `resource` in the query.

Use `verifyClient` to get the client for the page. It throws when the client or the redirect address is wrong:

```dart
McpOAuthClient client = await oauth.verifyClient(clientId, redirectUri);
// show client.name next to client.host, and the host of redirectUri
```

`client.host` is the host of the client's address, like `claude.ai`. It is `null` for an older client that registered. A client can choose any name, but not its host, so show both.

The older `checkClient` and `deny` still work. They are not async, so they can not wait for a client document. If the document is not in memory yet, they start to load it and throw `invalid_client`. A new try a moment later works. Use `verifyClient` and `denyClient` in new code.

On yes, call `approve`. It returns the address to send the browser to:

```dart
String url = await oauth.approve(
  subject: '${user.id}',
  clientId: clientId,
  redirectUri: redirectUri,
  codeChallenge: codeChallenge,
  state: state,
  resource: resource,
);
return redirect(url);
```

On no, call `denyClient`:

```dart
String url = await oauth.denyClient(
  clientId: clientId,
  redirectUri: redirectUri,
  state: state,
);
```

The consent page decides who gets access, so keep these rules:

- Put the yes route behind your login and [CSRF protection](https://dartondox.dev/latest/security/csrf/). Without it, another site can make a signed-in person say yes.
- Show the host of the `client_id` and of the redirect address. The client chooses its own name, so the host is the part a person can trust.
- HTML-escape the client name before you print it.

### How clients sign in

A client names itself with a client metadata document. Its `client_id` is an `https` address, like `https://claude.ai/oauth/mcp-oauth-client-metadata`. A JSON file at that address holds the name of the client and its redirect addresses. `dox_mcp` loads the file and checks it, so there is nothing to register and nothing to store.

The server only loads small files from public hosts, and it follows no redirects. It keeps a loaded document for its `Cache-Control: max-age`, at most `clientCacheMaxAge`. If the host of a client does not answer, the server uses the last document for up to 1 hour. If the host answers with an error or a changed document, the change applies at once. A failed load is not tried again for 1 minute.

These options limit the loads:

```dart
McpOAuth(
  issuer: 'https://my.app',
  tokens: McpTokens(),
  allowedClientHosts: <String>{'claude.ai'},
  maxClientFetches: 4,
);
```

- `allowedClientHosts`: accept clients from these hosts only. By default, any public host works.
- `maxClientFetches`: how many documents one isolate loads at the same time. The default is 8. When all are busy, a new client is refused at once.
- `maxClientFetchesPerHost`: how many of these loads can go to one host. The default is 2, so one slow host can not use all the slots.
- `McpOAuthHttpFetcher(maxFetchesPerAddress:)`: how many loads can go to one IP address. The default is 2.

## Checking the origin

A web page on another site can try to call your MCP server from the browser of a user. This matters most for a server on `localhost` or a private network. Set `allowedOrigins` to stop it:

```dart
McpServer(
  name: 'my-app',
  version: '1.0.0',
  tools: <McpTool>[AddExpense()],
  allowedOrigins: <String>['https://my.app'],
);
```

A request with another `Origin` header gets `403`. A request with no `Origin` is not from a browser, so it is always allowed.

When `allowedOrigins` is not set, the server writes a warning once at start.

## Details

This section is for special cases. Most apps do not need it.

### Server options

| Option | Default | What it does |
| --- | --- | --- |
| `name` | required | The name of the server, for the client. |
| `version` | required | The version of your server, for the client. |
| `tools` | required | The tools. Two tools with the same name throw an `ArgumentError`. |
| `title` | `null` | A name for people. |
| `instructions` | `null` | Text for the model about how to use the server. |
| `allowedOrigins` | `null` | See [Checking the origin](#checking-the-origin). |
| `onToolError` | `null` | See [Errors in your code](#errors-in-your-code). |
| `requestStateTtl` | 5 minutes | How long the answers of a question work. |
| `requestStateKey` | from `APP_KEY` | The key that signs the answers. |

### OAuth options

| Option | Default | What it does |
| --- | --- | --- |
| `issuer` | required | The address of your app, like `https://my.app`. |
| `tokens` | required | Your `McpOAuthTokens`. |
| `codes` | the default cache store | The cache store for the one-time codes. |
| `mcpPath` | `/mcp` | The path of the MCP route. |
| `authorizePage` | `<issuer>/oauth/authorize` | The address of the consent page. |
| `codeTtl` | 1 minute | How long a code works. |
| `resourceName` | `null` | A name for the server in the discovery file. |
| `allowedClientHosts` | `null` | See [How clients sign in](#how-clients-sign-in). |
| `maxClientFetches` | 8 | See [How clients sign in](#how-clients-sign-in). |
| `maxClientFetchesPerHost` | 2 | See [How clients sign in](#how-clients-sign-in). |
| `clientCacheMaxAge` | 5 minutes | The longest time a client document is kept in memory. |

### Other cases

- The server has tools only. It has no MCP resources, prompts or streams.
- Older clients (MCP `2025-11-25` and before) still work on the same route, with no change in your app. They are why the route takes `GET`, `POST` and `DELETE`: new clients only use `POST`. Older clients can not answer a question, and they can register at `POST /oauth/register`.
- A tool can have a `title` for people, and `annotations` like `{'readOnlyHint': true}`.
- The answers of a question can be sent again until they expire. A tool that must run only once, like a payment, must check that itself.
- `context.answer` also gives `null` for an answer the server can not read, like a wrong type or a form that fails the DTO rules. So the tool asks again.
- A question the client can not show gets an error that names the missing capability. Check `context.clientCapabilities` first if the tool can work without the question.
- Two inputs with the same question in one `inputRequired` list throw an `ArgumentError`. Give each one its own message.
- A redirect address must be `https`, or `http` on `localhost`, `127.0.0.1` or `[::1]`. For an `http` address on the same computer, the port may differ.
- `issue` may throw an `McpOAuthException`, like `access_denied` when a person has too many clients. The client gets it.
- The OAuth routes answer any origin and read no cookie. They skip the CORS list of the app.
- A batch of more than 50 messages (from an older client) gets `400` with `-32600`, and no message runs.
- In tests, pass `clientFetcher` to `McpOAuth` to give client documents without the network.
