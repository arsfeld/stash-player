import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/domain/scan_options.dart';

void main() {
  group('resolveScanOptions', () {
    test("the web UI's saved task defaults win over the server's", () {
      final options = resolveScanOptions(
        uiTaskDefaultsScan: {
          'scanGenerateCovers': true,
          'scanGeneratePreviews': true,
          'scanGenerateSprites': true,
        },
        serverDefaultsScan: {'scanGenerateThumbnails': true},
      );

      expect(
        options,
        const ScanOptions(
          generateCovers: true,
          generatePreviews: true,
          generateSprites: true,
        ),
      );
    });

    test('server defaults apply when the web UI saved none', () {
      final options = resolveScanOptions(
        serverDefaultsScan: {
          'scanGenerateCovers': true,
          'scanGenerateThumbnails': true,
        },
      );

      expect(
        options,
        const ScanOptions(generateCovers: true, generateThumbnails: true),
      );
    });

    test('with nothing saved anywhere, only covers are generated', () {
      expect(resolveScanOptions(), ScanOptions.builtIn);
      expect(ScanOptions.builtIn, const ScanOptions(generateCovers: true));
    });

    test('a source that is not a JSON object falls through to the next', () {
      final options = resolveScanOptions(
        uiTaskDefaultsScan: 'garbage',
        serverDefaultsScan: {'scanGeneratePhashes': true},
      );

      expect(options, const ScanOptions(generatePhashes: true));
      expect(
        resolveScanOptions(uiTaskDefaultsScan: 42, serverDefaultsScan: null),
        ScanOptions.builtIn,
      );
    });

    test('an empty saved object means everything off, as in the web UI', () {
      expect(resolveScanOptions(uiTaskDefaultsScan: {}), const ScanOptions());
    });
  });

  group('ScanOptions.fromJson', () {
    test('reads every known flag', () {
      final options = ScanOptions.fromJson({
        'scanGenerateCovers': true,
        'scanGeneratePreviews': true,
        'scanGenerateImagePreviews': true,
        'scanGenerateSprites': true,
        'scanGeneratePhashes': true,
        'scanGenerateThumbnails': true,
        'scanGenerateClipPreviews': true,
        'rescan': true,
      });

      expect(
        options,
        const ScanOptions(
          generateCovers: true,
          generatePreviews: true,
          generateImagePreviews: true,
          generateSprites: true,
          generatePhashes: true,
          generateThumbnails: true,
          generateClipPreviews: true,
          rescan: true,
        ),
      );
    });

    test('a missing or non-bool flag is false, and unknown keys are '
        'dropped', () {
      final options = ScanOptions.fromJson({
        'scanGenerateCovers': 'yes',
        'scanGeneratePreviews': 1,
        'paths': ['/media'],
        '__typename': 'ScanMetadataOptions',
      });

      expect(options, const ScanOptions());
      expect(options.toInput().keys, isNot(contains('paths')));
      expect(options.toInput().keys, isNot(contains('__typename')));
    });
  });

  test('toInput sends all eight flags under their wire names', () {
    const options = ScanOptions(generateCovers: true, rescan: true);

    expect(options.toInput(), {
      'scanGenerateCovers': true,
      'scanGeneratePreviews': false,
      'scanGenerateImagePreviews': false,
      'scanGenerateSprites': false,
      'scanGeneratePhashes': false,
      'scanGenerateThumbnails': false,
      'scanGenerateClipPreviews': false,
      'rescan': true,
    });
  });
}
