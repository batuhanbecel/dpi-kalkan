import Foundation

/// DNS-over-HTTPS (Cloudflare 1.1.1.1, JSON API) ile A kaydı çözer.
/// Sağlayıcı DNS'i zehirlediğinde kullanılır; IP ile bağlandığı için kendisi engellenmez.
public final class DoHResolver: @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()
    private var cache: [String: (ip: String, expires: Date)] = [:]

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config)
    }

    public func resolve(_ host: String, completion: @escaping (String?) -> Void) {
        if isIPAddress(host) { return completion(host) }
        lock.lock()
        if let hit = cache[host], hit.expires > Date() {
            lock.unlock()
            return completion(hit.ip)
        }
        lock.unlock()

        var comps = URLComponents(string: "https://1.1.1.1/dns-query")!
        comps.queryItems = [.init(name: "name", value: host), .init(name: "type", value: "A")]
        var req = URLRequest(url: comps.url!)
        req.setValue("application/dns-json", forHTTPHeaderField: "Accept")

        session.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answers = json["Answer"] as? [[String: Any]],
                  let a = answers.first(where: { ($0["type"] as? Int) == 1 }),
                  let ip = a["data"] as? String
            else { return completion(nil) }
            let ttl = max(60, a["TTL"] as? Int ?? 300)
            self.lock.lock()
            self.cache[host] = (ip, Date().addingTimeInterval(TimeInterval(ttl)))
            self.lock.unlock()
            completion(ip)
        }.resume()
    }

    private func isIPAddress(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }
}
