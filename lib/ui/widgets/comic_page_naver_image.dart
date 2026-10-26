import 'package:flutter/material.dart';

class ComicPageNaverImage extends StatelessWidget {
  final String imageUrl;
  final String nidAut;
  final String nidSes;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? errorWidget;

  const ComicPageNaverImage({
    super.key,
    required this.imageUrl,
    required this.nidAut,
    required this.nidSes,
    this.fit = BoxFit.contain,
    this.placeholder,
    this.errorWidget,
  });

  Map<String, String> get _naverImageHeaders => {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
        'Referer': 'https://mybox.naver.com/',
        'Origin': 'https://mybox.naver.com',
        'Cookie': 'NID_AUT=$nidAut; NID_SES=$nidSes;',
      };

  @override
  Widget build(BuildContext context) {
    return Image.network(
      imageUrl,
      headers: _naverImageHeaders,
      fit: fit,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return placeholder ??
            Center(
              child: SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: loadingProgress.expectedTotalBytes != null
                      ? loadingProgress.cumulativeBytesLoaded /
                          loadingProgress.expectedTotalBytes!
                      : null,
                ),
              ),
            );
      },
      errorBuilder: (context, error, stackTrace) {
        return errorWidget ??
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.broken_image_rounded, size: 40, color: Colors.grey),
                  const SizedBox(height: 8),
                  Text(
                    '이미지 로딩 실패\n($error)',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            );
      },
    );
  }
}
