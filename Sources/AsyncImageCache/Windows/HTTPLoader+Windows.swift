// Sources/AsyncImageCache/Windows/HTTPLoader+Windows.swift
//
// http and https on Windows, through WinHTTP, synchronously on a network queue of the store's own, at most six
// downloads at a time (URLSession's connections per host). As on Apple platforms (0.2.5) and Linux, a download
// carries none of the user's identity: WinHTTP's cookies, its automatic sign-in (the Windows account's credentials,
// Kerberos and NTLM, sent to a server or a proxy that asks) and its handling of sign-in challenges are all off. It
// follows redirects itself, to http and https only (WinHTTP's own following reads a redirect's body outside any
// limit), refuses a status outside 200-299 (so an error page, which some CDNs serve as an image, is never decoded or
// persisted) and a body that declares or brings more than the limit. Each step (resolving, connecting, sending,
// each read) may wait 60 seconds, as URLSession's default request timeout and the Linux engine allow. The system's
// proxy settings are used (WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY); a proxy that asks for sign-in is not answered.

#if os(Windows)

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import CAsyncImageCacheWindows
import Dispatch
import WinSDK

enum HTTPLoader {

    /// How long one step of a request may wait, in milliseconds.
    private static let stepTimeout: Int32 = 60_000
    /// The most redirects one download follows, as libsoup's and URLSession's own following do.
    private static let maximumRedirects = 20
    /// The statuses that redirect a GET.
    private static let redirectStatuses: Set<DWORD> = [301, 302, 303, 307, 308]
    private static let pieceSize = 64 * 1024

    /// A WinHTTP handle, closed with the box. WinHTTP's handles may be used from any thread.
    private final class Handle: @unchecked Sendable {
        let raw: HINTERNET
        init?(_ raw: HINTERNET?) {
            guard let raw else {
                return nil
            }
            self.raw = raw
        }
        deinit {
            WinHttpCloseHandle(raw)
        }
    }

    // One session for every download (its connections are reused), made on first use.
    private static let session: Handle? = {
        let made = "AsyncImageCache".withCString(encodedAs: UTF16.self) { agent in
            WinHttpOpen(agent, DWORD(WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY), nil, nil, 0)
        }
        guard let session = Handle(made) else {
            return nil
        }
        _ = WinHttpSetTimeouts(session.raw, stepTimeout, stepTimeout, stepTimeout, stepTimeout)
        // The wait for the whole response header is a separate timeout (90 seconds unless set), which a server
        // sending its header slowly, a byte at a time, would otherwise get.
        var headerTimeout = DWORD(stepTimeout)
        _ = WinHttpSetOption(session.raw, DWORD(WINHTTP_OPTION_RECEIVE_RESPONSE_TIMEOUT), &headerTimeout,
                             DWORD(MemoryLayout<DWORD>.size))
        var never = DWORD(WINHTTP_OPTION_REDIRECT_POLICY_NEVER)
        _ = WinHttpSetOption(session.raw, DWORD(WINHTTP_OPTION_REDIRECT_POLICY), &never, DWORD(MemoryLayout<DWORD>.size))
        return session
    }()

    // The network queue admits downloads in order, six at a time: it waits for a free slot, then starts the
    // download on a serial queue of its own. Dispatch gives a serial queue a new thread when all are busy, while
    // concurrent queues and the global queues share a pool of about one thread per processor, so a download that
    // blocks in WinHTTP for up to a minute holds none of that pool and decoding never waits behind the network.
    private static let queue = DispatchQueue(label: "AsyncImageCache.network")
    private static let slots = DispatchSemaphore(value: 6)

    /// Fetches `url`, reading at most `limit` bytes of body, and passes the body (or nil) to `done`, on the
    /// download's own queue.
    static func fetch(_ url: URL, limit: Int, _ done: @escaping @Sendable (Data?) -> Void) {
        queue.async {
            slots.wait()
            DispatchQueue(label: "AsyncImageCache.download").async {
                let body = download(url, limit: limit)
                slots.signal()
                done(body)
            }
        }
    }

    /// The body of `url` after its redirects, or nil.
    private static func download(_ url: URL, limit: Int) -> Data? {
        guard let session else {
            return nil
        }
        var address = url
        for _ in 0...maximumRedirects {
            switch request(address, session: session, limit: limit) {
            case .body(let data):
                return data.isEmpty ? nil : data
            case .redirect(let next):
                address = next
            case .failed:
                return nil
            }
        }
        return nil
    }

    private enum Outcome {
        case body(Data)
        case redirect(URL)
        case failed
    }

