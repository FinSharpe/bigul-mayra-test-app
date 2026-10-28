// Mayra handoff tester: a stand-in for the Bigul app.
//
// Mayra lives in an in-app panel: a floating button over the app's own
// screen opens a sheet with Mayra's web UI inside. The WebView is the app's
// own (top-level, never an iframe) and stays alive between opens, so the
// chat is still there when the client comes back. The first open signs the
// client in the way the Bigul app will (see README.md):
// /auth/mobile with the platform code and session token in two headers, on
// that first load only, behind a loading cover. /auth/mobile/expired and
// /auth/mobile/error are intercepted; other sites open in the phone's browser.
//
// Test-only. Never log or display the token. Optional --dart-define values:
//   BASE_URL, PLATFORM, APP_TOKEN, VERCEL_BYPASS (FinSharpe preview builds only).

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

const _defaultBaseUrl = String.fromEnvironment(
  'BASE_URL',
  defaultValue: 'https://bigul-ai.vercel.app',
);
const _defaultPlatform = String.fromEnvironment('PLATFORM', defaultValue: '12');
const _defaultToken = String.fromEnvironment('APP_TOKEN');
const _defaultBypass = String.fromEnvironment('VERCEL_BYPASS');

// The app's own limit for the loading cover; Mayra answers within 12 s.
const _coverTimeout = Duration(seconds: 15);
const _brand = Color(0xFF3265A8);

void main() => runApp(const TesterApp());

class TesterApp extends StatelessWidget {
  const TesterApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Mayra tester',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: _brand),
        home: const HomeScreen(),
      );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// Where the Mayra session stands.
enum _Mayra { signedOut, loading, ready, failed }

class _HomeScreenState extends State<HomeScreen> {
  final _baseUrl = TextEditingController(text: _defaultBaseUrl);
  final _platform = TextEditingController(text: _defaultPlatform);
  final _token = TextEditingController(text: _defaultToken);
  final _bypass = TextEditingController(text: _defaultBypass);
  final _log = <String>[];
  final _random = Random.secure();

  WebViewController? _controller;
  _Mayra _mayra = _Mayra.signedOut;
  bool _panelOpen = false;
  bool _showLog = false;
  bool _intercept = true;
  String _failure = '';
  int _retries = 0;
  Timer? _coverTimer;
  DateTime? _started;

  Uri get _base => Uri.parse(_baseUrl.text.trim());
  bool _isOurs(Uri uri) => uri.scheme == _base.scheme && uri.host == _base.host;

  void _note(String line) {
    final at = _started == null
        ? ''
        : '+${DateTime.now().difference(_started!).inMilliseconds}ms ';
    if (mounted) setState(() => _log.add('$at$line'));
    debugPrint('[tester] $at$line');
  }

  // Paths only: a URL here never carries the token, but stay strict.
  String _show(Uri uri) =>
      '${_isOurs(uri) ? '' : uri.host}${uri.path}'
      '${uri.queryParameters.containsKey('code') ? '?code=${uri.queryParameters['code']}' : ''}';

  // ---------------------------------------------------------------------------
  // The panel

  Future<void> _openPanel() async {
    if (_token.text.trim().isEmpty) {
      await _openSettings(reason: 'Paste the app token to open Mayra.');
      if (_token.text.trim().isEmpty) return;
    }
    setState(() => _panelOpen = true);
    _note('panel opened');
    // Sign in only when needed: an open chat is simply shown again.
    if (_mayra == _Mayra.signedOut || _mayra == _Mayra.failed) _signIn();
  }

  void _closePanel() {
    setState(() => _panelOpen = false);
    _note('panel closed (WebView kept alive)');
  }

  // ---------------------------------------------------------------------------
  // Sign-in

  Future<void> _signIn({bool retry = false}) async {
    if (!retry) {
      _retries = 0;
      _log.clear();
    }
    _started = DateTime.now();
    final controller = _controller ??
        (WebViewController()..setJavaScriptMode(JavaScriptMode.unrestricted));
    controller.setNavigationDelegate(_delegate());
    setState(() {
      _controller = controller;
      _mayra = _Mayra.loading;
      _failure = '';
    });

    // A fresh random value per sign-in: Android replays load headers when the
    // same URL is reloaded.
    final nonce = _random.nextInt(1 << 32).toRadixString(36);
    final url = _base.replace(
      path: '/auth/mobile',
      queryParameters: {'next': '/', 'n': nonce},
    );
    final headers = <String, String>{
      'X-Bigul-Platform': _platform.text.trim(),
      'X-Bigul-Token': _token.text.trim(),
    };
    final bypass = _bypass.text.trim();
    if (bypass.isNotEmpty) {
      // Test-only: through Vercel's preview protection, with a bypass cookie.
      headers['x-vercel-protection-bypass'] = bypass;
      headers['x-vercel-set-bypass-cookie'] = 'true';
    }
    _note('load /auth/mobile (headers: platform, token'
        '${bypass.isEmpty ? '' : ', vercel bypass'})');
    _coverTimer?.cancel();
    _coverTimer = Timer(_coverTimeout, () {
      if (_mayra == _Mayra.loading) {
        _fail('Timed out after ${_coverTimeout.inSeconds}s');
      }
    });
    await controller.loadRequest(url, headers: headers);
  }

