// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:io';

import 'package:db_shelf/abort_signal.dart';
import 'package:db_shelf/db_shelf.dart';
import 'package:http/http.dart' as http;
import 'package:postgres/postgres.dart' as pg;
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_plus/shelf_plus.dart';
import 'package:test/test.dart';
import 'package:test_api/src/backend/invoker.dart';

Future<TestServer> runTestServer({
  void Function(RouterPlus router, pg.Pool db)? extraRoutes,
}) async {
  final liveTest = Invoker.current!.liveTest;
  final String testName = liveTest.test.name;

  final appRes = await setupAppWithDb(
    extraRoutes: extraRoutes,
    appName: 'test_server_$testName',
  );
  addTearDown(() => appRes.db.close());

  final handler = appRes.handler.call;
  var server = TestServer(handler);
  addTearDown(() => server.stop());

  return runZonedGuarded(() async {
    await server.start();
    return server;
  }, (e, st) {
    if (e is HttpRequestFinished) return;

    throw Error.throwWithStackTrace(e, st);
  })!;
}

class TestServer {
  HttpServer? server;
  Handler handler;

  TestServer(this.handler);

  Future<void> start() async {
    server = await io.serve(handler, '127.0.0.1', 0);
  }

  Future<void> stop() async {
    await server?.close(force: true);
  }

  String get host {
    return 'http://127.0.0.1:${server?.port}';
  }

  Future<http.Response> get(String path) async {
    return await http.get(Uri.parse('$host$path'));
  }
}
