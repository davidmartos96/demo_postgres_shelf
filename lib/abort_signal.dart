import 'dart:async';

import 'package:postgres/postgres.dart' as pg;
// ignore: implementation_imports
import 'package:postgres/src/pool/pool_impl.dart' as pool_impl;
import 'package:shelf/shelf.dart';

const _abortSignalZoneKey = #AbortSignal;

class AbortSignal {
  final Completer<void> _errorCompleter = Completer<void>();

  bool get wasAborted => _errorCompleter.isCompleted;

  void signalError(Object error, [StackTrace? stackTrace]) {
    _errorCompleter.completeError(error, stackTrace);
  }

  // This is a helper function to wait for the provided future or throw if the abort signal is triggered and finishes earlier.
  Future<T> waitFuture<T>(Future<T> future) async {
    return (await Future.any<void>([
      future,
      _errorCompleter.future..ignore(),
    ])) as T;
  }
}

AbortSignal? getAbortSignalInZone() {
  return Zone.current[_abortSignalZoneKey] as AbortSignal?;
}

Middleware abortSignalMiddleware() {
  return (innerHandler) {
    return (request) async {
      final abortSignal = AbortSignal();

      return runZoned(
        () async {
          try {
            return await innerHandler(request);
          } finally {
            if (!abortSignal.wasAborted) {
              // Use the abort signal to signal the error in case someone is aware of it, like the database pool
              abortSignal.signalError(HttpRequestFinished());
            }
          }
        },
        zoneValues: {
          _abortSignalZoneKey: abortSignal,
        },
      );
    };
  };
}

class HttpRequestFinished implements Exception {
  @override
  String toString() => 'Request has finished';
}

/// A pool that aborts the connection if receives an abort signal.
/// This is useful to abort the db query if the request is aborted.
class AbortSignalAwarePool<T> extends pool_impl.PoolImplementation<T> {
  AbortSignalAwarePool(super.selector, super.settings);

  factory AbortSignalAwarePool.withEndpoints(
    List<pg.Endpoint> endpoints, {
    pg.PoolSettings? settings,
  }) =>
      AbortSignalAwarePool(pool_impl.roundRobinSelector(endpoints), settings);

  /// This method is the only one that is overridden to add the abort signal handling.
  /// and let the postgres library know about the error outside the connection callback
  /// so that it releases the connection.
  @override
  Future<R> withConnection<R>(
    Future<R> Function(pg.Connection connection) fn, {
    pg.ConnectionSettings? settings,
    locality,
  }) {
    final AbortSignal? abortSignal = getAbortSignalInZone();

    // print("Abort signal: $abortSignal");

    final Future<R> Function(pg.Connection connection) effectiveFn;
    if (abortSignal == null) {
      effectiveFn = fn;
    } else {
      effectiveFn = (connection) async {
        try {
          return await abortSignal.waitFuture(fn(connection));
        } catch (e) {
          if (abortSignal.wasAborted) {
            // Interrupt the pg connection if the http request has finished
            // to avoid dangling connections
            unawaited(connection.close(interruptRunning: true));
          }
          rethrow;
        }
      };
    }

    return super
        .withConnection(effectiveFn, settings: settings, locality: locality);
  }
}