  NavigationDelegate _delegate() => NavigationDelegate(
        onNavigationRequest: _intercept ? _onNavigationRequest : null,
        onPageStarted: (url) => _note('page started ${_show(Uri.parse(url))}'),
        onPageFinished: (url) {
          final uri = Uri.parse(url);
          _note('page finished ${_show(uri)}');
          if (_mayra == _Mayra.loading &&
              _isOurs(uri) &&
              !uri.path.startsWith('/auth/') &&
              !uri.path.startsWith('/login')) {
            _coverTimer?.cancel();
            setState(() => _mayra = _Mayra.ready);
            _note('CHAT LOADED (signed in)');
          }
          if (!_intercept && _isOurs(uri)) _checkFallback(uri);
        },
        onUrlChange: (change) {
          if (change.url != null) _note('url → ${_show(Uri.parse(change.url!))}');
        },
        onHttpError: (error) => _note('HTTP ${error.response?.statusCode} '
            '${error.request == null ? '' : _show(error.request!.uri)}'),
        onWebResourceError: (error) => _note(
            'web error ${error.errorCode} ${error.description} main=${error.isForMainFrame}'),
      );

  FutureOr<NavigationDecision> _onNavigationRequest(NavigationRequest request) {
    final uri = Uri.parse(request.url);
    _note('nav request ${_show(uri)} main=${request.isMainFrame}');
    if (!request.isMainFrame) return NavigationDecision.navigate;
    if (!_isOurs(uri)) {
      if (uri.host == 'vercel.com') {
        _fail('Blocked by Vercel preview protection: add the bypass secret.');
        return NavigationDecision.prevent;
      }
      // Other sites (e.g. citation links) open in the phone's browser.
      _note('→ external browser: ${uri.host}');
      launchUrl(uri, mode: LaunchMode.externalApplication);
      return NavigationDecision.prevent;
    }
    if (_checkFallback(uri)) return NavigationDecision.prevent;
    return NavigationDecision.navigate;
  }

  /// Handles /auth/mobile/expired and /auth/mobile/error; true when handled.
  bool _checkFallback(Uri uri) {
    if (uri.path == '/auth/mobile/expired') {
      _note('intercepted EXPIRED');
      _retryOrFail('Your Mayra session ended.');
      return true;
    }
    if (uri.path == '/auth/mobile/error') {
      final code = uri.queryParameters['code'] ?? '?';
      _note('intercepted ERROR code=$code');
      _retryOrFail('Couldn\'t sign in to Mayra ($code).');
      return true;
    }
    return false;
  }

  void _retryOrFail(String reason) {
    if (_retries < 1) {
      _retries += 1;
      _note('signing in again once, with a fresh nonce');
      Future.delayed(
          const Duration(milliseconds: 300), () => _signIn(retry: true));
    } else {
      _fail(reason);
    }
  }

  void _fail(String reason) {
    _coverTimer?.cancel();
    _note('FAILED: $reason');
    setState(() {
      _mayra = _Mayra.failed;
      _failure = reason;
    });
  }

  /// What the Bigul app must do on logout or account switch.
  Future<void> _signOut() async {
    await WebViewCookieManager().clearCookies();
    await _controller?.clearLocalStorage();
    await _controller?.clearCache();
    setState(() {
      _controller = null; // a fresh WebView next time
      _mayra = _Mayra.signedOut;
      _panelOpen = false;
    });
    _snack('Signed out: WebView cookies, storage and cache cleared.');
  }

  // ---------------------------------------------------------------------------
  // Settings (test-only)

