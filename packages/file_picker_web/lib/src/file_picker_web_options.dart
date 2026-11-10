/// @docImport 'file_picker_web.dart';
/// @docImport 'web_platform_file.dart';
library;

import 'package:file_picker_platform_interface/file_picker_platform_interface.dart';

/// How [FilePickerWeb.pickFile] and [FilePickerWeb.pickFiles] open the
/// browser's open dialog on the web.
enum WebFileDialog {
  /// Uses `<input type="file">`, which is what picking did before
  /// [FilePickerWebOptions.dialog] existed: the file system access dialog is
  /// only used when it is asked for.
  ///
  /// Picked files have no [WebPlatformFile.handle], so they can't be
  /// persisted, and only exist for as long as the page does.
  input,

  /// Uses the file system access dialog where the browser has one and the pick
  /// can be filtered with [FilePickerWebOptions.types], and `<input
  /// type="file">` everywhere else.
  ///
  /// The picked file then carries a handle, which [WebPlatformFile.persist]
  /// can store, and both [WebPlatformFile.hasAccess] and
  /// [WebPlatformFile.requestAccess] work on its content. It falls back to the
  /// input when the browser refuses to open the dialog, typically because
  /// there was no recent user gesture.
  auto,

  /// Always uses the file system access dialog, and throws an
  /// [UnsupportedError] where the browser has none, or an [ArgumentError] when
  /// the pick has no [FilePickerWebOptions.types] to filter it with.
  fileSystemAccess,
}

/// A file type the file system access dialog accepts, as a
/// [FilePickerWebOptions.types] entry.
final class WebFileTypeFilter {
  /// Creates a filter for the given [accept] map and optional [description].
  const WebFileTypeFilter({required this.accept, this.description = ''});

  /// The MIME types this filter accepts, mapped to the file extensions each
  /// one covers, such as `{'application/zip': ['.zip']}`.
  ///
  /// The dialog checks every listed extension against its MIME type, so a
  /// mismatched pair leaves the filter empty. Extensions include the leading
  /// dot, unlike `allowedExtensions`.
  final Map<String, List<String>> accept;

  /// The label the dialog shows for this filter.
  final String description;
}

/// How [FilePickerWeb.saveFile] saves the file on the web.
enum WebSaveFileMode {
  /// Downloads the file, which most browsers drop into the Downloads folder
  /// without asking for a location or a name.
  download,

  /// Opens the browser's save dialog, so the user picks the folder and the
  /// file name.
  dialog,
}

/// Configuration options specific to the Web platform.
final class FilePickerWebOptions extends WebOptions {
  /// Whether to read each picked file into memory at pick time.
  ///
  /// Files larger than 2 GB are never preloaded, since browsers cannot hold
  /// them in a single buffer. Their content can be read on demand through
  /// `PlatformFile.readAsBytes()` and `readAsByteStream()` instead.
  @Deprecated(
    'Picked files are read on demand by PlatformFile.readAsBytes() and '
    'readAsByteStream(). This option will be removed in file_picker v14.0.0.',
  )
  final bool withData;

  /// Whether to create a read stream for each picked file.
  @Deprecated(
    'PlatformFile.readAsByteStream() already reads on demand in evenly sized '
    'chunks. This option will be removed in file_picker v14.0.0.',
  )
  final bool withReadStream;

  /// Whether to read multiple files one at a time instead of concurrently.
  ///
  /// The result always preserves the original selection order, regardless
  /// of this setting.
  @Deprecated(
    'Only affects the deprecated withData preload. This option will be '
    'removed in file_picker v14.0.0.',
  )
  final bool readSequential;

  /// Whether to cancel upload when window loses focus.
  final bool cancelUploadOnWindowBlur;

  /// How [FilePickerWeb.saveFile] saves the file. Defaults to
  /// [WebSaveFileMode.download].
  final WebSaveFileMode saveMode;

  /// How [FilePickerWeb.pickFile] and [FilePickerWeb.pickFiles] open the
  /// browser's open dialog. Defaults to [WebFileDialog.input], the behaviour
  /// before this option existed.
  final WebFileDialog dialog;

  /// The `id` the browser keys the remembered folder of the file system access
  /// dialog on. Two picks with the same id reopen where the last one left off.
  ///
  /// Ignored by [WebFileDialog.input].
  final String? pickerId;

  /// The file types the file system access dialog accepts.
  ///
  /// It is the only way to filter that dialog: `type` and `allowedExtensions`
  /// only apply to the `<input type="file">` fallback, so [WebFileDialog.auto]
  /// keeps using the input for a pick they filter and this leaves empty.
  ///
  /// Ignored by [WebFileDialog.input].
  final List<WebFileTypeFilter> types;

  /// Creates an instance of [FilePickerWebOptions].
  const FilePickerWebOptions({
    @Deprecated(
      'Picked files are read on demand by PlatformFile.readAsBytes() and '
      'readAsByteStream(). This option will be removed in file_picker v14.0.0.',
    )
    this.withData = true,
    @Deprecated(
      'PlatformFile.readAsByteStream() already reads on demand in evenly '
      'sized chunks. This option will be removed in file_picker v14.0.0.',
    )
    this.withReadStream = false,
    @Deprecated(
      'Only affects the deprecated withData preload. This option will be '
      'removed in file_picker v14.0.0.',
    )
    this.readSequential = false,
    this.cancelUploadOnWindowBlur = true,
    this.saveMode = WebSaveFileMode.download,
    this.dialog = WebFileDialog.input,
    this.pickerId,
    this.types = const <WebFileTypeFilter>[],
  });
}
