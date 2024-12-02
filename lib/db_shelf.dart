import 'dart:async';

import 'package:db_shelf/abort_signal.dart';
import 'package:db_shelf/db.dart';
import 'package:shelf_plus/shelf_plus.dart';
import 'package:postgres/postgres.dart' as pg;

Future<void> main() async {
  final appRes = await setupAppWithDb();

  await runZonedGuarded(() {
    return shelfRun(
      () => appRes.handler,
      defaultEnableHotReload: false,
    );
  }, (e, st) {
    if (e is HttpRequestFinished) return;

    throw Error.throwWithStackTrace(e, st);
  });
}

Future<({Handler handler, pg.Pool db})> setupAppWithDb({
  String? appName,
  void Function(RouterPlus router, pg.Pool db)? extraRoutes,
}) async {
  final dbPool = getPostgresPool(
    getEndpoint(),
    appName: appName,
    abortSignalAware: true,
  );

  final handler = _initRouter(dbPool, extraRoutes: extraRoutes);
  return (handler: handler, db: dbPool);
}

Handler _initRouter(
  pg.Pool pool, {
  void Function(RouterPlus router, pg.Pool db)? extraRoutes,
}) {
  var app = Router().plus;

  app.get('/now', () => Response.ok('Now: ${DateTime.now()}'));

  app.get('/error', () {
    throw Exception('Error');
  });

  if (extraRoutes != null) {
    extraRoutes(app, pool);
  }

  return const Pipeline() //
      // Adds a signal object to trigger errors during the pipeline
      // and be able to cancel non-tied futures like database queries in the pool
      .addMiddleware(abortSignalMiddleware()) //
      .addMiddleware(unexpectedErrorsMiddleware()) //
      .addHandler(app.call);
}

Middleware unexpectedErrorsMiddleware() {
  return (innerHandler) {
    return (request) async {
      try {
        return await innerHandler(request);
      } catch (e, st) {
        return Response.internalServerError(
          body: 'Unexpected error: $e\n$st',
        );
      }
    };
  };
}
