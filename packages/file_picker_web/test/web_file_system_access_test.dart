@TestOn('browser')
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:file_picker_platform_interface/file_picker_platform_interface.dart';
import 'package:file_picker_web/file_picker_web.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart';

extension on Window {
  @JS('showOpenFilePicker')
  external JSFunction? get showOpenFilePicker;

  @JS('showOpenFilePicker')
  external set showOpenFilePicker(JSFunction? value);
}

@JS('Promise.reject')
external JSPromise<JSObject> _rejectedPromise(JSAny reason);

/// The file handle `showOpenFilePicker()` resolves with when the user picks.
@JSExport()
class _FakeFileHandle {
  _FakeFileHandle({
    required this.name,
    required this.contents,
    this.permission = 'granted',
  });

  final String name;
  final String contents;

  /// What `queryPermission()` and `requestPermission()` report.
  String permission;

  int queryCalls = 0;
  int requestCalls = 0;

  JSPromise<File> getFile() =>
      Future.value(File([utf8.encode(contents).toJS].toJS, name)).toJS;

  JSPromise<JSString> queryPermission(JSObject descriptor) {
    queryCalls++;
    return Future.value(permission.toJS).toJS;
  }

  JSPromise<JSString> requestPermission(JSObject descriptor) {
    requestCalls++;
    permission = 'granted';
    return Future.value(permission.toJS).toJS;
  }
}

/// A [_FakeFileHandle] as the handle type the package works with.
FileSystemFileHandle _fakeHandle(_FakeFileHandle fake) =>
    createJSInteropWrapper(fake) as FileSystemFileHandle;

const String _inputsSelector = 'flt-file-picker-inputs input';

