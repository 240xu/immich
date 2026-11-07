import 'dart:ffi';
import 'dart:io';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:ok_http/ok_http.dart';
import 'package:web_socket/web_socket.dart';
import 'package:cronet_http/cronet_http.dart';

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
      _client = _CronetAuthClient(CronetClient.defaultCronetEngine());
    }
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

  /// Returns a shared HTTP client that uses native SSL configuration.
  ///
  /// On iOS: Uses SharedURLSessionManager's URLSession.
  /// On Android: Uses SharedHttpClientManager's OkHttpClient.
  ///
  /// Must call [init] before using this method.
  static http.Client get client => _client!;
}

class _CronetAuthClient extends http.BaseClient {
  _CronetAuthClient(this._inner);

  final http.Client _inner;

  final Map<String, Map<String, String>> _cookies = {};

  String? _cookieHeader(String host) {
    final jar = _cookies[host];
    if (jar == null || jar.isEmpty) return null;
    return jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  void _storeCookies(String host, List<String> setCookieHeaders) {
    final raws = <String>[];
    for (final line in setCookieHeaders) {
      final parts = line.split(RegExp(r',\s*(?=[A-Za-z0-9!#$%&*+.^_`|~-]+=)'));
      raws.addAll(parts);
    }

    for (final raw in raws) {
      final semi = raw.indexOf(';');
      final pair = (semi >= 0 ? raw.substring(0, semi) : raw).trim();
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final name = pair.substring(0, eq).trim();
      final value = pair.substring(eq + 1).trim();
      if (name.isEmpty) continue;
      final jar = _cookies.putIfAbsent(host, () => {});
      if (value.isEmpty) {
        jar.remove(name);
      } else {
        jar[name] = value;
      }
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final host = request.url.host;

    final headers = await networkApi.requestAuthHeaders(request.url.toString());
    headers.forEach((k, v) {
      if (!request.headers.containsKey(k)) {
        request.headers[k] = v;
      }
    });

    final cookie = _cookieHeader(host);
    if (cookie != null && !request.headers.containsKey('cookie')) {
      request.headers['cookie'] = cookie;
    }

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
