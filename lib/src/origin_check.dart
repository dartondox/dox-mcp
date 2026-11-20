import 'dart:io';

/// True after the open-origin warning was written in this isolate.
bool originWarningDone = false;

/// Writes once that `McpServer(allowedOrigins:)` is not set. Then any
/// website can call the server from a browser (DNS rebinding), even a
/// local one.
void warnOpenOriginOnce() {
  if (originWarningDone) return;
  originWarningDone = true;
  stderr.writeln(
    '[mcp] warning: McpServer(allowedOrigins:) is not set. Any website '
    'can call this server from a browser, also when it runs on localhost. '
    "Set allowedOrigins to your own sites, eg. ['https://app.example.com'].",
  );
}
