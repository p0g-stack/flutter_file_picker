![File Picker for Web](https://raw.githubusercontent.com/vicajilau/flutter_file_picker/main/.github/assets/readme_banner_web.svg)

# file_picker_web

The Web implementation of [`file_picker`](https://pub.dev/packages/file_picker).

## Usage

This package is endorsed, which means you can simply use `file_picker` as normal, and the Web implementation will be automatically included.

## File system access dialog

Picking uses `<input type="file">` by default. Where the browser has
`showOpenFilePicker()` — Chromium based ones, in a secure context, outside a
cross-origin iframe — `pickFile()` can use the file system access dialog
instead, which returns a handle next to the browser `File`:

```dart
final picked = await FilePicker.pickFile(
  webOptions: const FilePickerWebOptions(
    dialog: WebFileDialog.fileSystemAccess,
    pickerId: 'ota',
    types: [
      WebFileTypeFilter(
        description: 'OTA package',
        accept: {
          'application/zip': ['.zip'],
        },
      ),
    ],
  ),
) as WebPlatformFile?;

// Ranged reads, without loading the whole file.
final header = await picked!.file!.slice(0, 4).arrayBuffer().toDart;
final magic = header.toDart.asUint8List();
```

`WebFileDialog.auto` does the same where the browser has the API and the pick
can be filtered with `types`, and keeps `<input type="file">` everywhere else,
including where `type` or `allowedExtensions` filter the pick (the dialog only
understands `types`). `FilePickerWebOptions.dialog` defaults to
`WebFileDialog.input`, which is picking as it was before this option existed:
the dialog is only used when it is asked for. Cancelling the dialog returns
`null`, like the input does. `WebFileDialog.fileSystemAccess` throws an
`UnsupportedError` where the browser has no dialog, so check
`supportsShowOpenFilePicker` first if the input is an acceptable fallback.

## Remembering a picked file

A handle can be stored in the browser's IndexedDB and loaded back after a page
reload, without asking for the file again:

```dart
final token = await picked.persist();          // null for an input pick

final restored = await WebPlatformFile.restore(token!);
if (restored != null) {
  // Read access is kept only while another tab of the site has it, or when the
  // user chose to allow it on every visit. Renewing it needs a user gesture.
  if (!await restored.hasAccess()) await restored.requestAccess();
  final file = await restored.getFile();
}

await WebPlatformFile.forget(token);
```

`restore()` returns `null` for a token it does not know, and a file whose
content may no longer be read still comes back with its `name` and `handle`, so
an app can offer to renew the access instead of asking for the file again.
Persisting the same file twice returns the same token. Files picked through
`<input type="file">` have no handle, so `persist()` returns `null` for them.

Tokens live in the origin's own storage. A browser that clears site data, or a
different browser profile, loses them: `restore()` then returns `null`, and the
app has to ask for the file again.

### Writing a file the page remembered

A handle the user picked to save to needs the `readwrite` mode, not `read`.
`hasAccess()` and `requestAccess()` take it as `FilePermissionMode.readWrite`,
and `hasPermission()`/`requestPermission()` do the same for a bare handle the
app kept on its own, such as one loaded from `loadHandle()`:

```dart
final handle = await loadHandle(writeToken);
if (handle != null && await hasPermission(handle, mode: FilePermissionMode.readWrite)) {
  final file = await handle.getFile();    // readable content of the same file
  final writable = await handle.createWritable();
  // ...
}
```

Without `readwrite` — after a reload, unless the user allowed the site on every
visit — `createWritable()` throws a `NotAllowedError`, so call
`requestPermission` from the click that starts the write.

