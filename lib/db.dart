import 'package:db_shelf/abort_signal.dart';
import 'package:postgres/postgres.dart' as pg;

pg.Endpoint getEndpoint() {
  return pg.Endpoint(
    host: '127.0.0.1',
    database: 'postgres',
    port: 5434,
    username: 'postgres',
    password: 'changeme',
  );
}

pg.Pool<dynamic> getPostgresPool(
  pg.Endpoint endpoint, {
  String? appName,
  bool abortSignalAware = false,
}) {
  final poolSettings = pg.PoolSettings(
    maxConnectionCount: 4,
    applicationName: appName ?? "dart_http_server",
    sslMode: pg.SslMode.disable,
  );

  if (abortSignalAware) {
    return AbortSignalAwarePool.withEndpoints(
      [endpoint],
      settings: poolSettings,
    );
  } else {
    return pg.Pool.withEndpoints(
      [endpoint],
      settings: poolSettings,
    );
  }
}
