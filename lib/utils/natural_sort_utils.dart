class NaturalSortUtils {
  static final RegExp _numRegex = RegExp(r'(\d+)');

  /// 문자열 내의 숫자 청크를 감지하여 인간이 인지하는 순서(1, 2, 10...)대로 정렬하는 비교 함수
  static int compare(String a, String b) {
    final aLower = a.toLowerCase();
    final bLower = b.toLowerCase();

    final aTokens = _tokenize(aLower);
    final bTokens = _tokenize(bLower);

    final minLength = aTokens.length < bTokens.length ? aTokens.length : bTokens.length;

    for (int i = 0; i < minLength; i++) {
      final aTok = aTokens[i];
      final bTok = bTokens[i];

      final aIsNum = aTok.isNumber;
      final bIsNum = bTok.isNumber;

      if (aIsNum && bIsNum) {
        final aVal = BigInt.tryParse(aTok.text) ?? BigInt.zero;
        final bVal = BigInt.tryParse(bTok.text) ?? BigInt.zero;
        final comp = aVal.compareTo(bVal);
        if (comp != 0) return comp;
        // 숫자의 값이 같을 때 앞자리 0 개수 비교 (예: "01" vs "1")
        final lenComp = aTok.text.length.compareTo(bTok.text.length);
        if (lenComp != 0) return lenComp;
      } else {
        final comp = aTok.text.compareTo(bTok.text);
        if (comp != 0) return comp;
      }
    }

    return aTokens.length.compareTo(bTokens.length);
  }

  static List<_SortToken> _tokenize(String str) {
    final List<_SortToken> tokens = [];
    int lastEnd = 0;

    for (final match in _numRegex.allMatches(str)) {
      if (match.start > lastEnd) {
        tokens.add(_SortToken(str.substring(lastEnd, match.start), false));
      }
      tokens.add(_SortToken(match.group(0)!, true));
      lastEnd = match.end;
    }

    if (lastEnd < str.length) {
      tokens.add(_SortToken(str.substring(lastEnd), false));
    }

    return tokens;
  }
}

class _SortToken {
  final String text;
  final bool isNumber;

  _SortToken(this.text, this.isNumber);
}
