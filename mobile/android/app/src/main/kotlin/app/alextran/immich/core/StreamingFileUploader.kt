package app.alextran.immich.core

import android.util.Log
import org.chromium.net.CronetEngine
import org.chromium.net.CronetException
import org.chromium.net.UploadDataProvider
import org.chromium.net.UploadDataSink
import org.chromium.net.UrlRequest
import org.chromium.net.UrlResponseInfo
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.atomic.AtomicLong

/**
 * Streams a single `multipart/form-data` upload straight from disk through Cronet.
 *
 * This exists because `package:cronet_http` materialises the whole request body in
 * Dart memory (`final body = await stream.toBytes()`) before handing it to the
 * native layer, and the JNI bridge then copies it twice more. Multi-gigabyte
 * videos therefore cannot be uploaded through that client at all: memory use
 * scales with file size and the process is killed part-way through.
 *
 * Cronet's own [UploadDataProvider] API is streaming, so driving it directly from
 * a file keeps memory flat regardless of payload size. Everything else — PQ
 * ClientHello, TLS, redirects, connection reuse — stays on the same engine the
 * rest of the app uses.
 */
internal class StreamingFileUploader(
  private val engine: CronetEngine,
  private val executor: ExecutorService,
) {

  /** Outcome of one upload attempt. */
  data class Outcome(
    val isSuccess: Boolean,
    val statusCode: Int,
    val body: String?,
    val errorMessage: String?,
  )

  /**
   * Live requests keyed by progress key, so Dart can abort an upload when the
   * backup is cancelled (app paused, worker stopped, user hit stop). Without this
   * the native thread would keep uploading after the caller moved on.
   */
  private val activeRequests = java.util.concurrent.ConcurrentHashMap<String, UrlRequest>()

  fun cancel(progressKey: String) {
    activeRequests.remove(progressKey)?.let {
      runCatching { it.cancel() }
    }
  }

  /**
   * Upload [file] to [url] as multipart/form-data.
   *
   * @param onProgress called with (bytesSent, totalBytes) as the body drains.
   * @return the outcome; never throws for transport or HTTP failures.
   */
  fun upload(
    url: String,
    file: File,
    fileName: String,
    fileFieldName: String,
    mimeType: String?,
    fields: Map<String, String>,
    onProgress: ((Long, Long) -> Unit)?,
    progressKey: String,
  ): Outcome {
    if (!file.isFile) {
      return Outcome(false, 0, null, "File not found: ${file.path}")
    }

    val boundary = "----ImmichUpload${UUID.randomUUID().toString().replace("-", "")}"
    val header = buildMultipartHeader(boundary, fields, fileFieldName, fileName, mimeType)
    val footer = "\r\n--$boundary--\r\n".toByteArray(Charsets.UTF_8)
    val fileLength = file.length()

    val provider = FileUploadProvider(file, header, footer, fileLength, onProgress)
    Log.i(TAG, "upload start file=${file.name} size=$fileLength " +
      "header=${header.size} footer=${footer.size} " +
      "totalLength=${provider.getLength()} url=$url")

    val latch = java.util.concurrent.CountDownLatch(1)
    var outcome: Outcome? = null
    var request: UrlRequest? = null

    /** Bytes handed to Cronet so far, read by the callbacks for diagnostics. */
    val uploadedBytes: Long get() = provider.bytesSentSnapshot

    val callback = object : UrlRequest.Callback() {
      override fun onRedirectReceived(request: UrlRequest, info: UrlResponseInfo, newLocationUrl: String) {
        // Follow redirects: Cronet does not do this for us by default.
        request.followRedirect()
      }

      override fun onResponseStarted(request: UrlRequest, info: UrlResponseInfo) {
        Log.i(TAG, "onResponseStarted status=${info.httpStatusCode} " +
          "negProtocol=${info.negotiatedProtocol} headers=${info.allHeaders}")
        request.read(ByteBuffer.allocateDirect(BUFFER_SIZE))
      }

      override fun onReadCompleted(
        request: UrlRequest,
        info: UrlResponseInfo,
        byteBuffer: ByteBuffer,
      ) {
        byteBuffer.flip()
        if (byteBuffer.hasRemaining()) {
          val chunk = ByteArray(byteBuffer.remaining())
          byteBuffer.get(chunk)
          responseBytes.write(chunk, 0, chunk.size)
        }
        byteBuffer.clear()
        request.read(byteBuffer)
      }

      override fun onSucceeded(request: UrlRequest, info: UrlResponseInfo) {
        Log.i(TAG, "onSucceeded status=${info.httpStatusCode} " +
          "sent=$uploadedBytes total=${provider.getLength()} " +
          "reads=${provider.readCount} lastRead=${provider.lastReadSize} " +
          "bodyLen=${responseBytes.size()}")
        outcome = Outcome(
          isSuccess = info.httpStatusCode in 200..299,
          statusCode = info.httpStatusCode,
          body = responseBytes.toString(Charsets.UTF_8),
          errorMessage = null,
        )
        latch.countDown()
      }

      override fun onFailed(request: UrlRequest, info: UrlResponseInfo?, error: CronetException) {
        Log.e(TAG, "onFailed status=${info?.httpStatusCode} " +
          "sent=$uploadedBytes total=${provider.getLength()} " +
          "reads=${provider.readCount} lastRead=${provider.lastReadSize} " +
          "error=${error.message} isCronetError=${error.isCronetError} " +
          "cronetError=${error.cronetError} " +
          "cause=${error.cause?.javaClass?.simpleName}:${error.cause?.message}")
        outcome = Outcome(false, info?.httpStatusCode ?: 0, null, error.toString())
        latch.countDown()
      }

      override fun onCanceled(request: UrlRequest, info: UrlResponseInfo?) {
        Log.w(TAG, "onCanceled status=${info?.httpStatusCode} sent=$uploadedBytes " +
          "total=${provider.getLength()} reads=${provider.readCount}")
        outcome = Outcome(false, info?.httpStatusCode ?: 0, null, "Upload cancelled")
        latch.countDown()
      }

      private val responseBytes = java.io.ByteArrayOutputStream()
    }

    return try {
      val builder = engine.newUrlRequestBuilder(url, callback, executor)

      // Auth and any other persisted headers. Cronet strips these from the URL
      // rather than reading them off the request, so set them explicitly.
      HttpClientManager.getAuthHeaders(url).forEach { (key, value) ->
        if (!key.equals("content-length", ignoreCase = true) &&
          !key.equals("content-type", ignoreCase = true)
        ) {
          builder.addHeader(key, value)
        }
      }
      builder.addHeader("Content-Type", "multipart/form-data; boundary=$boundary")

      // Cronet only calls rewind() when it needs to replay the body (redirects,
      // auth challenges). Prime the provider so the first read has data.
      provider.resetForFirstRead()

      request = builder
        .setHttpMethod("POST")
        .setUploadDataProvider(provider, executor)
        .build()
      activeRequests[progressKey] = request!!
      request.start()

      // A watchdog is the only way to tell "Cronet stopped asking for data" from
      // "the body is still draining". If readCount stops advancing while the
      // request is live, the bug is on our side of the UploadDataProvider.
      val watchdogStart = System.nanoTime()
      val watchdog = java.util.Timer("upload-watchdog-$progressKey", true)
      watchdog.scheduleAtFixedRate(object : java.util.TimerTask() {
        override fun run() {
          val elapsed = (System.nanoTime() - watchdogStart) / 1_000_000_000
          Log.i(TAG, "watchdog t=${elapsed}s sent=$uploadedBytes/${provider.getLength()} " +
            "reads=${provider.readCount} lastRead=${provider.lastReadSize} " +
            "latchDone=${latch.count == 0L}")
        }
      }, 2000L, 3000L)

      // A missing callback would otherwise wedge the calling thread forever.
      val finished = latch.await(UPLOAD_TIMEOUT_SECONDS, java.util.concurrent.TimeUnit.SECONDS)
      watchdog.cancel()
      if (!finished) {
        Log.e(TAG, "upload timed out after ${UPLOAD_TIMEOUT_SECONDS}s " +
          "sent=$uploadedBytes/${provider.getLength()} reads=${provider.readCount}")
        request.cancel()
        return Outcome(false, 0, null, "Upload timed out")
      }
      outcome?.let {
        val bodySnippet = it.body?.take(300)?.replace("\n", " ")
        Log.i(TAG, "upload done success=${it.isSuccess} status=${it.statusCode} " +
          "sent=$uploadedBytes/${provider.getLength()} reads=${provider.readCount} " +
          "err=${it.errorMessage} body=$bodySnippet")
      }
      outcome ?: Outcome(false, 0, null, "Upload finished with no result")
    } catch (e: Exception) {
      Log.e(TAG, "upload threw sent=$uploadedBytes", e)
      Outcome(false, 0, null, e.toString())
    } finally {
      activeRequests.remove(progressKey)
      provider.closeStream()
    }
  }

  private fun buildMultipartHeader(
    boundary: String,
    fields: Map<String, String>,
    fileFieldName: String,
    fileName: String,
    mimeType: String?,
  ): ByteArray {
    val out = StringBuilder()
    fields.forEach { (name, value) ->
      out.append("--").append(boundary).append("\r\n")
      out.append("Content-Disposition: form-data; name=\"").append(name.escapeQuotes()).append("\"\r\n")
      out.append("\r\n")
      out.append(value).append("\r\n")
    }
    out.append("--").append(boundary).append("\r\n")
    out.append("Content-Disposition: form-data; name=\"")
      .append(fileFieldName.escapeQuotes())
      .append("\"; filename=\"")
      .append(fileName.escapeQuotes())
      .append("\"\r\n")
    out.append("Content-Type: ").append(mimeType ?: "application/octet-stream").append("\r\n")
    out.append("\r\n")
    return out.toString().toByteArray(Charsets.UTF_8)
  }

  private fun String.escapeQuotes(): String = replace("\\", "\\\\").replace("\"", "\\\"")

  /**
   * Feeds header, file bytes, then footer to Cronet without ever holding more
   * than one buffer worth of the payload in memory.
   */
  private class FileUploadProvider(
    private val file: File,
    private val header: ByteArray,
    private val footer: ByteArray,
    private val fileLength: Long,
    private val onProgress: ((Long, Long) -> Unit)?,
  ) : UploadDataProvider() {

    private val totalLength: Long = header.size.toLong() + fileLength + footer.size.toLong()

    private var stream: FileInputStream? = null
    private var headerRemaining = 0
    private var fileRemaining = 0L
    private var footerRemaining = 0
    private var bytesSent = 0L
    private var lastReported = 0L
    private var scratch = ByteArray(0)

    /** Diagnostics: how many times Cronet asked for data, and the size of the last read. */
    internal var readCount = 0L
      private set
    internal var lastReadSize = 0

    /** Monotonic count of bytes handed to Cronet, safe to read from any thread. */
    internal val bytesSentSnapshot: Long get() = bytesSent

    override fun getLength(): Long = totalLength

    override fun rewind(uploadDataSink: UploadDataSink) {
      openStream()
    }

    /// Primes the provider for the first read. Cronet only calls [rewind] itself
    /// when it must replay the body, so the very first read needs this too.
    fun resetForFirstRead() {
      openStream()
    }

    private fun openStream() {
      closeStream()
      stream = FileInputStream(file)
      headerRemaining = header.size
      fileRemaining = fileLength
      footerRemaining = footer.size
      bytesSent = 0
      lastReported = 0
    }


    override fun read(sink: UploadDataSink, buffer: ByteBuffer) {
      readCount++
      try {
        var wrote = 0
        val capacity = buffer.remaining()

        // 1) multipart preamble (field headers + file part header)
        if (headerRemaining > 0 && wrote < capacity) {
          val chunk = minOf(headerRemaining, capacity)
          val offset = header.size - headerRemaining
          buffer.put(header, offset, chunk)
          headerRemaining -= chunk
          wrote += chunk
        }

        // 2) file payload, read straight off disk
        if (fileRemaining > 0 && wrote < capacity) {
          val want = minOf(fileRemaining, (capacity - wrote).toLong()).toInt()
          // Cronet hands us a direct buffer, which has no backing array, so read
          // into a scratch array and copy across.
          if (scratch.size < want) {
            scratch = ByteArray(want)
          }
          val read = stream?.read(scratch, 0, want) ?: -1
          if (read <= 0) {
            // Disk truncated underneath us; fail loudly rather than sending a
            // short body that the server would reject with a confusing error.
            Log.e(TAG, "read#$readCount EOF at sent=$bytesSent fileRemaining=$fileRemaining want=$want")
            sink.onReadError(IOException("Unexpected EOF reading ${file.path}"))
            return
          }
          buffer.put(scratch, 0, read)
          fileRemaining -= read
          wrote += read
        }

        // 3) closing boundary
        if (footerRemaining > 0 && wrote < capacity) {
          val chunk = minOf(footerRemaining, capacity)
          val offset = footer.size - footerRemaining
          buffer.put(footer, offset, chunk)
          footerRemaining -= chunk
          wrote += chunk
        }

        lastReadSize = wrote

        // Log the shape of the read loop: Cronet's buffer sizes tell us whether
        // it is throttling us, and where the first non-full read lands.
        if (readCount <= 8 || readCount % 200 == 0L || wrote == 0) {
          Log.i(TAG, "read#$readCount cap=$capacity wrote=$wrote " +
            "sent=$bytesSent/$totalLength fileRemaining=$fileRemaining " +
            "headerRemaining=$headerRemaining footerRemaining=$footerRemaining")
        }

        if (wrote == 0) {
          // No bytes left to hand over. Cronet needs the final-chunk flag set so
          // it can close out the request instead of asking again.
          Log.i(TAG, "read#$readCount final chunk, sent=$bytesSent/$totalLength")
          sink.onReadSucceeded(true)
          return
        }

        bytesSent += wrote
        onProgress?.let { report(it) }
        sink.onReadSucceeded(false)
      } catch (e: IOException) {
        Log.e(TAG, "read#$readCount IOException sent=$bytesSent", e)
        sink.onReadError(e)
      } catch (e: Exception) {
        Log.e(TAG, "read#$readCount failed sent=$bytesSent", e)
        sink.onReadError(IOException(e))
      }
    }

    private fun report(cb: (Long, Long) -> Unit) {
      // Throttle: progress callbacks cross the platform channel, so firing one
      // per 64 KiB buffer would flood the message loop on a large upload.
      if (bytesSent - lastReported >= PROGRESS_INTERVAL || bytesSent >= totalLength) {
        lastReported = bytesSent
        cb(bytesSent, totalLength)
      }
    }

    fun closeStream() {
      try {
        stream?.close()
      } catch (_: IOException) {
      }
      stream = null
    }

    override fun close() {
      closeStream()
    }

    companion object {
      private const val PROGRESS_INTERVAL = 1L * 1024 * 1024
    }
  }

  companion object {
    private const val TAG = "ImmichStreamUpload"
    private const val BUFFER_SIZE = 256 * 1024
    private const val UPLOAD_TIMEOUT_SECONDS = 60L * 30
  }
}
