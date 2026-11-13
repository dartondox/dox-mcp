import 'dart:io';

import 'package:dox_annotation/install.dart';
import 'package:dox_mcp/commands.dart';
import 'package:test/test.dart';

/// records the `dart` commands, runs nothing
class FakeRunner extends ProcessRunner {
  final List<String> calls = <String>[];

  @override
  Future<int> run(String executable, List<String> args, String folder) async {
    calls.add(args.join(' '));
    return 0;
  }
}

void main() {
  late Directory root;
  late FakeRunner runner;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dox_mcp_install_');
    File(
      '${root.path}/pubspec.yaml',
    ).writeAsStringSync('name: my_app\n\ndependencies:\n  dox_core: ^3.1.0\n');
    runner = FakeRunner();
    exitCode = 0;
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  String read(String path) => File('${root.path}/$path').readAsStringSync();

  Future<void> install(List<String> args) {
    return McpInstallCommand(root: root, runner: runner).run(args);
  }

  /// every file of the app and its text
  Map<String, String> snapshot() {
    Map<String, String> files = <String, String>{};
    for (FileSystemEntity f in root.listSync(recursive: true)) {
      if (f is File) files[f.path] = f.readAsStringSync();
    }
    return files;
  }

  test('sets up the server and a sample tool', () async {
    await install(<String>[]);
    expect(exitCode, 0);
    expect(runner.calls, <String>['pub add dox_mcp']);
    expect(
      read('lib/config/mcp.dart'),
      contains("import 'package:my_app/app/mcp/echo.tool.dart';"),
    );
    expect(read('lib/app/mcp/echo.tool.dart'), contains('class EchoTool'));
  });

  test('a second run changes nothing', () async {
    await install(<String>[]);
    File('${root.path}/lib/config/mcp.dart').writeAsStringSync('// mine {');
    Map<String, String> before = snapshot();
    await install(<String>[]);
    expect(exitCode, 0);
    expect(snapshot(), before);
  });

  test('any option stops with exit code 1 and writes nothing', () async {
    for (List<String> args in <List<String>>[
      <String>['--x'],
      <String>['x'],
      <String>['--x='],
    ]) {
      Map<String, String> before = snapshot();
      await install(args);
      expect(exitCode, 1, reason: '$args');
      expect(runner.calls, isEmpty, reason: '$args');
      expect(snapshot(), before, reason: '$args');
      exitCode = 0;
    }
  });
}
