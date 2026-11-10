import Foundation

/// Forwards TUS requests to the real server and injects network faults on the way,
/// so retry, offset resync, and resume can be checked against real Bunny without
/// touching the machine's network. Used only by the fault test (`--fault-test`).
public final class FaultInjectingURLProtocol: URLProtocol, @unchecked Sendable {
    /// Probability of each fault per request (0...1). Only `tusupload` requests get faults.
    public struct Faults: Sendable, Equatable {
        /// The connection drops before the request reaches the server.
        public var dropBeforeSend: Double
        /// The server gets the request, but the response is lost.
        public var dropAfterSend: Double
        /// The server answers 503 without handling the request.
        public var serviceUnavailable: Double

        public init(dropBeforeSend: Double = 0, dropAfterSend: Double = 0, serviceUnavailable: Double = 0) {
            self.dropBeforeSend = dropBeforeSend
            self.dropAfterSend = dropAfterSend
            self.serviceUnavailable = serviceUnavailable
        }
    }

    public enum Kind: String, CaseIterable, Sendable {
        case dropBeforeSend
        case dropAfterSend
        case serviceUnavailable
    }

    /// Counters and settings shared by all protocol instances.
    public final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var _faults = Faults()
        private var _injected: [Kind: Int] = [:]
        private var _forwardedBodyBytes: Int64 = 0
        private var _random: () -> Double = { Double.random(in: 0..<1) }

        public var faults: Faults {
            get { lock.withLock { _faults } }
            set { lock.withLock { _faults = newValue } }
        }

        public var injected: [Kind: Int] {
            lock.withLock { _injected }
        }

        /// PATCH body bytes that reached the server.
        public var forwardedBodyBytes: Int64 {
            lock.withLock { _forwardedBodyBytes }
        }

        /// Replaces the random source (tests).
        public func setRandom(_ random: @escaping () -> Double) {
            lock.withLock {
                _random = random
            }
        }

        public func reset() {
            lock.withLock {
                _injected = [:]
                _forwardedBodyBytes = 0
            }
        }

        func pick(for request: URLRequest) -> Kind? {
            guard request.url?.absoluteString.contains("tusupload") == true else { return nil }
            return lock.withLock {
                let roll = _random()
                var edge = 0.0
                for (kind, chance) in [
                    (Kind.dropBeforeSend, _faults.dropBeforeSend),
                    (.serviceUnavailable, _faults.serviceUnavailable),
                    (.dropAfterSend, _faults.dropAfterSend),
                ] {
                    edge += chance
                    if roll < edge {
                        _injected[kind, default: 0] += 1
                        return kind
                    }
                }
                return nil
            }
        }

        func addForwarded(_ bytes: Int) {
            lock.withLock {
                _forwardedBodyBytes += Int64(bytes)
            }
        }
    }

    public static let state = State()

    /// Session that really sends the requests (no custom protocols, many connections).
    nonisolated(unsafe) static var forwardingSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 128
        config.timeoutIntervalForRequest = 600
        return URLSession(configuration: config)
    }()

    /// A session configuration whose requests go through this protocol.
    public static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FaultInjectingURLProtocol.self]
        config.timeoutIntervalForRequest = 600
        return config
    }

    private var forwardTask: URLSessionTask?

    override public class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override public func startLoading() {
        let fault = Self.state.pick(for: request)
        switch fault {
        case .dropBeforeSend:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        case .serviceUnavailable:
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        default:
            break
        }

        var forwarded = request
        let body = Self.readBody(of: request)
        forwarded.httpBodyStream = nil
        let completion: @Sendable (Data?, URLResponse?, Error?) -> Void = { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            if let body, self.request.httpMethod == "PATCH", let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                Self.state.addForwarded(body.count)
            }
            if fault == .dropAfterSend {
                self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            if let response {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            if let data {
                self.client?.urlProtocol(self, didLoad: data)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        let session = Self.forwardingSession
        if let body {
            forwardTask = session.uploadTask(with: forwarded, from: body, completionHandler: completion)
        } else {
            forwardTask = session.dataTask(with: forwarded, completionHandler: completion)
        }
        forwardTask?.resume()
    }

    override public func stopLoading() {
        forwardTask?.cancel()
    }

    /// Body of an upload request (URLProtocol sees upload bodies as a stream).
    static func readBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 {
                break
            }
            data.append(buffer, count: n)
        }
        return data
    }
}
