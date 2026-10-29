import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:screen_aware_ai/services/screen_capture_service.dart';
import 'package:screen_aware_ai/services/local_model_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalModelService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    service = LocalModelService(ScreenCaptureManager());
    await service.initialize();
  });

  group('LocalModelService binary GGUF parsing tests', () {
    test('parses valid GGUF header magic and version', () async {
      // Create synthetic GGUF byte buffer
      // GGUF magic bytes: 'G' (0x47), 'G' (0x47), 'U' (0x55), 'F' (0x46)
      // Version: 3 (0x03, 0x00, 0x00, 0x00 little endian uint32)
      // Tensor count: 100 uint64
      // Metadata count: 12 uint64
      final bytes = BytesBuilder();
      bytes.add([0x47, 0x47, 0x55, 0x46]); // Magic "GGUF"
      bytes.add([0x03, 0x00, 0x00, 0x00]); // Version 3
      bytes.add([100, 0, 0, 0, 0, 0, 0, 0]); // 100 tensors
      bytes.add([12, 0, 0, 0, 0, 0, 0, 0]); // 12 metadata entries

      final header = LocalModelService.parseGgufHeader(bytes.toBytes());
      expect(header, isNotNull);
      expect(header!.version, equals(3));
      expect(header.tensorCount, equals(100));
      expect(header.metadataCount, equals(12));
      expect(header.toString(), contains('GGUF v3'));
    });

    test('rejects non-GGUF file header', () {
      final badBytes = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07];
      final header = LocalModelService.parseGgufHeader(badBytes);
      expect(header, isNull);
    });
  });

  group('LocalModelService configuration & state tests', () {
    test('default settings and thread configuration', () async {
      expect(service.threads, equals(4));
      expect(service.contextSize, equals(2048));
      expect(service.maxTokens, equals(512));
      expect(service.temperature, equals(0.2));

      await service.setThreads(6);
      expect(service.threads, equals(6));

      await service.setThreads(8);
      expect(service.threads, equals(8));

      expect(() => service.setThreads(16), throwsArgumentError);
      expect(() => service.setThreads(0), throwsArgumentError);
    });

    test('clearing model resets state to noModelSelected', () async {
      await service.clearModel();
      expect(service.state, equals(LocalModelState.noModelSelected));
      expect(service.hasSelectedModel, isFalse);
      expect(service.isReady, isFalse);
      expect(service.selectedModelPath, isNull);
    });

    test('test inference when unloaded throws StateError', () async {
      expect(() => service.runTestInference(), throwsA(isA<StateError>()));
    });
  });
}
