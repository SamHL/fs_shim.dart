@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:fs_shim/fs_idb.dart';
import 'package:idb_shim/idb.dart' as idb;
import 'package:idb_shim/idb_client_memory.dart';
import 'package:test/test.dart';

/// A browser can close an IndexedDB connection on its own, for example when
/// the user clears site data or the storage backend fails. Every transaction
/// started on that connection then throws `InvalidStateError: The database
/// connection is closing`, synchronously, for the life of the page.
///
/// The in-memory factory does not behave that way once closed, so these tests
/// wrap it in one that does.
void main() {
  group('idb connection closed by the browser', () {
    late _ClosableIdbFactory factory;
    late FileSystem fs;
    late File file;

    setUp(() async {
      factory = _ClosableIdbFactory(newIdbFactoryMemory());
      fs = newFileSystemIdb(factory);
      file = fs.file('/dir/file.bin');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(Uint8List.fromList([1, 2, 3]));
    });

    test('a read after the connection closes succeeds on a new one', () async {
      factory.closeOpenConnections();

      final uncaught = <Object>[];
      List<int>? read;
      await runZonedGuarded(() async {
        read = await file.readAsBytes().timeout(const Duration(seconds: 5));
      }, (error, _) => uncaught.add(error))!;

      expect(uncaught, isEmpty);
      expect(read, [1, 2, 3]);
      expect(factory.opened, 2);
    });

    // Looking up a node threw "The database connection is closing" out of
    // IdbFileSystemStorage.getNode, uncaught, in the HazView web app
    // (HAZVIEW-1GK).
    test('every kind of operation recovers on its own', () async {
      factory.closeOpenConnections();
      expect(await file.exists(), isTrue);

      factory.closeOpenConnections();
      expect((await file.stat()).size, 3);

      factory.closeOpenConnections();
      expect(await fs.directory('/dir').list().toList(), hasLength(1));

      factory.closeOpenConnections();
      final other = fs.file('/dir/other.bin');
      await other.writeAsBytes(Uint8List.fromList([4, 5]));
      expect(await other.readAsBytes(), [4, 5]);
    });

    test('an open connection is reused', () async {
      expect(await file.readAsBytes(), [1, 2, 3]);
      expect(await file.readAsBytes(), [1, 2, 3]);
      expect(factory.opened, 1);
    });
  });
}

/// Opens databases through [_delegate] and can close them the way a browser
/// does: every later transaction on them throws.
class _ClosableIdbFactory implements idb.IdbFactory {
  _ClosableIdbFactory(this._delegate);

  final idb.IdbFactory _delegate;
  final _databases = <_ClosableDatabase>[];

  int get opened => _databases.length;

  void closeOpenConnections() {
    for (final database in _databases) {
      database.closedByBrowser = true;
    }
  }

  @override
  Future<idb.Database> open(
    String dbName, {
    int? version,
    idb.OnUpgradeNeededFunction? onUpgradeNeeded,
    idb.OnBlockedFunction? onBlocked,
  }) async {
    final database = _ClosableDatabase(
      await _delegate.open(
        dbName,
        version: version,
        onUpgradeNeeded: onUpgradeNeeded,
        onBlocked: onBlocked,
      ),
      this,
    );
    _databases.add(database);
    return database;
  }

  @override
  int cmp(Object first, Object second) => _delegate.cmp(first, second);

  @override
  Future<idb.IdbFactory> deleteDatabase(
    String name, {
    idb.OnBlockedFunction? onBlocked,
  }) => _delegate.deleteDatabase(name, onBlocked: onBlocked);

  @override
  String get name => _delegate.name;

  @override
  bool get persistent => _delegate.persistent;

  // The members idb_shim adds from one version to the next are never called
  // by the file system under test.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _ClosableDatabase extends idb.Database {
  _ClosableDatabase(this._delegate, idb.IdbFactory factory) : super(factory);

  final idb.Database _delegate;
  bool closedByBrowser = false;

  void _checkOpen() {
    if (closedByBrowser) {
      throw StateError(
        "InvalidStateError: Failed to execute 'transaction' on 'IDBDatabase': "
        'The database connection is closing.',
      );
    }
  }

  @override
  idb.Transaction transaction(Object storeNameOrStoreNames, String mode) {
    _checkOpen();
    return _delegate.transaction(storeNameOrStoreNames, mode);
  }

  @override
  idb.Transaction transactionList(List<String> storeNames, String mode) {
    _checkOpen();
    return _delegate.transactionList(storeNames, mode);
  }

  @override
  idb.ObjectStore createObjectStore(
    String name, {
    Object? keyPath,
    bool? autoIncrement,
  }) => _delegate.createObjectStore(
    name,
    keyPath: keyPath,
    autoIncrement: autoIncrement,
  );

  @override
  void deleteObjectStore(String name) => _delegate.deleteObjectStore(name);

  @override
  Iterable<String> get objectStoreNames => _delegate.objectStoreNames;

  @override
  void close() => _delegate.close();

  @override
  int get version => _delegate.version;

  @override
  Stream<idb.VersionChangeEvent> get onVersionChange =>
      _delegate.onVersionChange;

  @override
  String get name => _delegate.name;
}
