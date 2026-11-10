import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:file_picker_platform_interface/file_picker_platform_interface.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:path/path.dart' as p;
import 'package:web/web.dart';

import 'file_picker_web_options.dart';
import 'indexed_task_runner.dart';
import 'platform_file_web_fetch.dart';
import 'preload_policy.dart';
import 'save_file_dialog.dart';
import 'web_file_input_session.dart';
import 'web_file_system_access.dart';
import 'web_platform_file.dart';

/// An implementation of [FilePickerPlatform] for the Web platform.
///
/// Uses standard HTML5 `<input type="file">` element interop via `package:web`
/// to provide single and multiple file picking, as well as file saving capabilities
/// in browser environments.
///
/// Where the browser has `showOpenFilePicker()`, picking can go through its
/// file system access dialog instead, see [FilePickerWebOptions.dialog]. The
/// picked files then keep a handle, which [WebPlatformFile.persist] can store
/// to remember them across page loads.
class FilePickerWeb extends FilePickerPlatform {
  static const String _kFilePickerInputsDomId = '__file_picker_web-file-input';

  late Element _target;

  FilePickerWeb._() {
    _target = _ensureInitialized(_kFilePickerInputsDomId);
  }

  /// Registers this class as the default instance of [FilePickerPlatform].
  static void registerWith(Registrar registrar) {
    FilePickerPlatform.instance = FilePickerWeb._();
  }

  /// Initializes a DOM container element where input elements can be appended.
  Element _ensureInitialized(String id) {
    Element? target = document.querySelector('#$id');
    if (target == null) {
      final Element targetElement = document.createElement(
        'flt-file-picker-inputs',
      )..id = id;

      document.body!.appendChild(targetElement);
      target = targetElement;
    }
    return target;
  }

