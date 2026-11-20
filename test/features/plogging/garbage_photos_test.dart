import 'dart:convert';
import 'dart:typed_data';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ploggr/features/plogging/data/plog_api.dart';
import 'package:ploggr/features/plogging/garbage_photos.dart';
import 'package:ploggr/features/plogging/saved_photos.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAACXBIWXMAAAPoAAAD6AG1e1Jr'
  'AAAAD0lEQVQImWNgaGAAIQgFAA4OAgHj5clFAAAAAElFTkSuQmCC',
);

class _Photos extends Fake implements PlogApi {
  final reads = <String>[];
  bool missing = true;
  @override
  Future<List<String>> evidence(String plogId) async => ['one', 'two'];
  @override
  Future<Uint8List> image(String plogId, String photoId) async {
    reads.add(photoId);
    if (photoId == 'one' && missing) throw StateError('Missing image');
    return _png;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'checks file size, type and decodability before storing a selection',
    () async {
      expect(await photoType(_png), 'image/png');
      await expectLater(
        photoType(Uint8List(8 * 1024 * 1024 + 1)),
        throwsFormatException,
      );
      await expectLater(
        photoType(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
      await expectLater(photoType(_png.sublist(0, 12)), throwsA(anything));
    },
  );

  testWidgets('one unavailable image can be retried independently', (
    tester,
  ) async {
    final api = _Photos();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [plogApiProvider.overrideWithValue(api)],
        child: const MaterialApp(home: Scaffold(body: SavedPhotos('plog'))),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Garbage photos (2)'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is Image && w.semanticLabel == 'Saved garbage photo 2',
      ),
      findsOneWidget,
    );
    api.missing = false;
    await tester.tap(find.text('Photo 1 unavailable · Retry'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (w) => w is Image && w.semanticLabel == 'Saved garbage photo 1',
      ),
      findsOneWidget,
    );
    expect(api.reads, ['one', 'two', 'one']);
  });
}
