import 'dart:async';

import 'package:db_shelf/db.dart';
import 'package:shelf_plus/shelf_plus.dart';
import 'package:test/test.dart';
import 'package:postgres/postgres.dart' as pg;

import 'test_helper.dart';

void main() {
  late TestServer server;
  late pg.Pool dbTest;

  setUpAll(() async {
    dbTest = getPostgresPool(getEndpoint(), appName: 'tests_conn');
  });

  tearDownAll(() async {
    await dbTest.close();
  });

  test('working server', () async {
    server = await runTestServer();
    final response = await server.get('/now');
    expect(response.body, startsWith('Now:'));
  });

  Future<T> dbRun<T>(pg.Pool db, Future<T> Function(pg.Session) fn,
      {required bool useTx}) async {
    if (useTx) {
      return db.runTx<T>((s) => fn(s));
    } else {
      return db.run<T>((s) => fn(s));
    }
  }
  
  // Test connection close with both db.run and db.runTx
  for (final useTx in [false, true]) {
    final groupName = useTx ? 'db.runTx' : 'db.run';

    group('$groupName - ', () {
      test('ending the request should close dangling connections', () async {
        server = await runTestServer(
          extraRoutes: (app, db) {
            app.get(
              "/dangling-conn",
              (Request request) async {
                final appNameCompleter = Completer<String>();
                unawaited(
                  dbRun(
                    useTx: useTx,
                    db,
                    (s) async {
                      final applicationName =
                          await _getCurrentPostgresApplicationName(s);
                      appNameCompleter.complete(applicationName);

                      // Let the connection dangling
                      await Future<void>.delayed(
                          const Duration(milliseconds: 3000));
                    },
                  ),
                );

                final appName = await appNameCompleter.future;
                return appName;
              },
            );
          },
        );

        final response = await server.get('/dangling-conn');
        expect(response.statusCode, 200);

        final pgAppName = response.body;
        expect(pgAppName, startsWith('test_server'));

        final isActive = await isPgApplicationActive(dbTest, pgAppName);
        expect(isActive, isFalse,
            reason: "Dangling request db connection should be closed");
      });

      test('unexpected error should abort running connections in the request',
          () async {
        server = await runTestServer(
          extraRoutes: (app, db) {
            // Set the application name to the query parameter and throws an error
            // while the connection is open
            app.get(
              "/dangling-conn-err",
              (Request request) async {
                final appName = request.url.queryParameters["appname"]!;

                await Future.wait(
                  [
                    dbRun(
                      useTx: useTx,
                      db,
                      (s) async {
                        await s.execute("SET application_name TO $appName");
                        await Future<void>.delayed(
                            const Duration(milliseconds: 3000));
                      },
                    ),

                    // Throw an error while the connection is open
                    () async {
                      await Future<void>.delayed(
                          const Duration(milliseconds: 300));
                      throw Exception("My unexpected error");
                    }(),
                  ],
                  // Don't wait for the database connection to finish
                  eagerError: true,
                );

                return "ok";
              },
            );
          },
        );

        const pgAppName = "unexpectederrtest";
        // This request will fail, but the running db connection should be closed
        // The request sets the application name to "unexpectederrtest"
        final response =
            await server.get('/dangling-conn-err?appname=$pgAppName');
        // Our top level error handler will catch this error and return a 500
        expect(response.statusCode, 500);

        final isActive = await isPgApplicationActive(dbTest, pgAppName);
        expect(isActive, isFalse,
            reason: "Dangling request db connection should be closed");
      });

      test('don\'t close connection in non-dangling http requests', () async {
        server = await runTestServer(
          extraRoutes: (app, db) {
            app.get(
              "/no-dangling",
              (Request request) async {
                final appName = await dbRun(
                  useTx: useTx,
                  db,
                  (s) async {
                    final applicationName =
                        await _getCurrentPostgresApplicationName(s);
                    return applicationName;
                  },
                );

                return appName;
              },
            );
          },
        );

        final response = await server.get('/no-dangling');
        expect(response.statusCode, 200);

        final pgAppName = response.body;
        expect(pgAppName, startsWith('test_server'));

        final isActive = await isPgApplicationActive(dbTest, pgAppName);
        expect(isActive, true, reason: "The db connection should be open");
      });
    });
  }
}

Future<String> _getCurrentPostgresApplicationName(pg.Session session) async {
  final result =
      await session.execute("select current_setting('application_name');");
  return result.first.first! as String;
}

Future<bool> isPgApplicationActive(pg.Pool db, String pgAppName) async {
  final result = await db.execute(
    r"SELECT 1 FROM pg_stat_activity WHERE application_name = $1",
    parameters: [pgAppName],
  );
  return result.isNotEmpty;
}

Future<List<String>> getDbConnectionNames(pg.Pool db) async {
  final result = await db.execute(
    r"SELECT application_name FROM pg_stat_activity",
    parameters: [],
  );
  return result.map((r) => r[0] as String).toList();
}
