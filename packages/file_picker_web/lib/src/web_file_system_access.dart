/// @docImport 'file_picker_web.dart';
/// @docImport 'web_platform_file.dart';
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart';

import 'file_picker_web_options.dart';

// `showOpenFilePicker()`, and the `queryPermission()`/`requestPermission()`
// methods of the handles it returns, are not part of package:web, since they
// are experimental APIs.
//
// See https://developer.mozilla.org/en-US/docs/Web/API/Window/showOpenFilePicker#browser_compatibility
@JS('showOpenFilePicker')
external JSFunction? get _showOpenFilePickerFunction;

/// Whether the browser supports the `showOpenFilePicker` API.
///
/// Only Chromium based browsers do, and only in a secure context and outside a
/// cross-origin iframe. This is the same check [FilePickerWeb.pickFile] and
/// [FilePickerWeb.pickFiles] make for `WebFileDialog.auto`; use it to decide
/// whether to offer [WebFileDialog.fileSystemAccess], which throws an
/// [UnsupportedError] where the API is missing.
bool get supportsShowOpenFilePicker => _showOpenFilePickerFunction != null;

@JS('showOpenFilePicker')
external JSPromise<JSArray<FileSystemFileHandle>> _showOpenFilePicker(
  JSObject options,
);

/// Opens the browser's open dialog and returns the picked handles, or `null`
/// when the user cancels it.
///
/// [types] filters the dialog, [pickerId] is the `id` the browser keys its
/// remembered folder on, and [multiple] allows picking more than one file.
///
/// Browsers restrict this to a user gesture, so it must be called from an
/// event handler with nothing awaited before it, or Chrome throws a
/// `SecurityError`. That, and every other failure, is thrown as the browser
/// reports it.
Future<List<FileSystemFileHandle>?> showFileSystemAccessPicker({
  List<WebFileTypeFilter> types = const <WebFileTypeFilter>[],
  String? pickerId,
  bool multiple = false,
}) async {
  if (!supportsShowOpenFilePicker) {
    throw UnsupportedError(
      'This browser does not support the showOpenFilePicker API.',
    );
  }

  final options = JSObject()..['multiple'] = multiple.toJS;
  if (pickerId != null) options['id'] = pickerId.toJS;
  if (types.isNotEmpty) {
    options['types'] = [for (final type in types) _acceptType(type)].toJS;
  }

  try {
    final handles = await _showOpenFilePicker(options).toDart;
    return handles.toDart;
  } catch (e) {
    if (e case DOMException(name: 'AbortError')) return null;
    rethrow;
  }
}

/// The `types` entry of the dialog options, built from [type].
///
/// `description` is left out when empty, so the browser labels the type itself
/// instead of showing an empty line.
JSObject _acceptType(WebFileTypeFilter type) {
  final entry = JSObject()..['accept'] = type.accept.jsify()!;
  if (type.description.isNotEmpty) {
    entry['description'] = type.description.toJS;
  }
  return entry;
}

/// What the page asks a handle to allow.
enum FilePermissionMode {
  /// Read the file's content, which is what picking gives a handle.
  read('read'),

  /// Read and write the file's content, which a handle the user chose to save
  /// to needs before it can be replaced.
  readWrite('readwrite');

  const FilePermissionMode(this.descriptor);

  /// The `mode` of the descriptor the browser's permission methods take.
  final String descriptor;
}

/// The descriptor [hasPermission] and [requestPermission] take for [mode].
JSObject _mode(FilePermissionMode mode) =>
    JSObject()..['mode'] = mode.descriptor.toJS;

/// Whether the page has [mode] access to [handle] now, without asking the
/// user.
///
/// A handle from `showOpenFilePicker()` or `showSaveFilePicker()` has it. One
/// loaded back from a token keeps it only while another tab of the site still
/// has it, or when the user chose to allow it on every visit. Otherwise call
/// [requestPermission] from a button.
///
/// [FilePermissionMode.readWrite] is about the file's content: a handle the
/// user picked to save to reports it as granted only while the page may
/// replace that content.
///
/// Browsers without `queryPermission()`, such as Firefox and Safari, return
/// `true`: they have no `showOpenFilePicker()` either, so a handle they give
/// out can only come from the origin private file system, which is the site's
/// own storage and needs no permission. `false` there would make an app show
/// an "allow access" button that can never succeed.
///
/// It is about permission only: a file that was deleted still returns `true`,
/// and reading it throws a `NotFoundError`.
Future<bool> hasPermission(
  FileSystemFileHandle handle, {
  FilePermissionMode mode = FilePermissionMode.read,
}) async {
  if (!handle.has('queryPermission')) return true;
  final state = await handle
      .callMethod<JSPromise<JSString>>('queryPermission'.toJS, _mode(mode))
      .toDart;
  return state.toDart == 'granted';
}

/// Asks the user for [mode] access to [handle] if the page doesn't have it
/// yet, and returns whether it has it now.
///
/// The browser only shows the prompt for a user gesture, so call it from a
/// click handler with nothing awaited before it. Returns `false` when the user
/// denies access, and throws the browser's own error when the prompt could not
/// be shown at all.
///
/// Browsers without `requestPermission()` return `true` without a prompt, for
/// the same reason as [hasPermission].
Future<bool> requestPermission(
  FileSystemFileHandle handle, {
  FilePermissionMode mode = FilePermissionMode.read,
}) async {
  if (!handle.has('requestPermission')) return true;
  final state = await handle
      .callMethod<JSPromise<JSString>>('requestPermission'.toJS, _mode(mode))
      .toDart;
  return state.toDart == 'granted';
}
