import Foundation
import KalkanCore

// Arayüzsüz çalıştırma ve test için: kalkan-cli [port] [recordHeader|tcpSegment|tlsRecord|both] [--all] [--doh]
setvbuf(stdout, nil, _IOLBF, 0)
var config = ProxyConfig()
var args = CommandLine.arguments.dropFirst()
if let p = args.first.flatMap(UInt16.init) { config.port = p; args = args.dropFirst() }
if let m = args.first.flatMap(FragmentMode.init(rawValue:)) { config.mode = m; args = args.dropFirst() }
if args.contains("--all") { config.onlyListedDomains = false }
if args.contains("--doh") { config.useDoH = true }
if args.contains("-v") { config.verbose = true }

let server = ProxyServer(config: config)
server.onLog = { print($0) }
server.onStateChange = { running, error in
    if !running, let error { print("Durdu: \(error)"); exit(1) }
}
try server.start()
dispatchMain()
