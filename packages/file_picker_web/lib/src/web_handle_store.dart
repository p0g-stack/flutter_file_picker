import 'dart:async';
import 'dart:js_interop';
import 'dart:math';

import 'package:web/web.dart';

// A FileSystemFileHandle can't be turned into a string, but it can be stored
// in IndexedDB, so the plugin keeps the handles in its own object store and
// the token is the record key.
//
// Adapted from dir_picker's web_tokens.dart, which uses the same design for
// directory handles:
// https://github.com/iamv4g/dir_picker.flutter/blob/main/lib/src/platforms/web/web_tokens.dart
//
// MIT License, Copyright (c) 2024 iamv4g:
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to
// deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
// sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions: the above
// copyright notice and this permission notice shall be included in all copies
// or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS",
// WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
// TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
// LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
// CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
// SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

/// The database and object store holding the handles a token refers to.
///
/// Private to the origin, like the rest of IndexedDB, and not tied to the
/// `id` a picker was opened with.
const String _databaseName = 'file_picker';
const String _storeName = 'files';

/// Stores [handle] and returns its token.
///
/// A handle for the same file as one already stored gets that record's token,
/// so a file the user picks again does not pile up records.
Future<String> storeHandle(FileSystemFileHandle handle) async {
  final (keys, handles) = await _transact('readonly', (store) async {
    final keys = store.getAllKeys();
    final handles = store.getAll();
    return (await _result(keys), await _result(handles));
  });
  final keyList = (keys as JSArray<JSString>).toDart;
  final handleList = (handles as JSArray<FileSystemHandle>).toDart;
  for (var i = 0; i < keyList.length; i++) {
    final stored = await handleList[i].isSameEntry(handle).toDart;
    if (stored.toDart) return keyList[i].toDart;
  }

  final token = _newToken();
  await _transact(
    'readwrite',
    (store) => _result(store.put(handle, token.toJS)),
  );
  return token;
}

/// The handle stored under [token], or `null` when there is none.
Future<FileSystemFileHandle?> loadHandle(String token) async {
  final value = await _transact(
    'readonly',
    (store) => _result(store.get(token.toJS)),
  );
  return value != null && value.isA<FileSystemFileHandle>()
      ? value as FileSystemFileHandle
      : null;
}

/// Deletes the record stored under [token], if any.
Future<void> deleteHandle(String token) =>
    _transact('readwrite', (store) => _result(store.delete(token.toJS)));

/// 128 random bits as hex, so a token can't be guessed or collide.
String _newToken() {
  final random = Random.secure();
  return [
    for (var i = 0; i < 16; i++)
      random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

/// Runs [body] in a transaction on the store and returns its result once the
/// transaction has committed.
Future<T> _transact<T>(
  String mode,
  Future<T> Function(IDBObjectStore store) body,
) async {
  final database = await _open();
  try {
    final transaction = database.transaction(_storeName.toJS, mode);
    final done = Completer<void>();
    // A failed request fires both error and abort on the transaction.
    void fail(Event _) {
      if (!done.isCompleted) done.completeError(_error(transaction.error));
    }

    transaction
      ..oncomplete = ((Event _) => done.complete()).toJS
      ..onerror = fail.toJS
      ..onabort = fail.toJS;
    final T result;
    try {
      result = await body(transaction.objectStore(_storeName));
    } catch (_) {
      // The failed request aborts the transaction, which fails [done] too.
      done.future.ignore();
      rethrow;
    }
    await done.future;
    return result;
  } finally {
    database.close();
  }
}

Future<IDBDatabase> _open() async {
  final request = window.indexedDB.open(_databaseName, 1);
  request.onupgradeneeded = ((Event _) {
    (request.result as IDBDatabase).createObjectStore(_storeName);
  }).toJS;
  return await _result(request) as IDBDatabase;
}

/// The result of [request], or its error.
Future<JSAny?> _result(IDBRequest request) {
  final completer = Completer<JSAny?>();
  request
    ..onsuccess = ((Event _) => completer.complete(request.result)).toJS
    ..onerror = ((Event _) => completer.completeError(
      _error(request.error),
    )).toJS;
  return completer.future;
}

Object _error(DOMException? error) =>
    error ?? Exception('IndexedDB request failed without an error');