    /// One GET of `url`: its body, the address its redirect names, or a failure.
    private static func request(_ url: URL, session: Handle, limit: Int) -> Outcome {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            return .failed
        }
        let secure = scheme == "https"
        let port = components.port ?? (secure ? 443 : 80)
        guard (1...65535).contains(port) else {
            return .failed
        }
        // The path and query as the URL has them (escaped); a URL's user and password are never sent.
        var object = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery {
            object += "?" + query
        }
        let connected = host.withCString(encodedAs: UTF16.self) { WinHttpConnect(session.raw, $0, INTERNET_PORT(port), 0) }
        guard let connection = Handle(connected) else {
            return .failed
        }
        let opened = "GET".withCString(encodedAs: UTF16.self) { verb in
            object.withCString(encodedAs: UTF16.self) { name in
                WinHttpOpenRequest(connection.raw, verb, name, nil, nil, nil, secure ? DWORD(WINHTTP_FLAG_SECURE) : 0)
            }
        }
        guard let request = Handle(opened) else {
            return .failed
        }
        // No cookies, no redirects, no answers to sign-in challenges; never the Windows account's credentials.
        var features = DWORD(WINHTTP_DISABLE_COOKIES) | DWORD(WINHTTP_DISABLE_REDIRECTS)
            | DWORD(WINHTTP_DISABLE_AUTHENTICATION)
        var autologon = DWORD(WINHTTP_AUTOLOGON_SECURITY_LEVEL_HIGH)
        guard WinHttpSetOption(request.raw, DWORD(WINHTTP_OPTION_DISABLE_FEATURE), &features,
                               DWORD(MemoryLayout<DWORD>.size)),
              WinHttpSetOption(request.raw, DWORD(WINHTTP_OPTION_AUTOLOGON_POLICY), &autologon,
                               DWORD(MemoryLayout<DWORD>.size)),
              WinHttpSendRequest(request.raw, nil, 0, nil, 0, 0, 0),
              WinHttpReceiveResponse(request.raw, nil),
              let status = numberHeader(request, DWORD(WINHTTP_QUERY_STATUS_CODE)) else {
            return .failed
        }
        if redirectStatuses.contains(status) {
            // A relative Location is read against this address; the redirect's own body is dropped unread.
            guard let location = stringHeader(request, DWORD(WINHTTP_QUERY_LOCATION)),
                  let next = URL(string: location, relativeTo: url)?.absoluteURL,
                  let nextScheme = next.scheme?.lowercased(), nextScheme == "http" || nextScheme == "https" else {
                return .failed
            }
            return .redirect(next)
        }
        guard (200...299).contains(status) else {
            return .failed
        }
        if let declared = contentLength(request), declared > UInt64(limit) {
            return .failed
        }
        var body = Data()
        var piece = [UInt8](repeating: 0, count: pieceSize)
        while true {
            var read: DWORD = 0
            let received = piece.withUnsafeMutableBytes { buffer in
                WinHttpReadData(request.raw, buffer.baseAddress, DWORD(buffer.count), &read)
            }
            guard received else {
                return .failed
            }
            if read == 0 {
                return .body(body)
            }
            guard Int(read) <= limit - body.count else {
                return .failed
            }
            body.append(contentsOf: piece[0..<Int(read)])
        }
    }

    /// A header as a number (the status code), or nil.
    private static func numberHeader(_ request: Handle, _ query: DWORD) -> DWORD? {
        var value: DWORD = 0
        var length = DWORD(MemoryLayout<DWORD>.size)
        guard WinHttpQueryHeaders(request.raw, query | DWORD(WINHTTP_QUERY_FLAG_NUMBER), nil, &value, &length, nil) else {
            return nil
        }
        return value
    }

    /// The Content-Length the response declares, or nil when it declares none.
    private static func contentLength(_ request: Handle) -> UInt64? {
        var value: UInt64 = 0
        var length = DWORD(MemoryLayout<UInt64>.size)
        guard WinHttpQueryHeaders(request.raw, DWORD(WINHTTP_QUERY_CONTENT_LENGTH) | DWORD(WINHTTP_QUERY_FLAG_NUMBER64),
                                  nil, &value, &length, nil) else {
            return nil
        }
        return value
    }

    /// A header as text (the Location), or nil.
    private static func stringHeader(_ request: Handle, _ query: DWORD) -> String? {
        var length: DWORD = 0
        // The first call fails and gives the length in bytes.
        _ = WinHttpQueryHeaders(request.raw, query, nil, nil, &length, nil)
        guard length > 0, length < 64 * 1024 else {
            return nil
        }
        var buffer = [UInt16](repeating: 0, count: Int(length) / 2 + 1)
        let read = buffer.withUnsafeMutableBytes { raw in
            WinHttpQueryHeaders(request.raw, query, nil, raw.baseAddress, &length, nil)
        }
        guard read else {
            return nil
        }
        return String(decoding: buffer.prefix(Int(length) / 2), as: UTF16.self)
    }
}

#endif
