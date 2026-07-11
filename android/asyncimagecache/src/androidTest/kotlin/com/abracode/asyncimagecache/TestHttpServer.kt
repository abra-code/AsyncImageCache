// TestHttpServer.kt - a minimal in-process HTTP server for the integration tests, built on a raw ServerSocket
// so it adds zero dependencies (com.sun.net.httpserver is not available on Android). It counts requests (to
// prove in-flight de-duplication issues exactly one fetch) and can serve an arbitrary status + body (to prove
// non-2xx rejection), with an optional per-response delay so concurrent loads overlap before the first
// completes.

package com.abracode.asyncimagecache

import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicInteger

internal class TestHttpServer(
    private val responder: (path: String) -> Response,
) {
    data class Response(val status: Int, val body: ByteArray, val delayMs: Long = 0L)

    private val serverSocket = ServerSocket(0)
    private val requests = AtomicInteger(0)
    @Volatile private var running = true

    val port: Int get() = serverSocket.localPort
    val requestCount: Int get() = requests.get()

    fun url(path: String): String = "http://127.0.0.1:$port$path"

    fun start() {
        Thread {
            while (running) {
                val socket = try {
                    serverSocket.accept()
                } catch (t: Throwable) {
                    break
                }
                // One thread per connection so concurrent (delayed) responses can overlap.
                Thread { handle(socket) }.apply { isDaemon = true }.start()
            }
        }.apply { isDaemon = true }.start()
    }

    fun stop() {
        running = false
        try {
            serverSocket.close()
        } catch (t: Throwable) {
            // ignore
        }
    }

    private fun handle(socket: Socket) {
        socket.use { s ->
            val input = s.getInputStream()
            val requestLine = readLine(input) ?: return
            // Drain the remaining request headers up to the blank line.
            while (true) {
                val line = readLine(input) ?: break
                if (line.isEmpty()) break
            }
            val path = requestLine.split(' ').getOrElse(1) { "/" }
            requests.incrementAndGet()

            val response = responder(path)
            if (response.delayMs > 0) {
                Thread.sleep(response.delayMs)
            }
            val header = buildString {
                append("HTTP/1.1 ").append(response.status).append(' ').append(reason(response.status)).append("\r\n")
                append("Content-Type: image/png\r\n")
                append("Content-Length: ").append(response.body.size).append("\r\n")
                append("Connection: close\r\n\r\n")
            }
            val out = s.getOutputStream()
            out.write(header.toByteArray(Charsets.US_ASCII))
            out.write(response.body)
            out.flush()
        }
    }

    // Read one CRLF-terminated line as ASCII (bytes up to and excluding the \r\n).
    private fun readLine(input: java.io.InputStream): String? {
        val buffer = StringBuilder()
        var prev = -1
        while (true) {
            val b = input.read()
            if (b == -1) {
                return if (buffer.isEmpty() && prev == -1) null else buffer.toString()
            }
            if (b == '\n'.code && prev == '\r'.code) {
                buffer.setLength(buffer.length - 1)   // drop the trailing '\r'
                return buffer.toString()
            }
            buffer.append(b.toChar())
            prev = b
        }
    }

    private fun reason(status: Int): String = when (status) {
        200 -> "OK"
        404 -> "Not Found"
        503 -> "Service Unavailable"
        else -> "Status"
    }
}