  /// Directory picking is not supported on web platforms.
  ///
  /// Always throws an [UnsupportedError].
  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    throw UnsupportedError('getDirectoryPath() is not supported on Web.');
  }

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    final files = await _pickFiles(
      type: type,
      allowedExtensions: allowedExtensions,
      onFileLoading: onFileLoading,
      webOptions: webOptions,
      allowMultiple: false,
    );
    return files.firstOrNull;
  }

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) {
    return _pickFiles(
      type: type,
      allowedExtensions: allowedExtensions,
      onFileLoading: onFileLoading,
      webOptions: webOptions,
      allowMultiple: true,
    );
  }

  Future<List<PlatformFile>> _pickFiles({
    required FileType type,
    required List<String>? allowedExtensions,
    required Function(FilePickerStatus)? onFileLoading,
    required WebOptions webOptions,
    required bool allowMultiple,
  }) async {
    if (type == FileType.custom &&
        (allowedExtensions == null || allowedExtensions.isEmpty)) {
      throw ArgumentError(
        'If type is set to FileType.custom, allowedExtensions cannot be null or empty.',
      );
    }

    final FilePickerWebOptions effectiveWebOptions =
        webOptions is FilePickerWebOptions
        ? webOptions
        : const FilePickerWebOptions();

    if (_usesFileSystemAccess(effectiveWebOptions, type)) {
      final List<PlatformFile>? picked = await _pickWithFileSystemAccess(
        webOptions: effectiveWebOptions,
        type: type,
        onFileLoading: onFileLoading,
        allowMultiple: allowMultiple,
      );
      if (picked != null) return picked;
    }

    final session = WebFileInputSession(
      target: _target,
      accept: _fileType(type, allowedExtensions),
      allowMultiple: allowMultiple,
      webOptions: effectiveWebOptions,
      onFileLoading: onFileLoading,
      processFiles: _processSelectedFiles,
    );

    final List<PlatformFile>? files = await session.start();
    return files ?? <PlatformFile>[];
  }

  /// Whether this pick opens the browser's file system access dialog.
  ///
  /// It is synchronous on purpose: [_pickFiles] decides before its first
  /// `await`, so a pick that stays on `<input type="file">` still attaches the
  /// input element in the caller's own task, where the click that opened the
  /// picker is still recent.
  static bool _usesFileSystemAccess(
    FilePickerWebOptions webOptions,
    FileType type,
  ) {
    return switch (webOptions.dialog) {
      // Asking for the dialog keeps asking, so the pick reports why it cannot
      // be shown rather than silently picking through the input.
      WebFileDialog.fileSystemAccess => true,
      WebFileDialog.input => false,
      // The dialog can only be filtered with `types`, while every other [type]
      // has an `accept` the input understands and the dialog has no equivalent
      // for, so such a pick keeps the input instead of accepting every file.
      WebFileDialog.auto =>
        supportsShowOpenFilePicker &&
            (webOptions.types.isNotEmpty || type == FileType.any),
    };
  }

  /// Picks through the browser's file system access dialog, or returns `null`
  /// when the browser refused to open it and this pick has to go through
  /// `<input type="file">` instead.
  ///
  /// Returns an empty list when the user cancels the dialog.
  Future<List<PlatformFile>?> _pickWithFileSystemAccess({
    required FilePickerWebOptions webOptions,
    required FileType type,
    required Function(FilePickerStatus)? onFileLoading,
    required bool allowMultiple,
  }) async {
    final dialog = webOptions.dialog;
    if (!supportsShowOpenFilePicker) {
      throw UnsupportedError(
        'This browser does not support the showOpenFilePicker API.',
      );
    }
    if (webOptions.types.isEmpty && type != FileType.any) {
      throw ArgumentError(
        'FilePickerWebOptions.types is required to filter the file system '
        'access dialog. Use WebFileDialog.input to filter with type or '
        'allowedExtensions instead.',
      );
    }

    final List<FileSystemFileHandle>? handles;
    try {
      onFileLoading?.call(FilePickerStatus.picking);
      handles = await showFileSystemAccessPicker(
        types: webOptions.types,
        pickerId: webOptions.pickerId,
        multiple: allowMultiple,
      );
    } catch (_) {
      // The browser refused to open it, typically because there was no recent
      // user gesture, and the input falls back to its own handling of that.
      if (dialog == WebFileDialog.fileSystemAccess) rethrow;
      return null;
    }

    if (handles == null) return <PlatformFile>[];

    try {
      return await _processHandles(handles, webOptions);
    } finally {
      onFileLoading?.call(FilePickerStatus.done);
    }
  }

  /// Converts the picked [handles] to [PlatformFile]s, keeping each handle on
  /// the file it belongs to.
  ///
  /// Reads files one at a time when [FilePickerWebOptions.readSequential] is
  /// `true`, or concurrently otherwise; either way the result preserves the
  /// original selection order.
  Future<List<PlatformFile>> _processHandles(
    List<FileSystemFileHandle> handles,
    FilePickerWebOptions webOptions,
  ) async {
    Future<PlatformFile?> processHandleAt(int index) async {
      final handle = handles[index];
      return _processFile(
        await handle.getFile().toDart,
        handle: handle,
        webOptions: webOptions,
      );
    }

    final results = await runIndexedTasks(
      handles.length,
      processHandleAt,
      sequential: webOptions.readSequential,
    );
    return results.whereType<PlatformFile>().toList();
  }

  /// Processes the selected [FileList] according to [webOptions] and returns
  /// a list of [PlatformFile] instances.
  ///
  /// Reads files one at a time when [FilePickerWebOptions.readSequential] is
  /// `true`, or concurrently otherwise; either way the result preserves the
  /// original selection order.
  Future<List<PlatformFile>> _processSelectedFiles(
    FileList files,
    FilePickerWebOptions webOptions,
  ) async {
    Future<PlatformFile?> processFileAt(int index) async {
      final file = files.item(index);
      if (file == null) return null;
      return _processFile(file, webOptions: webOptions);
    }

    final results = await runIndexedTasks(
      files.length,
      processFileAt,
      sequential: webOptions.readSequential,
    );
    return results.whereType<PlatformFile>().toList();
  }

  /// Converts one picked browser [file] to a [PlatformFile] according to
  /// [webOptions], keeping the [handle] it was picked through, if any.
  Future<PlatformFile> _processFile(
    File file, {
    FileSystemFileHandle? handle,
    required FilePickerWebOptions webOptions,
  }) async {
    if (webOptions.withReadStream) {
      return _createWebPlatformFile(
        file: file,
        handle: handle,
        readStream: streamBlobInChunks(file),
      );
    }

    if (!shouldPreloadBytes(file.size, withData: webOptions.withData)) {
      return _createWebPlatformFile(file: file, handle: handle);
    }

    final bytes = await _readSingleFileBytes(file);
    return _createWebPlatformFile(file: file, handle: handle, bytes: bytes);
  }

  /// Reads an HTML [File] content into a [Uint8List] using [FileReader].
  Future<Uint8List?> _readSingleFileBytes(File file) async {
    final completer = Completer<Uint8List?>();
    final reader = FileReader();

    reader.addEventListener(
      'loadend',
      ((Event _) {
        if (!completer.isCompleted) {
          final byteBuffer = (reader.result as JSArrayBuffer?)?.toDart;
          completer.complete(byteBuffer?.asUint8List());
        }
      }).toJS,
    );

    reader.addEventListener(
      'error',
      ((Event _) {
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      }).toJS,
    );

    reader.readAsArrayBuffer(file);
    return completer.future;
  }

  /// Creates a [WebPlatformFile] from an HTML [File], resolving its `blob:` URI.
  ///
  /// The URI always points at the picked [file] itself, which avoids creating a copy.
  WebPlatformFile _createWebPlatformFile({
    required File file,
    FileSystemFileHandle? handle,
    Uint8List? bytes,
    Stream<Uint8List>? readStream,
  }) {
    return WebPlatformFile(
      name: file.name,
      uri: Uri.parse(URL.createObjectURL(file)),
      file: file,
      handle: handle,
      bytesLength: bytes != null ? bytes.length : file.size,
      bytes: bytes,
      readStream: readStream,
    );
  }

  /// Saves [bytes] as [fileName] with the given [mimeType].
  ///
  /// By default it triggers a browser download and returns `null`. With
  /// `FilePickerWebOptions(saveMode: WebSaveFileMode.dialog)` it opens the
  /// browser's save dialog instead, and returns a [Uri] whose path is the
  /// file name the user chose, since browsers do not expose the folder, or
  /// `null` if the user cancelled. That [Uri] has no scheme, so it is not a
  /// valid file system or network location (no `file`, `http(s)`, `data` or
  /// `blob` [Uri]) and cannot be used to read the file back.
  ///
  /// Throws an [UnsupportedError] if the browser does not support the dialog,
  /// see [supportsShowSaveFileDialog]. Falls back to the download if the
  /// browser refuses to open it, typically without a recent user gesture.
  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    if (bytes.isEmpty) {
      throw ArgumentError(
        'The bytes are required when saving a file on the web.',
      );
    }

    if (fileName.isEmpty) {
      throw ArgumentError(
        'A file name is required when saving a file on the web.',
      );
    }

    if (p.extension(fileName).isEmpty) {
      throw ArgumentError(
        'The file name should include a valid file extension.',
      );
    }

    if (webOptions is FilePickerWebOptions &&
        webOptions.saveMode == WebSaveFileMode.dialog) {
      final dialog = await saveWithDialog(
        fileName: fileName,
        bytes: bytes,
        mimeType: mimeType,
      );
      if (dialog.shown) {
        final name = dialog.name;
        return name == null ? null : Uri(path: name);
      }
    }

    final blob = Blob([bytes.toJS].toJS, BlobPropertyBag(type: mimeType));
    final url = URL.createObjectURL(blob);

    HTMLAnchorElement()
      ..href = url
      ..target = 'blank'
      ..download = fileName
      ..click();

    URL.revokeObjectURL(url);
    return null;
  }

  /// Converts a [FileType] enum and [allowedExtensions] list into an HTML
  /// `accept` attribute string.
  static String _fileType(FileType type, List<String>? allowedExtensions) {
    return switch (type) {
      FileType.any => '',
      FileType.audio => 'audio/*',
      FileType.image => 'image/*',
      FileType.video => 'video/*',
      FileType.media => 'video/*,image/*',
      FileType.custom => allowedExtensions!.fold(
        '',
        (prev, next) => '${prev.isEmpty ? '' : '$prev,'} .$next',
      ),
    };
  }
}
