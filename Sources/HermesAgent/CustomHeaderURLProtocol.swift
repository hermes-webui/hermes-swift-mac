import Foundation

/// URLProtocol that intercepts HTTP/HTTPS requests from WKWebView
/// and adds custom headers stored in UserDefaults.
///
/// Registered dynamically in BrowserWindowController before the WebView loads.
/// Header key-value pairs are stored as JSON array under the `customHeaders` key.
final class CustomHeaderURLProtocol: URLProtocol {

    private static let handledKey = "CustomHeaderURLProtocolHandled"
    private static let storageKey = "customHeaders"

    /// Returns the custom headers stored in UserDefaults.
    static func loadCustomHeaders() -> [(name: String, value: String)] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        return json.compactMap { dict in
            guard let name = dict["name"], let value = dict["value"], !name.isEmpty else { return nil }
            return (name, value)
        }
    }

    /// Save custom headers to UserDefaults (replaces existing).
    static func saveCustomHeaders(_ headers: [(name: String, value: String)]) {
        let json = headers.map { ["name": $0.name, "value": $0.value] }
        let data = try? JSONSerialization.data(withJSONObject: json)
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    // MARK: - URLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool {
        // Only intercept http/https schemes
        guard let scheme = request.url?.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return false }
        // Avoid re-processing requests we've already modified
        if URLProtocol.property(forKey: handledKey, in: request) != nil { return false }
        // Only intercept if there are custom headers configured
        return !loadCustomHeaders().isEmpty
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let mutableRequest = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        // Mark as handled to prevent infinite recursion
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutableRequest)

        // Add custom headers
        let headers = Self.loadCustomHeaders()
        for header in headers {
            mutableRequest.setValue(header.value, forHTTPHeaderField: header.name)
        }

        let newRequest = mutableRequest as URLRequest
        let session = URLSession.shared
        let task = session.dataTask(with: newRequest) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            if let response = response, let data = data {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        task.resume()
    }

    override func stopLoading() {
        // The URLSessionTask is automatically handled; no extra cleanup needed.
    }
}
