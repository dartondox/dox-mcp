import 'dart:io';

import 'package:dox_annotation/command.dart';
import 'package:dox_annotation/install.dart';

/// `dox mcp:install`. `dox add mcp` runs it. It sets up an MCP server in
/// an app: the `McpServer` in `lib/config/mcp.dart` and one sample tool.
/// It does not add a route, because you must check who calls first. It
/// never overwrites a file, so it is safe to run twice.
class McpInstallCommand extends Command {
  /// [root] is the app folder (the current folder by default). [runner]
  /// runs `dart`, tests pass a fake one.
  McpInstallCommand({this.root, this.runner});

  final Directory? root;
  final ProcessRunner? runner;

  @override
  String get name => 'mcp:install';

  @override
  String get description => 'Set up an MCP server in this app';

  @override
  String get usage => 'mcp:install';

  @override
  Future<void> run(List<String> args) async {
    if (args.isNotEmpty) {
      print('Unknown option. mcp:install has no options.');
      exitCode = 1;
      return;
    }
    Installer installer = Installer(root: root, runner: runner);
    String app = installer.appName;

    await installer.addDependency('dox_mcp');

    installer.writeFile('lib/app/mcp/echo.tool.dart', echoTool);
    installer.writeFile('lib/config/mcp.dart', config(app));

    installer.printSummary(<String>[
      'Check that APP_KEY is set in .env (`dox key:generate`). MCP sessions '
          'are signed with it.',
      'Mount `mcp` on a route behind your own auth. Find the user first, '
          r"then call `mcp.handle(req, auth: user, scope: 'user:${user.id}')`. "
          'See the MCP docs.',
      'Write your own tools and add them to `tools` in lib/config/mcp.dart.',
    ]);
  }

  /// `lib/app/mcp/echo.tool.dart`, a small sample tool
  static const String echoTool = '''
import 'package:dox_core/dox_core.dart';
import 'package:dox_mcp/dox_mcp.dart';

/// Says the text back. Replace it with your own tool.
class EchoTool extends McpTool {
  @override
  String get name => 'echo';

  @override
  String get description => 'Say the text back.';

  @override
  ObjectSchema get input => v.object(<String, Schema<Object?>>{
    'text': v.string(),
  });

  @override
  Future<McpToolResult> call(
    Map<String, dynamic> args,
    McpContext context,
  ) async {
    return McpToolResult.text(args['text'] as String);
  }
}
''';

  /// `lib/config/mcp.dart`, the server of the docs
  static String config(String app) {
    return '''
import 'package:dox_mcp/dox_mcp.dart';
import 'package:$app/app/mcp/echo.tool.dart';

final McpServer mcp = McpServer(
  name: '$app',
  version: '1.0.0',
  tools: <McpTool>[EchoTool()],
);
''';
  }
}
