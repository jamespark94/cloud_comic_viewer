import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:webview_flutter/webview_flutter.dart';

class NaverAuthSession {
  final String nidAut;
  final String nidSes;

  NaverAuthSession({required this.nidAut, required this.nidSes});

  String toCookieHeader() => 'NID_AUT=$nidAut; NID_SES=$nidSes;';
}

class NaverAuthView extends StatefulWidget {
  final void Function(NaverAuthSession session)? onSuccess;
  final FlutterSecureStorage? secureStorage;

  const NaverAuthView({
    super.key,
    this.onSuccess,
    this.secureStorage,
  });

  static Future<NaverAuthSession?> show(BuildContext context) {
    return showDialog<NaverAuthSession>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: SizedBox(
          width: 520,
          height: 680,
          child: NaverAuthView(
            onSuccess: (session) => Navigator.of(ctx).pop(session),
          ),
        ),
      ),
    );
  }

  @override
  State<NaverAuthView> createState() => _NaverAuthViewState();
}

class _NaverAuthViewState extends State<NaverAuthView> {
  late final WebViewController _controller;
  final WebViewCookieManager _cookieManager = WebViewCookieManager();
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  bool _isLoading = true;
  bool _isProcessingAuth = false;
  double _loadingProgress = 0.0;
  String _currentUrl = '';
  Timer? _pollingTimer;

  static const String _initialLoginUrl =
      'https://nid.naver.com/nidlogin.login?mode=form&url=https%3A%2F%2Fm.mybox.naver.com%2F';

  static final List<Uri> _checkDomains = [
    Uri.parse('https://nid.naver.com'),
    Uri.parse('https://naver.com'),
    Uri.parse('https://.naver.com'),
    Uri.parse('https://mybox.naver.com'),
    Uri.parse('https://m.mybox.naver.com'),
    Uri.parse('https://m.naver.com'),
    Uri.parse('https://www.naver.com'),
  ];

  @override
  void initState() {
    super.initState();
    _initWebViewController();
    _startPolling();
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _pollingTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (!_isProcessingAuth && mounted) {
        _inspectAndCaptureCookies();
      }
    });
  }

  void _initWebViewController() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36',
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) setState(() => _loadingProgress = progress / 100.0);
          },
          onPageStarted: (url) {
            _currentUrl = url;
            if (mounted) setState(() => _isLoading = true);
            _inspectAndCaptureCookies();
          },
          onPageFinished: (url) {
            _currentUrl = url;
            if (mounted) setState(() => _isLoading = false);
            _inspectAndCaptureCookies();
          },
          onUrlChange: (change) {
            if (change.url != null) {
              _currentUrl = change.url!;
              _inspectAndCaptureCookies();
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(_initialLoginUrl));
  }

  Future<void> _inspectAndCaptureCookies() async {
    if (_isProcessingAuth) return;

    try {
      String? nidAut;
      String? nidSes;

      // 1. WebViewCookieManager를 통해 각 도메인 전수 조사
      for (final domainUri in _checkDomains) {
        try {
          final cookies = await _cookieManager.getCookies(domain: domainUri);
          for (final c in cookies) {
            if (c.name == 'NID_AUT' && c.value.isNotEmpty) nidAut = c.value;
            if (c.name == 'NID_SES' && c.value.isNotEmpty) nidSes = c.value;
          }
        } catch (_) {}
      }

      // 2. 현재 로드된 웹뷰 주소의 도메인으로도 getCookies 실행
      if (_currentUrl.isNotEmpty) {
        try {
          final uri = Uri.tryParse(_currentUrl);
          if (uri != null) {
            final cookies = await _cookieManager.getCookies(domain: uri);
            for (final c in cookies) {
              if (c.name == 'NID_AUT' && c.value.isNotEmpty) nidAut = c.value;
              if (c.name == 'NID_SES' && c.value.isNotEmpty) nidSes = c.value;
            }
          }
        } catch (_) {}
      }

      // 3. 자바스크립트로 document.cookie 조사
      if (nidAut == null || nidSes == null) {
        try {
          final jsRaw = await _controller.runJavaScriptReturningResult('document.cookie') as String;
          final unquoted = jsRaw.replaceAll('"', '');
          for (final piece in unquoted.split(';')) {
            final kv = piece.trim().split('=');
            if (kv.length >= 2) {
              final k = kv[0].trim();
              final v = kv.sublist(1).join('=').trim();
              if (k == 'NID_AUT' && v.isNotEmpty) nidAut = v;
              if (k == 'NID_SES' && v.isNotEmpty) nidSes = v;
            }
          }
        } catch (_) {}
      }

      // 로그인이 성공하여 NID_AUT와 NID_SES가 확보되었거나, MYBOX 페이지로 리다이렉트된 경우
      if (nidAut != null && nidSes != null) {
        _isProcessingAuth = true;
        _pollingTimer?.cancel();

        final session = NaverAuthSession(nidAut: nidAut, nidSes: nidSes);
        final storage = widget.secureStorage ?? _storage;
        await storage.write(key: 'NAVER_NID_AUT', value: nidAut);
        await storage.write(key: 'NAVER_NID_SES', value: nidSes);

        if (widget.onSuccess != null) {
          widget.onSuccess!(session);
        } else if (mounted) {
          Navigator.of(context).pop(session);
        }
      } else if (_currentUrl.contains('mybox.naver.com') || _currentUrl.contains('nidlogin.login') == false && _currentUrl.contains('naver.com')) {
        // 이미 네이버 페이지로 진입했는데 쿠키가 아직 비동기 반영 전일 경우 쿠키 재스캔 시도
      }
    } catch (e) {
      debugPrint('[NaverAuth] Error: $e');
    }
  }

  Future<void> _manualCheck() async {
    await _inspectAndCaptureCookies();
    if (!_isProcessingAuth && mounted) {
      // 쿠키 상태 디버그 알림
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '네이버 로그인 완료를 감지하지 못했습니다.\n현재 페이지: $_currentUrl\n로그인 후 MYBOX 또는 메인화면으로 이동했는지 확인해 주세요.',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('네이버 로그인 (MYBOX)'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(null),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.check_circle_rounded, color: Colors.greenAccent, size: 28),
            tooltip: '로그인 완료 확인',
            onPressed: _manualCheck,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '새로고침',
            onPressed: () => _controller.reload(),
          ),
        ],
        bottom: _isLoading
            ? PreferredSize(
                preferredSize: const Size.fromHeight(3),
                child: LinearProgressIndicator(value: _loadingProgress),
              )
            : null,
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_isProcessingAuth)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.greenAccent),
                    SizedBox(height: 16),
                    Text(
                      '네이버 MYBOX 연결 중입니다...',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
