import Foundation

/// Sistem proxy ayarına verilen otomatik yapılandırma (PAC) dosyası.
/// "PROXY …; DIRECT" sayesinde uygulama kapalıyken ya da çökmüşken internet doğrudan çalışmaya devam eder.
public enum PACScript {
    public static let path = "/proxy.pac"

    public static func url(port: UInt16, version: Int = 0) -> String {
        "http://127.0.0.1:\(port)\(path)?v=\(version)"
    }

    public static func make(config: ProxyConfig) -> String {
        let proxy = "PROXY 127.0.0.1:\(config.port); DIRECT"
        let route: String
        if config.onlyListedDomains {
            let list = config.domains.map { "\"\($0.lowercased())\"" }.joined(separator: ", ")
            route = """
              var list = [\(list)];
              for (var i = 0; i < list.length; i++) {
                if (host == list[i] || dnsDomainIs(host, "." + list[i])) return "\(proxy)";
              }
              return "DIRECT";
            """
        } else {
            route = "  return \"\(proxy)\";"
        }
        return """
        function FindProxyForURL(url, host) {
          host = host.toLowerCase();
          if (isPlainHostName(host) || host == "localhost" || dnsDomainIs(host, ".local")) return "DIRECT";
          // IP adresleri doğrudan: SNI'siz bağlantıların bölünmeye ihtiyacı yok ve proxy'nin kendi
          // giden bağlantıları da IP ile kurulduğu için bu kural döngüyü önler.
          if (/^[0-9.]+$/.test(host) || host.indexOf(":") >= 0) return "DIRECT";
        \(route)
        }

        """
    }
}
