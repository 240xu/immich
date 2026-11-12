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

  static Future<void> init() async {
    final clientPointer = Pointer<Void>.fromAddress(await networkApi.getClientPointer());
    if (clientPointer == _clientPointer) {
      return;
    }
    _clientPointer = clientPointer;
    _client?.close();
    if (Platform.isIOS) {
      final session = URLSession.fromRawPointer(clientPointer.cast());
      _client = CupertinoClient.fromSharedSession(session);
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

  /// Clears both copies of the session cookies: the native persistent jar and the
  /// in-process jar inside [_CronetAuthClient].
  ///
  /// Call this on logout instead of `networkApi.clearCookies()` -- the latter only
  /// touches the native jar, and the Dart jar would then re-send the old access
  /// token on the next request to the same host.
  static Future<void> clearCookies() async {
    await networkApi.clearCookies();
    final current = _client;
    if (current is _CronetAuthClient) {
      current.clearCookieJar();
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

class _CronetAuthClient extends http.BaseClient {
  _CronetAuthClient(this._inner);

  final http.Client _inner;

  final Map<String, Map<String, _JarCookie>> _cookies = {};

  /// Drops the whole jar. Logout must call this: the native jar is not the only
  /// copy of the session cookies, and leaving this one populated means the old
  /// access token is sent again on the next request to the same host -- after
  /// the user has signed out.
  void clearCookieJar() => _cookies.clear();

  String? _cookieHeader(String host, {required bool isHttps, required String path}) {
    final jar = _cookies[host];
    if (jar == null || jar.isEmpty) return null;
    jar.removeWhere((_, cookie) => cookie.isExpired);
    final parts = <String>[];
    for (final entry in jar.entries) {
      final cookie = entry.value;
      // A Secure cookie must not travel over plain HTTP: the access token is a
      // bearer credential, and Immich supports http:// LAN endpoints.
      if (cookie.secure && !isHttps) continue;
      if (!path.startsWith(cookie.path)) continue;
      parts.add('${entry.key}=${cookie.value}');
    }
    return parts.isEmpty ? null : parts.join('; ');
  }

  void _storeCookies(String host, List<String> setCookieHeaders) {
    final raws = <String>[];
    for (final line in setCookieHeaders) {
      final parts = line.split(RegExp(r',\s*(?=[A-Za-z0-9!#$%&*+.^_`|~-]+=)'));
      raws.addAll(parts);
    }

    for (final raw in raws) {
      final segments = raw.split(';');
      final eq = segments.first.indexOf('=');
      if (eq <= 0) continue;
      final name = segments.first.substring(0, eq).trim();
      final value = segments.first.substring(eq + 1).trim();
      if (name.isEmpty) continue;

      var path = '/';
      var secure = false;
      DateTime? expiresAt;
      for (final attribute in segments.skip(1)) {
        final i = attribute.indexOf('=');
        final key = (i < 0 ? attribute : attribute.substring(0, i)).trim().toLowerCase();
        final rawValue = i < 0 ? '' : attribute.substring(i + 1).trim();
        switch (key) {
          case 'path':
            if (rawValue.startsWith('/')) path = rawValue;
            break;
          case 'secure':
            secure = true;
            break;
          case 'max-age':
            final seconds = int.tryParse(rawValue);
            if (seconds != null) expiresAt = DateTime.now().add(Duration(seconds: seconds));
            break;
          case 'expires':
            final parsed = _tryParseHttpDate(rawValue);
            if (parsed != null) expiresAt = parsed;
            break;
        }
      }

      final jar = _cookies.putIfAbsent(host, () => {});
      final expired = expiresAt != null && !expiresAt.isAfter(DateTime.now());
      if (value.isEmpty || expired) {
        jar.remove(name);
      } else {
        jar[name] = _JarCookie(value, path: path, secure: secure, expiresAt: expiresAt);
      }
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final host = request.url.host;
    final isHttps = request.url.scheme == 'https';
    final path = request.url.path.isEmpty ? '/' : request.url.path;

    final headers = await networkApi.requestAuthHeaders(request.url.toString());
    headers.forEach((k, v) {
      if (!request.headers.containsKey(k)) {
        request.headers[k] = v;
      }
    });

    final cookie = _cookieHeader(host, isHttps: isHttps, path: path);
    if (cookie != null && !request.headers.containsKey('cookie')) {
      request.headers['cookie'] = cookie;
    }

    // Cronet follows redirects by replaying the same UrlRequest, so the Cookie and
    // Authorization headers set above would travel to the redirect target too --
    // OkHttp strips them on a host change, Cronet does not. This is not disabled
    // here because Immich deployments commonly rely on a same-origin 301/302
    // (http -> https at a reverse proxy), and breaking that would be worse than
    // the exposure. Cross-host redirects are the caller's responsibility.
    final response = await _inner.send(request);

    final setCookies = response.headers.entries
        .where((e) => e.key.toLowerCase() == 'set-cookie')
        .map((e) => e.value)
        .toList();
    if (setCookies.isNotEmpty) {
      _storeCookies(host, setCookies);
    }

    return response;
  }

  @override
  void close() => _inner.close();
}

/// One entry in the Dart-side cookie jar.
///
/// Only the attributes that change how a cookie is *sent* are kept. Domain is
/// deliberately absent: this jar is keyed by the exact request host, matching how
/// the calls above look it up, and pretending to support cross-subdomain sharing
/// without an eTLD+1 computation would be worse than not supporting it.
class _JarCookie {
  const _JarCookie(this.value, {required this.path, required this.secure, this.expiresAt});

  final String value;
  final String path;
  final bool secure;
  final DateTime? expiresAt;

  bool get isExpired => expiresAt != null && !expiresAt!.isAfter(DateTime.now());
}

/// Parses the three date formats HTTP allows. Returns null when the value is not
/// a date, so an unparseable Expires simply leaves the cookie non-expiring.
DateTime? _tryParseHttpDate(String value) {
  try {
    return HttpDate.parse(value);
  } catch (_) {
    return null;
  }
}
