import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/platform/network_api.g.dart';
import 'package:logging/logging.dart';

final uploadRepositoryProvider = Provider((ref) => UploadRepository());

class UploadRepository {
  final Logger logger = Logger('UploadRepository');
  void Function(TaskStatusUpdate)? onUploadStatus;
  void Function(TaskProgressUpdate)? onTaskProgress;

  /// The generated Pigeon host API. Kept as a field rather than pulled from a
  /// provider so this repository stays free of Riverpod wiring (platform.provider
  /// already imports this file, so importing it back would be a cycle).
  final NetworkApi _networkApi = NetworkApi();

  UploadRepository() {
    FileDownloader().registerCallbacks(
      group: kBackupGroup,
      taskStatusCallback: (update) => onUploadStatus?.call(update),
      taskProgressCallback: (update) => onTaskProgress?.call(update),
    );
    FileDownloader().registerCallbacks(
      group: kBackupLivePhotoGroup,
      taskStatusCallback: (update) => onUploadStatus?.call(update),
      taskProgressCallback: (update) => onTaskProgress?.call(update),
    );
    FileDownloader().registerCallbacks(
      group: kManualUploadGroup,
      taskStatusCallback: (update) => onUploadStatus?.call(update),
      taskProgressCallback: (update) => onTaskProgress?.call(update),
    );
  }

  Future<List<bool>> enqueueBackgroundAll(List<UploadTask> tasks) {
    return FileDownloader().enqueueAll(tasks);
  }

  /// Uploads through the native Cronet uploader, which streams the file off disk.
  ///
  /// Returns null when the native path is not usable on this build so the caller
  /// can fall back to the Dart client.
  Future<UploadResult?> _uploadFileStreaming({
    required File file,
    required String originalFileName,
    required Map<String, String> fields,
    void Function(int bytes, int totalBytes)? onProgress,
    required String logContext,
    Completer<void>? cancelToken,
  }) async {
    final progressKey = '$logContext:${file.path}';
    if (onProgress != null) {
      _streamingProgressListeners[progressKey] = onProgress;
    }

    // Abort the native upload when the caller cancels, otherwise the native
    // thread keeps streaming long after the backup has been stopped.
    if (cancelToken != null && !cancelToken.isCompleted) {
      unawaited(
        cancelToken.future.then((_) => _networkApi.cancelStreamingUpload(progressKey)).catchError((_) {}),
      );
    }

    try {
      final endpoint = Store.get(StoreKey.serverEndpoint);
      final result = await _networkApi.uploadFileStreaming(
        '$endpoint/assets',
        file.path,
        originalFileName,
        'assetData',
        _mimeTypeForFile(originalFileName),
        fields,
        progressKey,
      );

      if (result.isSuccess) {
        final body = result.body ?? '';
        try {
          final decoded = jsonDecode(body);
          final id = decoded['id'];
          if (id is String) {
            return UploadResult.success(remoteAssetId: id);
          }
          return UploadResult.error(errorMessage: 'Failed to parse server response');
        } catch (_) {
          return UploadResult.error(errorMessage: 'Failed to parse server response');
        }
      }

      final message = result.errorMessage ??
          (result.body?.isNotEmpty == true ? result.body : 'Upload failed with status ${result.statusCode}');
      logger.warning("Streaming upload $logContext failed: $message");
      return UploadResult.error(statusCode: result.statusCode, errorMessage: message);
    } catch (error, stackTrace) {
      logger.warning("Streaming upload $logContext threw", error, stackTrace);
      // Returning null lets the caller retry with the Dart client, which is slow
      // for big files but still better than dropping the asset.
      return null;
    } finally {
      _streamingProgressListeners.remove(progressKey);
    }
  }

  /// Progress callbacks are routed by [progressKey] so concurrent uploads do not
  /// overwrite each other's progress.
  static final Map<String, void Function(int, int)> _streamingProgressListeners = {};

  static void dispatchStreamingProgress(String key, int transferred, int total) {
    _streamingProgressListeners[key]?.call(transferred, total);
  }

