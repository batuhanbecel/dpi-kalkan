import Testing
@testable import KalkanCore

/// SNI'si `host` olan en küçük geçerli ClientHello kaydını üretir.
private func makeClientHello(host: String) -> [UInt8] {
    let name = Array(host.utf8)
    let sniData: [UInt8] = [UInt8((name.count + 3) >> 8), UInt8((name.count + 3) & 0xff), 0x00,
                            UInt8(name.count >> 8), UInt8(name.count & 0xff)] + name
    let sniExt: [UInt8] = [0x00, 0x00, UInt8(sniData.count >> 8), UInt8(sniData.count & 0xff)] + sniData
    let otherExt: [UInt8] = [0x00, 0x0b, 0x00, 0x02, 0x01, 0x00]
    let exts = otherExt + sniExt
    var body: [UInt8] = [0x03, 0x03] + [UInt8](repeating: 0xaa, count: 32)
    body += [0x00]                         // session id
    body += [0x00, 0x02, 0x13, 0x01]       // cipher suites
    body += [0x01, 0x00]                   // compression
    body += [UInt8(exts.count >> 8), UInt8(exts.count & 0xff)] + exts
    let hs: [UInt8] = [0x01, 0x00, UInt8(body.count >> 8), UInt8(body.count & 0xff)] + body
    return [0x16, 0x03, 0x01, UInt8(hs.count >> 8), UInt8(hs.count & 0xff)] + hs
}

@Test func parsesServerName() {
    let hello = makeClientHello(host: "gateway.discord.gg")
    guard case .clientHello(let info) = TLSFragmenter.parse(hello) else {
        Issue.record("ClientHello tanınmadı"); return
    }
    #expect(info.serverName == "gateway.discord.gg")
    #expect(info.recordLength == hello.count)
    let off = info.serverNameOffset!
    #expect(Array(hello[off..<(off + 18)]) == Array("gateway.discord.gg".utf8))
}

@Test func needsMoreDataForPartialRecord() {
    let hello = makeClientHello(host: "discord.com")
    #expect(TLSFragmenter.parse(Array(hello.prefix(20))) == .needMoreData)
    #expect(TLSFragmenter.parse([0x47, 0x45, 0x54]) == .notClientHello)
}

@Test func tcpSegmentSplitsInsideHostName() {
    let hello = makeClientHello(host: "discord.com") + [0x99]
    guard case .clientHello(let info) = TLSFragmenter.parse(hello) else { return }
    let pieces = TLSFragmenter.fragment(hello, info: info, mode: .tcpSegment)
    #expect(pieces.count == 2)
    #expect(pieces.joined().elementsEqual(hello))
    #expect(!pieces[0].elementsEqual("discord.com".utf8) && pieces[0].count > info.serverNameOffset!)
}

@Test func tlsRecordSplitProducesTwoValidRecords() {
    let hello = makeClientHello(host: "discord.com")
    guard case .clientHello(let info) = TLSFragmenter.parse(hello) else { return }
    for mode in [FragmentMode.tlsRecord, .both] {
        let out = TLSFragmenter.fragment(hello, info: info, mode: mode).flatMap { $0 }
        let len1 = Int(out[3]) << 8 | Int(out[4])
        let second = Array(out[(5 + len1)...])
        let len2 = Int(second[3]) << 8 | Int(second[4])
        #expect(second[0] == 0x16 && second.count == 5 + len2)
        #expect(Array(out[5..<(5 + len1)]) + Array(second[5...]) == Array(hello[5...]))
    }
}

@Test func recordHeaderSplitHidesHandshakeLength() {
    let hello = makeClientHello(host: "updates.discord.com") + [0x99]
    guard case .clientHello(let info) = TLSFragmenter.parse(hello) else { return }
    let pieces = TLSFragmenter.fragment(hello, info: info, mode: .recordHeader)
    #expect(pieces.count == 2)
    let out = pieces.flatMap { $0 }
    // İlk kayıt yalnızca el sıkışma türünü taşır.
    #expect(Array(out[0..<6]) == [0x16, 0x03, 0x01, 0x00, 0x01, 0x01])
    let len2 = Int(out[9]) << 8 | Int(out[10])
    #expect(out[6] == 0x16 && 11 + len2 == info.recordLength + 5)
    #expect([out[5]] + Array(out[11..<(11 + len2)]) == Array(hello[5..<info.recordLength]))
    #expect(out.last == 0x99)
    // TCP kesimi ana bilgisayar adının içinden geçer.
    let nameStart = info.serverNameOffset! + 5
    #expect(pieces[0].count > nameStart && pieces[0].count < nameStart + 19)
}

@Test func domainMatching() {
    #expect(DomainList.matches("cdn.discordapp.com", in: DomainList.discord))
    #expect(DomainList.matches("Discord.com.", in: DomainList.discord))
    #expect(!DomainList.matches("notdiscord.com", in: DomainList.discord))
}

@Test func hostPortParsing() {
    #expect(ProxySession.splitHostPort("discord.com:443", defaultPort: 1)! == ("discord.com", 443))
    #expect(ProxySession.splitHostPort("[::1]:8080", defaultPort: 1)! == ("::1", 8080))
    #expect(ProxySession.splitHostPort("example.org", defaultPort: 80)! == ("example.org", 80))
}

@Test func strategyOrderPrefersRememberedMode() {
    let cache = StrategyCache()
    #expect(cache.order(for: "bank.com.tr", preferred: .recordHeader) == [.recordHeader, .tcpSegment])
    cache.remember(.tcpSegment, for: "bank.com.tr")
    #expect(cache.order(for: "bank.com.tr", preferred: .recordHeader) == [.tcpSegment, .recordHeader])
    #expect(cache.order(for: "x.com", preferred: .tcpSegment) == [.tcpSegment])
}

@Test func pacRoutesListedDomainsOnly() {
    var config = ProxyConfig()
    config.port = 8881
    config.onlyListedDomains = true
    config.domains = ["discord.com"]
    let pac = PACScript.make(config: config)
    #expect(pac.contains("\"discord.com\""))
    #expect(pac.contains("PROXY 127.0.0.1:8881; DIRECT"))
    config.onlyListedDomains = false
    #expect(!PACScript.make(config: config).contains("var list"))
}
