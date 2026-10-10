import 'package:flutter_test/flutter_test.dart';
import 'package:cloud_comic_viewer/main.dart';

void main() {
  testWidgets('CloudComicViewerApp basic smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const CloudComicViewerApp());
    expect(find.text('Cloud Comic Viewer'), findsOneWidget);
  });
}