void main() {
  late final FilePickerWeb picker;
  late final JSFunction? originalOpenFilePicker;

  final pickerCalls = <Map<Object?, Object?>>[];

  setUpAll(() {
    FilePickerWeb.registerWith(webPluginRegistrar);
    picker = FilePickerPlatform.instance as FilePickerWeb;
    originalOpenFilePicker = window.showOpenFilePicker;
  });

  setUp(() {
    pickerCalls.clear();
    for (
      var input = document.querySelector(_inputsSelector);
      input != null;
      input = document.querySelector(_inputsSelector)
    ) {
      input.remove();
    }
  });

  tearDown(() {
    window.showOpenFilePicker = originalOpenFilePicker;
  });

  /// Replaces `showOpenFilePicker` with one that records its options and
  /// completes with [respond].
  void stubPicker(JSPromise<JSObject> Function() respond) {
    window.showOpenFilePicker = ((JSObject options) {
      pickerCalls.add(options.dartify()! as Map<Object?, Object?>);
      return respond();
    }).toJS;
  }

  /// Makes `showOpenFilePicker` resolve with [handles].
  void stubPickedHandles(List<_FakeFileHandle> handles) {
    stubPicker(
      () => Future.value(
        [for (final handle in handles) createJSInteropWrapper(handle)].toJS,
      ).toJS,
    );
  }

  /// Makes `showOpenFilePicker` reject with a `DOMException` named [name].
  void stubPickerError(String name) {
    stubPicker(() => _rejectedPromise(DOMException('', name)));
  }

  /// The `<input type="file">` the fallback path attaches, once it does.
  Future<HTMLInputElement> waitForInput() async {
    for (var i = 0; i < 100; i++) {
      final input = document.querySelector(_inputsSelector);
      if (input != null) return input as HTMLInputElement;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('No file input was attached.');
  }

  /// Completes the pending input pick with a file holding [contents].
  Future<void> selectThroughInput(
    Future<Object?> pick, {
    String name = 'picked.txt',
    String contents = 'picked',
  }) async {
    final input = await waitForInput();
    final transfer = DataTransfer()
      ..items.add(File([utf8.encode(contents).toJS].toJS, name));
    input.files = transfer.files;
    input.dispatchEvent(Event('change'));
    await pick;
  }

  const otaTypes = [
    WebFileTypeFilter(
      description: 'OTA package',
      accept: {
        'application/zip': ['.zip'],
      },
    ),
  ];

  test('picks through the file system access dialog', () async {
    stubPickedHandles([_FakeFileHandle(name: 'ota.zip', contents: 'zipdata')]);

    final picked = await picker.pickFile(
      webOptions: const FilePickerWebOptions(
        dialog: WebFileDialog.fileSystemAccess,
        pickerId: 'ota',
        types: otaTypes,
      ),
    );

    expect(picked, isA<WebPlatformFile>());
    final file = picked! as WebPlatformFile;
    expect(file.name, 'ota.zip');
    expect(file.lengthSync(), 7);
    expect(file.handle, isNotNull);
    expect(file.file, isNotNull);
    expect(file.uri.scheme, 'blob');
    expect(utf8.decode(await file.readAsBytes()), 'zipdata');

    // The browser File is what ranged reads go through.
    final range = await file.file!.slice(0, 3).arrayBuffer().toDart;
    expect(utf8.decode(range.toDart.asUint8List()), 'zip');

    expect(pickerCalls.single, {
      'id': 'ota',
      'multiple': false,
      'types': [
        {
          'description': 'OTA package',
          'accept': {
            'application/zip': ['.zip'],
          },
        },
      ],
    });
    expect(document.querySelector(_inputsSelector), isNull);
  });

  test('picks several files through the file system access dialog', () async {
    stubPickedHandles([
      _FakeFileHandle(name: 'a.txt', contents: 'a'),
      _FakeFileHandle(name: 'b.txt', contents: 'b'),
    ]);

    final picked = await picker.pickFiles(
      webOptions: const FilePickerWebOptions(
        dialog: WebFileDialog.fileSystemAccess,
        types: otaTypes,
      ),
    );

    expect(picked.map((file) => file.name), ['a.txt', 'b.txt']);
    expect(pickerCalls.single['multiple'], isTrue);
    for (final file in picked) {
      expect((file as WebPlatformFile).handle, isNotNull);
      expect(utf8.decode(await file.readAsBytes()), file.name.substring(0, 1));
    }
  });

  test('returns null when the user cancels the dialog', () async {
    stubPickerError('AbortError');

    expect(
      await picker.pickFile(
        webOptions: const FilePickerWebOptions(
          dialog: WebFileDialog.fileSystemAccess,
          types: otaTypes,
        ),
      ),
      isNull,
    );
    expect(pickerCalls, hasLength(1));
    // A cancel is not a refused dialog: nothing falls back to the input.
    expect(document.querySelector(_inputsSelector), isNull);
  });

  test('falls back to the input when the browser refuses the dialog', () async {
    stubPickerError('SecurityError');

    final pick = picker.pickFile(
      webOptions: const FilePickerWebOptions(
        dialog: WebFileDialog.auto,
        types: otaTypes,
      ),
    );
    await selectThroughInput(pick);

    final picked = (await pick)! as WebPlatformFile;
    expect(picked.name, 'picked.txt');
    expect(picked.handle, isNull);
    expect(pickerCalls, hasLength(1));
  });

  test('keeps the input filter when no types are given', () async {
    stubPickedHandles([_FakeFileHandle(name: 'ota.zip', contents: 'zip')]);

    // `type`/`allowedExtensions` only filter the input, so `auto` keeps it
    // rather than opening a dialog that accepts every file.
    final pick = picker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      webOptions: const FilePickerWebOptions(dialog: WebFileDialog.auto),
    );
    await selectThroughInput(pick, name: 'ota.zip', contents: 'zip');

    expect(((await pick)! as WebPlatformFile).handle, isNull);
    expect(pickerCalls, isEmpty);
  });

  test('accepts every file through the dialog without a filter', () async {
    stubPickedHandles([_FakeFileHandle(name: 'any.bin', contents: 'x')]);

    final picked = await picker.pickFile(
      webOptions: const FilePickerWebOptions(dialog: WebFileDialog.auto),
    );

    expect(picked!.name, 'any.bin');
    expect(pickerCalls.single, {'multiple': false});
  });

  test('uses the input without asking for the dialog', () async {
    stubPickedHandles([_FakeFileHandle(name: 'ota.zip', contents: 'zip')]);

    // The dialog has to be asked for, so a plain pick keeps what every
    // browser has.
    final pick = picker.pickFile(
      webOptions: const FilePickerWebOptions(types: otaTypes),
    );
    await selectThroughInput(pick);

    expect(((await pick)! as WebPlatformFile).handle, isNull);
    expect(pickerCalls, isEmpty);
  });

  test('uses the input when WebFileDialog.input is asked for', () async {
    stubPickedHandles([_FakeFileHandle(name: 'ota.zip', contents: 'zip')]);

    final pick = picker.pickFile(
      webOptions: const FilePickerWebOptions(dialog: WebFileDialog.input),
    );
    await selectThroughInput(pick);

    expect(((await pick)! as WebPlatformFile).handle, isNull);
    expect(pickerCalls, isEmpty);
  });

  test('uses the input when the browser has no dialog', () async {
    window.showOpenFilePicker = null;

    expect(supportsShowOpenFilePicker, isFalse);
    final pick = picker.pickFile(
      webOptions: const FilePickerWebOptions(
        dialog: WebFileDialog.auto,
        types: otaTypes,
      ),
    );
    await selectThroughInput(pick);

    expect(((await pick)! as WebPlatformFile).handle, isNull);
  });

  test('throws without a dialog to use when it is required', () async {
    window.showOpenFilePicker = null;

    await expectLater(
      picker.pickFile(
        webOptions: const FilePickerWebOptions(
          dialog: WebFileDialog.fileSystemAccess,
          types: otaTypes,
        ),
      ),
      throwsUnsupportedError,
    );
    expect(document.querySelector(_inputsSelector), isNull);
  });

  test('throws without types when the dialog is required', () async {
    stubPickedHandles([_FakeFileHandle(name: 'ota.zip', contents: 'zip')]);

    await expectLater(
      picker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['zip'],
        webOptions: const FilePickerWebOptions(
          dialog: WebFileDialog.fileSystemAccess,
        ),
      ),
      throwsArgumentError,
    );
    expect(pickerCalls, isEmpty);
  });

  test('reports support when the dialog is available', () {
    stubPickerError('AbortError');

    expect(supportsShowOpenFilePicker, isTrue);
  });

  group('WebPlatformFile', () {
    /// A real handle, from the origin private file system, so IndexedDB can
    /// store it and `getFile()` reads actual content.
    Future<FileSystemFileHandle> storedHandle(
      String name, {
      required String contents,
    }) async {
      final root = await window.navigator.storage.getDirectory().toDart;
      final handle = await root
          .getFileHandle(name, FileSystemGetFileOptions(create: true))
          .toDart;
      final writable = await handle.createWritable().toDart;
      await writable
          .write(Uint8List.fromList(utf8.encode(contents)).toJS)
          .toDart;
      await writable.close().toDart;
      return handle;
    }

    test('keeps a picked file readable without a handle', () async {
      final file = WebPlatformFile(
        name: 'picked.txt',
        file: File([utf8.encode('picked').toJS].toJS, 'picked.txt'),
      );

      expect(await file.hasAccess(), isTrue);
      expect(await file.requestAccess(), isTrue);
      expect(utf8.decode(await file.readAsBytes()), 'picked');
      expect(await file.persist(), isNull);
      expect(file.uri.scheme, 'blob');
    });

    test('persists, restores and forgets a handle', () async {
      final handle = await storedHandle('remembered.zip', contents: 'hello');
      final file = WebPlatformFile(name: handle.name, handle: handle);

      final token = await file.persist();
      expect(token, isNotNull);
      expect(token, hasLength(32));

      // The same file gets the same token instead of piling up records.
      expect(await file.persist(), token);
      expect(await WebPlatformFile.persistHandle(handle), token);

      final restored = await WebPlatformFile.restore(token!);
      expect(restored, isNotNull);
      expect(restored!.name, 'remembered.zip');
      expect(restored.handle, isNotNull);
      expect(restored.file, isNotNull);
      expect(restored.lengthSync(), 5);
      expect(utf8.decode(await restored.readAsBytes()), 'hello');

      await WebPlatformFile.forget(token);
      expect(await WebPlatformFile.restore(token), isNull);

      // Forgetting an unknown token is not an error.
      await WebPlatformFile.forget(token);
    });

    test('restores nothing for an unknown token', () async {
      expect(await WebPlatformFile.restore('0' * 32), isNull);
    });

    test('reads a file restored without access once it is granted', () async {
      final fake = _FakeFileHandle(
        name: 'locked.zip',
        contents: 'zip',
        permission: 'prompt',
      );
      final file = WebPlatformFile(name: fake.name, handle: _fakeHandle(fake));

      expect(file.file, isNull);
      expect(file.uri, Uri());
      expect(file.lengthSync(), isNull);
      expect(await file.hasAccess(), isFalse);
      expect(fake.queryCalls, 1);

      expect(await file.requestAccess(), isTrue);
      expect(fake.requestCalls, 1);

      final read = await file.getFile();
      expect(read.name, 'locked.zip');
      expect(file.file, isNotNull);
      expect(file.lengthSync(), 3);
      expect(utf8.decode(await file.readAsBytes()), 'zip');
    });
  });
}
