import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:cronet_http/cronet_http.dart';
import 'package:cupertino_http/cupertino_http.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:ok_http/ok_http.dart';
import 'package:web_socket/web_socket.dart';

class NetworkRepository {
  static http.Client? _client;
  static Pointer<Void>? _clientPointer;

  /// Whether the current client was built for mutual TLS. Tracked separately from
  /// [_clientPointer] because installing or removing a client certificate keeps
  /// the pointer the same but changes which transport can actually connect.
  static bool _usingMtls = false;

  static Future<void> init() async {
    final clientPointer = Pointer<Void>.fromAddress(await networkApi.getClientPointer());
    // A client certificate changes which transport is usable, so it has to be part
    // of the "nothing to do" check -- otherwise installing one after init() leaves
    // the Cronet client in place and every request fails the TLS handshake.
    final mtls = Platform.isIOS ? false : await networkApi.hasCertificate();
    if (clientPointer == _clientPointer && mtls == _usingMtls) {
      return;
    }
    _clientPointer = clientPointer;
    _usingMtls = mtls;
    if (Platform.isIOS) {
      _client?.close();
      final session = URLSession.fromRawPointer(clientPointer.cast());
      _client = CupertinoClient.fromSharedSession(session);
    } else if (mtls) {
      // Cronet cannot be given a client certificate (see HttpClientManager's image
      // loader, which falls back to OkHttp for the same reason), so mTLS users stay
      // on the native OkHttp client with its configured timeouts.
      _client?.close();
      _client = OkHttpClient.fromJniGlobalRef(
        clientPointer,
        configuration: const OkHttpClientConfiguration(
          connectTimeout: Duration(seconds: 30),
          readTimeout: Duration(seconds: 60),
          writeTimeout: Duration(seconds: 60),
        ),
      );
    } else {
      // Keep the wrapper object identity stable when one already exists: callers
      // hold a snapshot of it (ApiService._apiClient.client), so replacing the
      // wrapper would leave them holding a closed client.
      final engine = await _buildCronetClient();
      final current = _client;
      if (current is _CronetAuthClient) {
        current.reset(engine);
      } else {
        _client?.close();
        _client = _CronetAuthClient(engine);
      }
    }
  }

  static Future<http.Client> _buildCronetClient() async {
    final engine = CronetEngine.build(
      cacheMode: CacheMode.memory,
      cacheMaxSize: 64 * 1024 * 1024,
      enableBrotli: true,
      enableHttp2: true,
      enableQuic: true,
      userAgent: await networkApi.getCronetUserAgent(),
    );
    return CronetClient.fromCronetEngine(engine, closeEngine: true);
  }

  static Future<void> setHeaders(Map<String, String> headers, List<String> serverUrls, {String? token}) async {
    await networkApi.setRequestHeaders(headers, serverUrls, token);
    if (Platform.isIOS) {
      await init();
    }
  }

  // ignore: avoid-unused-parameters
  static Future<WebSocket> createWebSocket(Uri uri, {Map<String, String>? headers, Iterable<String>? protocols}) {
    if (Platform.isIOS) {
      final session = URLSession.fromRawPointer(_clientPointer!.cast());
      return CupertinoWebSocket.connectWithSession(session, uri, protocols: protocols);
    } else {
      return OkHttpWebSocket.connectFromJniGlobalRef(_clientPointer!, uri, protocols: protocols);
    }
  }

  /// Clears the session cookies.
  ///
  /// The native persistent jar is cleared directly. The Cronet engine keeps its own
  /// cookie store and exposes no API to clear it, so the engine is replaced --
  /// in place, keeping this wrapper's identity intact, because callers hold a
  /// snapshot of the client (`ApiService._apiClient.client`). Swapping the object
  /// itself would leave them holding a closed one.
  static Future<void> clearCookies() async {
    await networkApi.clearCookies();
    if (Platform.isAndroid && !_usingMtls) {
      final current = _client;
      if (current is _CronetAuthClient) {
        current.reset(await _buildCronetClient());
      }
    }
  }

  /// Releases the client and the native engine behind it.
  ///
  /// Each isolate builds its own Cronet engine, and the engine holds native
  /// threads and a 64 MiB cache until `shutdown()` runs. Isolates are torn down
  /// regularly (every background worker run), so they must release it explicitly
  /// rather than rely on the isolate dying.
  static void dispose() {
    _client?.close();
    _client = null;
    _clientPointer = null;
    _usingMtls = false;
  }

  /// Returns a shared HTTP client that uses native SSL configuration.
  ///
  /// On iOS: Uses SharedURLSessionManager's URLSession.
  /// On Android: Uses a Cronet client sharing the native configuration.
  ///
  /// Must call [init] before using this method.
  static http.Client get client => _client!;

  /// Whether the active client is the native OkHttp one because a client
  /// certificate is installed. Callers that bypass [client] -- the native
  /// streaming uploader talks to Cronet directly -- must consult this first,
  /// because Cronet cannot present a client certificate.
  static bool get usingMtls => _usingMtls;
}

/// Attaches the headers the native client would have attached.
///
/// Cronet cannot be given OkHttp-style interceptors, so the auth headers have to be
/// copied onto each request. Cookie lifetime is left to the Cronet engine's own
/// store: the native jar is the single source of truth (it parses Set-Cookie per
/// RFC 6265 and syncs cookies across server URLs), and re-implementing that here
/// produced a weaker second copy that could disagree with it.
class _CronetAuthClient extends http.BaseClient {
  _CronetAuthClient(this._inner);

  http.Client _inner;

  /// Swaps the underlying client without changing this object's identity.
  ///
  /// The Cronet engine's cookie store cannot be cleared through the API, so a
  /// logout has to replace the engine. Callers keep a reference to this wrapper
  /// (e.g. `ApiService._apiClient.client`), so it must survive the swap.
  ///
  /// The old engine is closed on a delay rather than immediately: closing it
  /// calls `CronetEngine.shutdown()`, which cancels *every* request still in
  /// flight on that engine. Logout happens while the UI is still fetching
  /// (backup status, album metadata), and those requests would come back as
  /// `RequestAbortedException` -- which the upload path treats as a user
  /// cancellation. A short grace period lets them finish; the cost is that the
  /// old engine's 64 MiB cache outlives the swap by a few seconds.
  void reset(http.Client inner) {
    final previous = _inner;
    _inner = inner;
    unawaited(
      Future<void>.delayed(const Duration(seconds: 30), () {
        try {
          previous.close();
        } catch (_) {
          // Closing is best-effort: a failure here must not break logout.
        }
      }),
    );
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // The native client owns header construction: it knows the persisted headers,
    // the cookie jar (parsed per RFC 6265, synced across server URLs) and any Basic
    // credentials embedded in the URL. Copy its answer onto the request instead of
    // reconstructing it here.
    //
    // Overwrite unconditionally, matching the OkHttp interceptor this replaces
    // (HttpClientManager: `builder.header(key, value)`): user-configured headers
    // must win over whatever the API client set by default.
    final headers = await networkApi.requestAuthHeaders(request.url.toString());
    headers.forEach((k, v) => request.headers[k] = v);

    // Cronet follows redirects by replaying the same UrlRequest, so the Cookie and
    // Authorization headers set above would travel to the redirect target too --
    // OkHttp strips them on a host change, Cronet does not. This is not disabled
    // here because Immich deployments commonly rely on a same-origin 301/302
    // (http -> https at a reverse proxy), and breaking that would be worse than
    // the exposure. Cross-host redirects are the caller's responsibility.
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

