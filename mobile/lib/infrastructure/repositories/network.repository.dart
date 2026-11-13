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
    _client?.close();
    if (Platform.isIOS) {
      final session = URLSession.fromRawPointer(clientPointer.cast());
      _client = CupertinoClient.fromSharedSession(session);
    } else if (mtls) {
      // Cronet cannot be given a client certificate (see HttpClientManager's image
      // loader, which falls back to OkHttp for the same reason), so mTLS users stay
      // on the native OkHttp client with its configured timeouts.
      _client = OkHttpClient.fromJniGlobalRef(
        clientPointer,
        configuration: const OkHttpClientConfiguration(
          connectTimeout: Duration(seconds: 30),
          readTimeout: Duration(seconds: 60),
          writeTimeout: Duration(seconds: 60),
        ),
      );
    } else {
      _client = _CronetAuthClient(await _buildCronetClient());
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
  /// cookie store and exposes no API to clear it, so the client is dropped and
  /// rebuilt on next use instead -- otherwise the old access token would keep being
  /// attached to requests after the user signed out.
  static Future<void> clearCookies() async {
    await networkApi.clearCookies();
    if (Platform.isAndroid && !_usingMtls) {
      // Drop the engine (its cookie store cannot be cleared through the API) and
      // rebuild it immediately: callers read [client] right after logout, so
      // leaving it null here would crash them.
      final pointer = _clientPointer;
      _client?.close();
      _client = _CronetAuthClient(await _buildCronetClient());
      _clientPointer = pointer;
    }
  }

  /// Returns a shared HTTP client that uses native SSL configuration.
  ///
  /// On iOS: Uses SharedURLSessionManager's URLSession.
  /// On Android: Uses a Cronet client sharing the native configuration.
  ///
  /// Must call [init] before using this method.
  static http.Client get client => _client!;
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

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // The native client owns header construction: it knows the persisted headers,
    // the cookie jar (parsed per RFC 6265, synced across server URLs) and any Basic
    // credentials embedded in the URL. Copy its answer onto the request instead of
    // reconstructing it here.
    final headers = await networkApi.requestAuthHeaders(request.url.toString());
    headers.forEach((k, v) {
      if (!request.headers.containsKey(k)) {
        request.headers[k] = v;
      }
    });

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

