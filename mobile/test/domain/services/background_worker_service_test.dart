import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/data/data_controller.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/services/background_worker.service.dart';
import 'package:immich_mobile/domain/services/hash.service.dart';
import 'package:immich_mobile/domain/services/local_sync.service.dart';
import 'package:immich_mobile/domain/services/sync_linked_album.service.dart';
import 'package:immich_mobile/domain/services/sync_stream.service.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/providers/infrastructure/sync.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:mocktail/mocktail.dart';

import '../../fixtures/user.stub.dart';
import '../../service.mocks.dart';

class MockDataController extends Mock implements DataController {}

class MockLocalSyncService extends Mock implements LocalSyncService {}

class MockSyncStreamService extends Mock implements SyncStreamService {}

class MockHashService extends Mock implements HashService {}

class MockSyncLinkedAlbumService extends Mock implements SyncLinkedAlbumService {}

void main() {
  late BackgroundWorkerBgService sut;
  late MockSyncStreamService mockRemoteSyncService;
  late MockBackgroundUploadService mockBackgroundUploadService;
  late MockForegroundUploadService mockForegroundUploadService;
  late MockSyncLinkedAlbumService mockSyncLinkedAlbumService;
  late int albumSteps;
  late Drift db;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    registerFallbackValue(Completer<void>());
    registerFallbackValue(const UploadCallbacks());

    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await SettingsRepository.ensureInitialized(db);
    await SettingsRepository.instance.write(SettingsKey.backupEnabled, true);
    // The background worker refuses to run unless the switch is on, so every
    // existing case below needs it enabled. The dedicated group at the bottom
    // turns it off to cover the skip path.
    await SettingsRepository.instance.write(SettingsKey.backgroundSync, true);
    await SettingsRepository.instance.write(SettingsKey.backupSyncAlbums, true);
  });

  tearDownAll(() async {
    debugDefaultTargetPlatformOverride = null;
    await db.close();
  });

  setUp(() {
    final mockLocalSyncService = MockLocalSyncService();
    final mockHashService = MockHashService();
    final mockUserService = MockUserService();
    mockRemoteSyncService = MockSyncStreamService();
    mockBackgroundUploadService = MockBackgroundUploadService();
    mockForegroundUploadService = MockForegroundUploadService();
    mockSyncLinkedAlbumService = MockSyncLinkedAlbumService();

    when(() => mockLocalSyncService.sync()).thenAnswer((_) async {});
    when(() => mockHashService.hashAssets()).thenAnswer((_) async {});
    when(() => mockUserService.tryGetMyUser()).thenReturn(UserStub.admin);
    when(() => mockUserService.watchMyUser()).thenAnswer((_) => const Stream.empty());
    when(() => mockBackgroundUploadService.getActiveTasks(kBackupGroup)).thenAnswer((_) async => []);
    when(() => mockBackgroundUploadService.uploadBackupCandidates(any())).thenAnswer((_) async {});
    when(() => mockBackgroundUploadService.resume()).thenAnswer((_) async {});
    albumSteps = 0;
    when(
      () => mockSyncLinkedAlbumService.syncLinkedAlbums(any(), cancellation: any(named: 'cancellation')),
    ).thenAnswer((_) async => albumSteps += 1);

    sut = BackgroundWorkerBgService(
      dataController: MockDataController(),
      apiService: MockApiService(),
      overrides: [
        localSyncServiceProvider.overrideWithValue(mockLocalSyncService),
        syncStreamServiceProvider.overrideWithValue(mockRemoteSyncService),
        hashServiceProvider.overrideWithValue(mockHashService),
        currentUserProvider.overrideWith((ref) => CurrentUserProvider(mockUserService)),
        foregroundUploadServiceProvider.overrideWithValue(mockForegroundUploadService),
        backgroundUploadServiceProvider.overrideWithValue(mockBackgroundUploadService),
        syncLinkedAlbumServiceProvider.overrideWithValue(mockSyncLinkedAlbumService),
      ],
    );
  });

  group('onAndroidUpload', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      when(() => mockRemoteSyncService.sync()).thenAnswer((_) async => true);
    });

    tearDown(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

    void stubUploads(Future<void> Function(UploadCallbacks callbacks) uploads) {
      when(
        () => mockForegroundUploadService.uploadCandidates(
          any(),
          any(),
          callbacks: any(named: 'callbacks'),
          useSequentialUpload: true,
        ),
      ).thenAnswer((invocation) => uploads(invocation.namedArguments[#callbacks] as UploadCallbacks));
    }

    test('syncs again and adds the uploads to their albums when the run ends', () async {
      stubUploads((callbacks) async => callbacks.onSuccess?.call('local-1', 'remote-1'));

      await sut.onAndroidUpload(20);

      verify(() => mockRemoteSyncService.sync()).called(2);
      expect(albumSteps, 1);
    });

    test('adds earlier uploads to their albums when nothing was uploaded', () async {
      stubUploads((_) async {});

      await sut.onAndroidUpload(20);

      expect(albumSteps, 1);
    });

    test('adds the uploads to their albums every 10 uploads', () {
      fakeAsync((async) {
        stubUploads((callbacks) async {
          for (var i = 0; i < 10; i++) {
            callbacks.onSuccess?.call('local-$i', 'remote-$i');
          }
          await Future<void>.delayed(const Duration(minutes: 5));
        });

        unawaited(sut.onAndroidUpload(20));
        async.elapse(const Duration(seconds: 10));

        expect(albumSteps, 1);
      });
    });

    test('runs one album step at a time', () {
      fakeAsync((async) {
        final albumStep = Completer<void>();
        when(
          () => mockSyncLinkedAlbumService.syncLinkedAlbums(any(), cancellation: any(named: 'cancellation')),
        ).thenAnswer((_) {
          albumSteps += 1;
          return albumStep.future;
        });
        stubUploads((callbacks) async {
          for (var i = 0; i < 100; i++) {
            callbacks.onSuccess?.call('local-$i', 'remote-$i');
          }
        });

        unawaited(sut.onAndroidUpload(20));
        async.flushMicrotasks();
        expect(albumSteps, 1);

        albumStep.complete();
        async.flushMicrotasks();
        expect(albumSteps, 2);
      });
    });

    test('leaves the albums alone when the run times out', () {
      fakeAsync((async) {
        stubUploads((callbacks) async {
          callbacks.onSuccess?.call('local-1', 'remote-1');
          await Future<void>.delayed(const Duration(minutes: 20));
        });

        unawaited(sut.onAndroidUpload(20));
        async.elapse(const Duration(minutes: 21));

        expect(albumSteps, 0);
      });
    });
  });

  group('onIosUpload', () {
    test('lists a new batch only after the remote sync finished', () async {
      final remoteSync = Completer<bool>();
      when(() => mockRemoteSyncService.sync()).thenAnswer((_) => remoteSync.future);

      final upload = sut.onIosUpload(true, 20);
      await pumpEventQueue();
      verifyNever(() => mockBackgroundUploadService.uploadBackupCandidates(any()));

      remoteSync.complete(true);
      await upload;
      verify(() => mockBackgroundUploadService.uploadBackupCandidates(UserStub.admin.id)).called(1);
    });

    test('does not list a new batch when the remote sync fails', () async {
      when(() => mockRemoteSyncService.sync()).thenAnswer((_) async => false);

      await sut.onIosUpload(true, 20);

      verifyNever(() => mockBackgroundUploadService.uploadBackupCandidates(any()));
    });

    test('does not list a new batch when the run times out before the remote sync finished', () {
      fakeAsync((async) {
        final remoteSync = Completer<bool>();
        when(() => mockRemoteSyncService.sync()).thenAnswer((_) => remoteSync.future);

        unawaited(sut.onIosUpload(true, 20));
        async.elapse(const Duration(seconds: 20));
        // a cancelled sync can still return true
        remoteSync.complete(true);
        async.flushMicrotasks();

        verifyNever(() => mockBackgroundUploadService.uploadBackupCandidates(any()));
      });
    });

    test('resumes pending uploads without waiting for the remote sync', () async {
      final remoteSync = Completer<bool>();
      when(() => mockRemoteSyncService.sync()).thenAnswer((_) => remoteSync.future);
      when(
        () => mockBackgroundUploadService.getActiveTasks(kBackupGroup),
      ).thenAnswer((_) async => [UploadTask(url: 'https://example.com', filename: 'photo.jpg')]);

      final upload = sut.onIosUpload(true, 20);
      await pumpEventQueue();
      verify(() => mockBackgroundUploadService.resume()).called(1);

      remoteSync.complete(true);
      await upload;
    });

    test('adds earlier uploads to their albums after the remote sync', () async {
      final remoteSync = Completer<bool>();
      when(() => mockRemoteSyncService.sync()).thenAnswer((_) => remoteSync.future);
      when(
        () => mockBackgroundUploadService.getActiveTasks(kBackupGroup),
      ).thenAnswer((_) async => [UploadTask(url: 'https://example.com', filename: 'photo.jpg')]);

      final upload = sut.onIosUpload(true, 20);
      await pumpEventQueue();
      verify(() => mockRemoteSyncService.sync()).called(1);
      expect(albumSteps, 0);

      remoteSync.complete(true);
      await upload;
      expect(albumSteps, 1);
    });
  });

  group('onAndroidUpload budget', () {
    // 预算到点是我们自己喊停的，不是用户手动停止。若报 false，Kotlin 侧会
    // complete(Result.success())，即「干完了、别重排」，用户观感是「传一会儿
    // 就停，得反复开 App 推它」。这两条用例把这个语义钉住。
    test('asks WorkManager to reschedule when it runs out of budget', () {
      fakeAsync((async) {
        when(() => mockRemoteSyncService.sync()).thenAnswer((_) async => true);
        final uploadService = MockForegroundUploadService();
        // 上传一直挂着，模拟还没传完就被预算掐断
        when(
          () => uploadService.uploadCandidates(
            any(),
            any(),
            callbacks: any(named: 'callbacks'),
            useSequentialUpload: any(named: 'useSequentialUpload'),
          ),
        ).thenAnswer((_) => Completer<void>().future);

        sut = BackgroundWorkerBgService(
          dataController: MockDataController(),
          apiService: MockApiService(),
          overrides: [
            localSyncServiceProvider.overrideWithValue(MockLocalSyncService()),
            syncStreamServiceProvider.overrideWithValue(mockRemoteSyncService),
            hashServiceProvider.overrideWithValue(MockHashService()),
            currentUserProvider.overrideWith((ref) => CurrentUserProvider(MockUserService())),
            foregroundUploadServiceProvider.overrideWithValue(uploadService),
            backgroundUploadServiceProvider.overrideWithValue(mockBackgroundUploadService),
            syncLinkedAlbumServiceProvider.overrideWithValue(mockSyncLinkedAlbumService),
          ],
        );

        bool? needsRetry;
        unawaited(sut.onAndroidUpload(20).then((value) => needsRetry = value));

        // maxMinutes=20 => backupTimeout = 19 分钟
        async.elapse(const Duration(minutes: 20, seconds: 5));
        async.flushMicrotasks();

        expect(needsRetry, isTrue, reason: '预算超时后必须要求重排');
      });
    });

    test('does not retry when the user cancels', () async {
      when(() => mockRemoteSyncService.sync()).thenAnswer((_) async => true);
      final uploadService = MockForegroundUploadService();
      final cancelToken = Completer<void>();
      when(
        () => uploadService.uploadCandidates(
          any(),
          any(),
          callbacks: any(named: 'callbacks'),
          useSequentialUpload: any(named: 'useSequentialUpload'),
        ),
      ).thenAnswer((invocation) async {
        final callbacks = invocation.namedArguments[#callbacks] as UploadCallbacks;
        // 模拟「用户手动停止 / 系统回收」导致的取消，而不是预算超时
        callbacks.onCancelled?.call('asset-1');
        cancelToken.complete();
      });

      sut = BackgroundWorkerBgService(
        dataController: MockDataController(),
        apiService: MockApiService(),
        overrides: [
          localSyncServiceProvider.overrideWithValue(MockLocalSyncService()),
          syncStreamServiceProvider.overrideWithValue(mockRemoteSyncService),
          hashServiceProvider.overrideWithValue(MockHashService()),
          currentUserProvider.overrideWith((ref) => CurrentUserProvider(MockUserService())),
          foregroundUploadServiceProvider.overrideWithValue(uploadService),
          backgroundUploadServiceProvider.overrideWithValue(mockBackgroundUploadService),
          syncLinkedAlbumServiceProvider.overrideWithValue(mockSyncLinkedAlbumService),
        ],
      );

      final needsRetry = await sut.onAndroidUpload(20);

      expect(needsRetry, isFalse, reason: '用户取消不该触发重排');
    });
  });

  group('background sync switch', () {
    tearDown(() async {
      await SettingsRepository.instance.write(SettingsKey.backgroundSync, true);
    });

    test('skips the whole run when the switch is off', () async {
      await SettingsRepository.instance.write(SettingsKey.backgroundSync, false);

      await sut.onIosUpload(true, 20);

      verifyNever(() => mockRemoteSyncService.sync());
      verifyNever(() => mockBackgroundUploadService.uploadBackupCandidates(any()));
      verifyNever(() => mockBackgroundUploadService.resume());
    });

    test('runs when the switch is on', () async {
      await SettingsRepository.instance.write(SettingsKey.backgroundSync, true);
      when(() => mockRemoteSyncService.sync()).thenAnswer((_) async => true);

      await sut.onIosUpload(true, 20);

      verify(() => mockRemoteSyncService.sync()).called(1);
      verify(() => mockBackgroundUploadService.uploadBackupCandidates(UserStub.admin.id)).called(1);
    });
  });
}
