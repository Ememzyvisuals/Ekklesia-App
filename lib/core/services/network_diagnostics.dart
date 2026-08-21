import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'user_groq_key_service.dart';

/// Result of a single diagnostic check — deliberately keeps the raw
/// exception text (not a friendlied-up message) since this screen exists
/// specifically to surface exact, unfiltered failure reasons for
/// debugging, unlike every other error surface in the app which
/// deliberately hides raw exception text from normal users.
class DiagnosticResult {
  const DiagnosticResult({
    required this.name,
    required this.ok,
    required this.detail,
    required this.durationMs,
  });

  final String name;
  final bool ok;
  final String detail;
  final int durationMs;
}

/// Built directly in response to a real, unresolved bug report: the app
/// behaving as if fully offline while other apps on the same device had
/// working internet at that exact moment — with no further evidence
/// available (missing INTERNET permission was checked and ruled out;
/// Dio/http client configuration was checked and found unremarkable;
/// no confirmed report of flutter_native_splash/flutter_launcher_icons
/// stripping manifest permissions either). Rather than guess at a fourth
/// hypothesis, this gives a real, on-device tool to test each of the
/// app's actual network dependencies individually and see exactly which
/// one fails and how, next time it happens.
class NetworkDiagnostics {
  NetworkDiagnostics._internal();
  static final NetworkDiagnostics instance = NetworkDiagnostics._internal();

  /// Raw, low-level connectivity — a successful DNS lookup + TCP
  /// connect to a well-known host, independent of any HTTP client
  /// wrapper (Dio, http, etc.) this app itself uses. If this ONE check
  /// fails while every other app on the device has internet, that
  /// specifically points at something OS-level scoped to this app (a
  /// missing permission, a network security policy, a VPN/firewall
  /// rule targeting this package) rather than the app's own HTTP
  /// client code, since this bypasses that code entirely.
  Future<DiagnosticResult> _checkRawConnectivity() async {
    final sw = Stopwatch()..start();
    try {
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 8));
      sw.stop();
      if (result.isEmpty || result[0].rawAddress.isEmpty) {
        return DiagnosticResult(
            name: 'Raw DNS + socket (google.com)',
            ok: false,
            detail: 'Lookup returned no address',
            durationMs: sw.elapsedMilliseconds);
      }
      return DiagnosticResult(
          name: 'Raw DNS + socket (google.com)',
          ok: true,
          detail: 'Resolved to ${result[0].address}',
          durationMs: sw.elapsedMilliseconds);
    } catch (e) {
      sw.stop();
      return DiagnosticResult(
          name: 'Raw DNS + socket (google.com)',
          ok: false,
          detail: e.toString(),
          durationMs: sw.elapsedMilliseconds);
    }
  }

  Future<DiagnosticResult> _checkHttps(String name, String url,
      {Map<String, String>? headers}) async {
    final sw = Stopwatch()..start();
    try {
      final response = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 10));
      sw.stop();
      // Any HTTP response at all (even 401/403/404) proves the network
      // path itself works — the request reached the server and came
      // back. Only a thrown exception (DNS failure, TLS failure,
      // connection refused, timeout) means the network path itself is
      // broken, which is what this tool exists to catch.
      return DiagnosticResult(
        name: name,
        ok: true,
        detail: 'HTTP ${response.statusCode}',
        durationMs: sw.elapsedMilliseconds,
      );
    } catch (e) {
      sw.stop();
      return DiagnosticResult(
          name: name,
          ok: false,
          detail: e.toString(),
          durationMs: sw.elapsedMilliseconds);
    }
  }

  Future<DiagnosticResult> _checkGroqKey() async {
    final sw = Stopwatch()..start();
    try {
      final key = await UserGroqKeyService.instance.getKey();
      sw.stop();
      return DiagnosticResult(
        name: 'Groq API key configured',
        ok: key != null,
        detail: key != null ? 'Key is set' : 'No key set in Settings',
        durationMs: sw.elapsedMilliseconds,
      );
    } catch (e) {
      sw.stop();
      return DiagnosticResult(
          name: 'Groq API key configured',
          ok: false,
          detail: e.toString(),
          durationMs: sw.elapsedMilliseconds);
    }
  }

  /// Runs every check, one at a time (not in parallel) — so if one hangs
  /// unexpectedly despite its own timeout, it's obvious which one from
  /// the screen simply stopping partway through, rather than all
  /// results arriving or failing together.
  Stream<DiagnosticResult> runAll() async* {
    yield await _checkRawConnectivity();
    yield await _checkGroqKey();
    yield await _checkHttps(
        'Groq API (api.groq.com)', 'https://api.groq.com/openai/v1/models');
    yield await _checkHttps('YouTube Data API (googleapis.com)',
        'https://www.googleapis.com/youtube/v3/videos?part=id&id=dQw4w9WgXcQ&key=${AppConfig.youtubeApiKey}');
    yield await _checkHttps('TTS model host (huggingface.co)',
        'https://huggingface.co/Axiveri/Renpiper-mms-onnx-V1/resolve/main');
    yield await _checkHttps('DCLM radio stream host (airtime.dclm.org)',
        AppConfig.dclmStreams['english']!);
  }
}