  Future<void> _openSettings({String? reason}) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => StatefulBuilder(
          builder: (context, setSheet) => Padding(
            padding: EdgeInsets.fromLTRB(
                16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
            child: ListView(
              shrinkWrap: true,
              children: [
                Text('Test settings',
                    style: Theme.of(context).textTheme.titleMedium),
                if (reason != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(reason,
                        style: const TextStyle(color: Colors.redAccent)),
                  ),
                TextField(
                  controller: _baseUrl,
                  decoration: const InputDecoration(labelText: 'Mayra base URL'),
                  keyboardType: TextInputType.url,
                ),
                TextField(
                  controller: _platform,
                  decoration: const InputDecoration(labelText: 'Platform code'),
                  keyboardType: TextInputType.number,
                ),
                _secretField(_token, 'App session token (JWT)', setSheet),
                _secretField(_bypass, 'Vercel bypass secret (previews only)',
                    setSheet),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Intercept navigations'),
                  subtitle: const Text('On, like the Bigul app.'),
                  value: _intercept,
                  onChanged: (value) {
                    setState(() => _intercept = value);
                    setSheet(() {});
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Show sign-in log in the panel'),
                  value: _showLog,
                  onChanged: (value) {
                    setState(() => _showLog = value);
                    setSheet(() {});
                  },
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done'),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _secretField(TextEditingController controller, String label,
          StateSetter setSheet) =>
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: label,
                helperText: controller.text.isEmpty
                    ? 'empty'
                    : '${controller.text.length} characters',
              ),
              onChanged: (_) => setSheet(() {}),
            ),
          ),
          IconButton(
            tooltip: 'Paste',
            icon: const Icon(Icons.content_paste),
            onPressed: () async {
              final data = await Clipboard.getData(Clipboard.kTextPlain);
              if (data?.text != null) {
                controller.text = data!.text!.trim();
                setSheet(() {});
              }
            },
          ),
        ],
      );

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  void dispose() {
    _coverTimer?.cancel();
    for (final c in [_baseUrl, _platform, _token, _bypass]) {
      c.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // UI

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height;
    return PopScope(
      canPop: !_panelOpen,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // Back goes back inside Mayra first, then closes the panel.
        if (_controller != null && await _controller!.canGoBack()) {
          await _controller!.goBack();
        } else {
          _closePanel();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Bigul (test app)'),
          actions: [
            IconButton(
              tooltip: 'Test settings',
              icon: const Icon(Icons.tune),
              onPressed: _openSettings,
            ),
            IconButton(
              tooltip: 'Sign out of the app',
              icon: const Icon(Icons.logout),
              onPressed: _signOut,
            ),
          ],
        ),
        body: Stack(
          children: [
            const _AppHome(),
            // Scrim behind the panel; tap to close.
            IgnorePointer(
              ignoring: !_panelOpen,
              child: AnimatedOpacity(
                opacity: _panelOpen ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: GestureDetector(
                  onTap: _closePanel,
                  child: Container(color: Colors.black38),
                ),
              ),
            ),
            // The Mayra panel. Kept in the tree once created, so the chat
            // survives closing and reopening.
            if (_controller != null)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                left: 0,
                right: 0,
                height: height * 0.86,
                bottom: _panelOpen ? 0 : -height,
                child: _panel(),
              ),
          ],
        ),
        floatingActionButton: _panelOpen
            ? null
            : FloatingActionButton(
                tooltip: 'Ask Mayra',
                backgroundColor: _brand,
                foregroundColor: Colors.white,
                shape: const CircleBorder(),
                onPressed: _openPanel,
                child: const Icon(Icons.auto_awesome),
              ),
      ),
    );
  }

  Widget _panel() => Material(
        elevation: 16,
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            SizedBox(
              height: 48,
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  const Icon(Icons.auto_awesome, color: _brand, size: 20),
                  const SizedBox(width: 8),
                  const Text('Mayra AI',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.keyboard_arrow_down),
                    onPressed: _closePanel,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Stack(
                children: [
                  WebViewWidget(controller: _controller!),
                  if (_mayra == _Mayra.loading)
                    const ColoredBox(
                      color: Colors.white,
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  if (_mayra == _Mayra.failed) _failedView(),
                ],
              ),
            ),
            if (_showLog) _logView(),
          ],
        ),
      );

  Widget _failedView() => ColoredBox(
        color: Colors.white,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_failure, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => _signIn(),
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _logView() => Container(
        height: 120,
        width: double.infinity,
        color: const Color(0xFF111827),
        padding: const EdgeInsets.all(8),
        child: ListView(
          reverse: true,
          children: [
            for (final line in _log.reversed)
              Text(line,
                  style: const TextStyle(
                      color: Color(0xFFD1D5DB),
                      fontFamily: 'monospace',
                      fontSize: 11)),
          ],
        ),
      );
}

/// A placeholder for the app's own screen behind Mayra.
class _AppHome extends StatelessWidget {
  const _AppHome();

  @override
  Widget build(BuildContext context) {
    Widget card(String title, String body, IconData icon) => Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: Icon(icon, color: _brand),
            title: Text(title),
            subtitle: Text(body),
          ),
        );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        card('Portfolio', 'Your holdings would be here.', Icons.pie_chart_outline),
        card('Watchlist', 'Stocks you follow.', Icons.visibility_outlined),
        card('Orders', 'Today\'s orders.', Icons.receipt_long_outlined),
        card('Funds', 'Available margin.', Icons.account_balance_wallet_outlined),
        const SizedBox(height: 8),
        const Text(
          'Tap the ✦ button to ask Mayra. The chat opens in a panel inside the '
          'app and stays where you left it when you close and reopen it.',
          style: TextStyle(color: Colors.black54),
        ),
      ],
    );
  }
}