  static String _mimeTypeForFile(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'heic' => 'image/heic',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'mp4' => 'video/mp4',
      'mov' => 'video/quicktime',
      '3gp' => 'video/3gpp',
      'mkv' => 'video/x-matroska',
      'avi' => 'video/x-msvideo',
      _ => 'application/octet-stream',
    };
  }

  Future<void> deleteDatabaseRecords(String group) {
    return FileDownloader().database.deleteAllRecords(group: group);
  }

  Future<int> reset(String group) {
    return FileDownloader().reset(group: group);
  }

  /// Get a list of tasks that are ENQUEUED or RUNNING
  Future<List<Task>> getActiveTasks(String group) {
    return FileDownloader().allTasks(group: group);
  }

  Future<void> start() {
    return FileDownloader().start();
  }

  Future<UploadResult> uploadFile({
    required File file,
    required String originalFileName,
    required Map<String, String> fields,
    required Completer<void>? cancelToken,
    void Function(int bytes, int totalBytes)? onProgress,
    required String logContext,
    Client? httpClient,
  }) async {
    // package:cronet_http buffers the entire request body in memory before it
    // hands it to the native layer (cronet_client.dart: `await stream.toBytes()`),
    // which makes anything larger than the heap unuploadable. Hand big files to
    // the native Cronet uploader, which streams them off disk instead.
    if (CurrentPlatform.isAndroid && file.lengthSync() > kStreamingUploadThreshold) {
      final streamed = await _uploadFileStreaming(
        file: file,
        originalFileName: originalFileName,
        fields: fields,
        onProgress: onProgress,
        logContext: logContext,
        cancelToken: cancelToken,
      );
      if (streamed != null) {
        return streamed;
      }
      // Fall through to the regular client if the native path is unavailable,
      // so a missing engine degrades to a slow upload rather than a hard failure.
    }

    final String savedEndpoint = Store.get(StoreKey.serverEndpoint);

    ProgressMultipartRequest buildRequest() {
      final request = ProgressMultipartRequest(
        'POST',
        Uri.parse('$savedEndpoint/assets'),
        abortTrigger: cancelToken?.future,
        onProgress: onProgress,
      );
      request.fields.addAll(fields);
      request.files.add(MultipartFile("assetData", file.openRead(), file.lengthSync(), filename: originalFileName));
      return request;
    }

    try {
      final client = httpClient ?? NetworkRepository.client;
      StreamedResponse response;
      try {
        response = await client.send(buildRequest());
      } on RequestAbortedException {
        rethrow;
      } on ClientException catch (error) {
        logger.warning("Upload $logContext failed before a response, resending once", error);
        response = await client.send(buildRequest());
      }

      final responseBodyString = await response.stream.bytesToString();

      if (![200, 201].contains(response.statusCode)) {
        String? errorMessage;

        if (response.statusCode == 413) {
          errorMessage = 'Error(413) File is too large to upload';
          return UploadResult.error(statusCode: response.statusCode, errorMessage: errorMessage);
        }

        try {
          final error = jsonDecode(responseBodyString);
          errorMessage = error['message'] ?? error['error'];
        } catch (_) {
          errorMessage = responseBodyString.isNotEmpty
              ? responseBodyString
              : 'Upload failed with status ${response.statusCode}';
        }

        return UploadResult.error(statusCode: response.statusCode, errorMessage: errorMessage);
      }

      try {
        final responseBody = jsonDecode(responseBodyString);
        return UploadResult.success(remoteAssetId: responseBody['id'] as String);
      } catch (e) {
        return UploadResult.error(errorMessage: 'Failed to parse server response');
      }
    } on RequestAbortedException {
      logger.warning("Upload $logContext was cancelled");
      return UploadResult.cancelled();
    } catch (error, stackTrace) {
      logger.warning("Error uploading $logContext", error, stackTrace);
      return UploadResult(isSuccess: false, isCancelled: false, errorMessage: error.toString(), error: error);
    }
  }
}

class ProgressMultipartRequest extends MultipartRequest with Abortable {
  ProgressMultipartRequest(super.method, super.url, {this.abortTrigger, this.onProgress});

  @override
  final Future<void>? abortTrigger;

  final void Function(int bytes, int totalBytes)? onProgress;

  @override
  ByteStream finalize() {
    final byteStream = super.finalize();
    if (onProgress == null) {
      return byteStream;
    }

    final total = contentLength;
    var bytes = 0;
    final stream = byteStream.transform(
      StreamTransformer.fromHandlers(
        handleData: (List<int> data, EventSink<List<int>> sink) {
          bytes += data.length;
          onProgress!(bytes, total);
          sink.add(data);
        },
      ),
    );
    return ByteStream(stream);
  }
}

class UploadResult {
  final bool isSuccess;
  final bool isCancelled;
  final String? remoteAssetId;
  final String? errorMessage;
  final int? statusCode;
  final Object? error;

  const UploadResult({
    required this.isSuccess,
    required this.isCancelled,
    this.remoteAssetId,
    this.errorMessage,
    this.statusCode,
    this.error,
  });

  factory UploadResult.success({required String remoteAssetId}) {
    return UploadResult(isSuccess: true, isCancelled: false, remoteAssetId: remoteAssetId);
  }

  factory UploadResult.error({String? errorMessage, int? statusCode}) {
    return UploadResult(isSuccess: false, isCancelled: false, errorMessage: errorMessage, statusCode: statusCode);
  }

  factory UploadResult.cancelled() {
    return const UploadResult(isSuccess: false, isCancelled: true);
  }
}
