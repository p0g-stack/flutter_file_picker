import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker_platform_interface/file_picker_platform_interface.dart';
import 'package:web/web.dart';

import 'platform_file_web_fetch.dart';
import 'web_file_system_access.dart';
import 'web_handle_store.dart';

/// A Web-specific implementation of [PlatformFile].
///
/// Wraps files selected or processed in a web environment, providing
/// access to file metadata, underlying bytes, stream readers, and `blob:` or
/// `data:` URIs.
base class WebPlatformFile extends PlatformFile {
  /// Creates a new [WebPlatformFile] instance.
  ///
  /// Requires a file [name]. Optional parameters include the browser [file]
  /// behind it, the [handle] it was picked through, a [uri], preloaded
  /// [bytes], a custom [readStream], file size in [bytesLength], or an
  /// underlying [xFile].
  WebPlatformFile({
    required this.name,
    Uri? uri,
    XFile? xFile,
    int? bytesLength,
    Uint8List? bytes,
    Stream<Uint8List>? readStream,
    File? file,
    FileSystemFileHandle? handle,
  }) : _uri = uri,
       _file = file,
       _handle = handle,
       _xFile = xFile,
       _bytesLength = bytesLength,
       _bytes = bytes,
       _readStream = readStream {
    if (name.isEmpty) {
      throw ArgumentError('name cannot be empty');
    }
  }

  /// The name of the file including extension.
  @override
  final String name;

  /// The web URI representing this file (typically a `blob:` or `data:` URL).
  ///
  /// It is created from [file] on first use, so it is empty for a file
  /// restored from a token that the page has not been granted access to yet;
  /// call [requestAccess] and [getFile] first.
  @override
  Uri get uri {
    final cached = _uri;
    if (cached != null) return cached;

    final file = _file;
    if (file == null) return Uri();
    return _uri = Uri.parse(URL.createObjectURL(file));
  }

  @override
  String? get path => null;

  /// The browser's [File] behind this pick, the object `slice()` reads ranges
  /// from without loading the whole file.
  ///
  /// It is set for every file picked through the file system access dialog,
  /// and for a file restored from a token once the page has access to it.
  /// It is `null` before [getFile] for a restored file whose access still has
  /// to be granted with [requestAccess].
  File? get file => _file;

  /// The file system access handle this file was picked or restored through,
  /// or `null` when it came from `<input type="file">`.
  ///
  /// Only a handle can be persisted, see [persist].
  FileSystemFileHandle? get handle => _handle;

  Uri? _uri;
  File? _file;
  final FileSystemFileHandle? _handle;
  final XFile? _xFile;
  int? _bytesLength;
  final Uint8List? _bytes;
  final Stream<Uint8List>? _readStream;

  /// Whether the page has [mode] access to this file now, without asking the
  /// user.
  ///
  /// A file from `<input type="file">` is always readable, since the browser
  /// already handed its content over. A persisted file keeps its read access
  /// only while another tab of the site has it, or when the user chose to allow
  /// it on every visit, so pass a restored one through this before reading it.
  ///
  /// [FilePermissionMode.readWrite] asks whether the file's content can be
  /// replaced instead, which a file the user picked to save to needs before a
  /// second save writes over it.
  Future<bool> hasAccess({
    FilePermissionMode mode = FilePermissionMode.read,
  }) async {
    final handle = _handle;
    if (handle == null) return true;
    return hasPermission(handle, mode: mode);
  }

  /// Asks the user for [mode] access to this file if the page doesn't have it
  /// yet, and returns whether it has it now.
  ///
  /// The browser only shows the prompt for a user gesture, so call it from a
  /// click handler with nothing awaited before it. Returns `false` when the
  /// user denies access.
  Future<bool> requestAccess({
    FilePermissionMode mode = FilePermissionMode.read,
  }) async {
    final handle = _handle;
    if (handle == null) return true;
    return requestPermission(handle, mode: mode);
  }

  /// Reads this file through its [handle] and returns the browser's [File].
  ///
  /// Returns the file already held when there is one, and otherwise the current
  /// content on disk, which needs read access. Throws the browser's error when
  /// the page has none, or when the file was deleted or moved.
  Future<File> getFile() async {
    final file = _file;
    if (file != null) return file;

    final handle = _handle;
    if (handle == null) {
      throw StateError('This file was not picked through a handle.');
    }

    final read = await handle.getFile().toDart;
    _file = read;
    _bytesLength = read.size;
    return read;
  }

  /// Stores this file's [handle] and returns a token for [restore].
  ///
  /// Returns `null` for a file picked through `<input type="file">`, which
  /// cannot be remembered. Picking the same file again returns the same token.
  Future<String?> persist() async {
    final handle = _handle;
    if (handle == null) return null;
    return persistHandle(handle);
  }

  /// Stores [handle] and returns a token for [restore].
  ///
  /// For a handle that did not come from a pick, such as one the page received
  /// from a drag and drop or from the installed app's file handler. A file that
  /// is already stored keeps its token instead of adding a record.
  static Future<String> persistHandle(FileSystemFileHandle handle) =>
      storeHandle(handle);

  /// The file stored under [token], or `null` when there is none.
  ///
  /// A file the page may no longer read still comes back, with its [name] and
  /// [handle] but no [file], so an app can offer to renew the access with
  /// [requestAccess] from a click instead of asking for the file again.
  static Future<WebPlatformFile?> restore(String token) async {
    final handle = await loadHandle(token);
    if (handle == null) return null;

    final file = WebPlatformFile(name: handle.name, handle: handle);
    if (!await file.hasAccess()) return file;

    // Read it now, so a restored file is as usable as a picked one. A record
    // whose file was deleted or moved since it was stored is reported as gone,
    // and left for the app to forget.
    try {
      await file.getFile();
    } catch (_) {
      return null;
    }
    return file;
  }

  /// Drops the file stored under [token], if any.
  ///
  /// A [WebPlatformFile] already restored from it keeps its [handle] and stays
  /// readable for as long as the page has access to it.
  static Future<void> forget(String token) => deleteHandle(token);

  /// Returns an [XFile] instance representing this web file.
  @override
  XFile get xFile {
    final file = _xFile;
    if (file != null) return file;
    return XFile(uri.toString(), name: name, bytes: _bytes);
  }

  /// The browser's `File.size`, or the loaded bytes' length.
  @override
  int? lengthSync() {
    return _bytesLength ?? _bytes?.length;
  }

  /// Asynchronously calculates and returns the size of the file in bytes.
  @override
  Future<int?> length() async {
    final len = _bytesLength;
    if (len != null) return len;
    final bytes = _bytes;
    if (bytes != null) return bytes.length;
    try {
      return await xFile.length();
    } catch (_) {
      return null;
    }
  }

  /// Asynchronously reads the file content as a byte array (`Uint8List`).
  ///
  /// If bytes are cached or readable from a `blob:`/`data:` URL, they will be
  /// retrieved directly; otherwise falls back to [xFile].
  ///
  /// A file restored from a token is read through its [handle], which needs
  /// read access, and throws the browser's error when the page has none.
  @override
  Future<Uint8List> readAsBytes() async {
    final bytes = _bytes;
    if (bytes != null) return bytes;

    await _resolveFile();

    // Try fetching from blob or data URL
    final fetched = await fetchBytesFromWebPath(uri.toString());
    if (fetched != null) return fetched;

    return xFile.readAsBytes();
  }

  /// The size of the chunks emitted by [readAsByteStream].
  static const int streamChunkSize = webStreamChunkSize;

  /// Asynchronously opens a stream to read the file content in chunks.
  ///
  /// Every chunk is [streamChunkSize] bytes long except the last one, which
  /// may be shorter, so consumers can rely on evenly sized buffers.
  @override
  Stream<Uint8List> readAsByteStream() async* {
    final readStream = _readStream;
    if (readStream != null) {
      yield* readStream;
      return;
    }

    await _resolveFile();

    final webStream = fetchStreamFromWebPath(uri.toString());
    if (webStream != null) {
      yield* webStream;
      return;
    }

    yield* xFile.openRead();
  }

  /// Reads the content through [_handle] the first time it is needed.
  Future<void> _resolveFile() async {
    if (_file == null && _handle != null) await getFile();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is WebPlatformFile && other.name == name && other.uri == uri;
  }

  @override
  int get hashCode => Object.hash(name, uri);

  @override
  String toString() {
    return 'WebPlatformFile(name: $name, uri: $uri)';
  }
}
