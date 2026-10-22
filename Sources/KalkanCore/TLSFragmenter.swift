import Foundation

/// TLS ClientHello'yu DPI'nin SNI'yi tek parçada göremeyeceği şekilde böler.
public enum FragmentMode: String, CaseIterable, Codable, Sendable {
    /// İlk TLS kaydına yalnızca el sıkışma türü baytını koyar, kalanını SNI ortasından
    /// ayrı TCP segmentinde gönderir. DPI ilk kayıtta el sıkışma uzunluğunu okuyamayınca
    /// kayıtları birleştirmeyi bırakıyor; Discord güncelleyicisinin kısa ClientHello'su
    /// yalnızca bu yöntemle geçiyor.
    case recordHeader
    /// Aynı TLS kaydını iki ayrı TCP segmentinde gönderir.
    case tcpSegment
    /// ClientHello'yu iki ayrı TLS kaydına böler (tek gönderim).
    case tlsRecord
    /// İkisi birden: iki TLS kaydı, iki ayrı TCP segmenti.
    case both

    public var title: String {
        switch self {
        case .recordHeader: "Kayıt başı (önerilen)"
        case .tcpSegment: "TCP segment"
        case .tlsRecord: "TLS kayıt"
        case .both: "TLS kayıt + TCP segment"
        }
    }
}

public struct ClientHelloInfo: Equatable, Sendable {
    /// Bütün kaydın (5 bayt başlık dahil) uzunluğu.
    public let recordLength: Int
    /// SNI'deki ana bilgisayar adı ve kayıt içindeki başlangıç ofseti.
    public let serverName: String?
    public let serverNameOffset: Int?
}

public enum TLSFragmenter {
    public enum ParseResult: Equatable {
        case needMoreData
        case notClientHello
        case clientHello(ClientHelloInfo)
    }

    /// Tamponun başında bir TLS ClientHello kaydı var mı bakar ve SNI konumunu bulur.
    public static func parse(_ buf: [UInt8]) -> ParseResult {
        guard buf.count >= 6 else {
            if let first = buf.first, first != 0x16 { return .notClientHello }
            return .needMoreData
        }
        guard buf[0] == 0x16, buf[1] == 0x03, buf[5] == 0x01 else { return .notClientHello }
        let payloadLength = Int(buf[3]) << 8 | Int(buf[4])
        let recordLength = 5 + payloadLength
        guard buf.count >= recordLength else { return .needMoreData }

        let sni = findServerName(buf, recordEnd: recordLength)
        return .clientHello(ClientHelloInfo(
            recordLength: recordLength,
            serverName: sni?.name,
            serverNameOffset: sni?.offset
        ))
    }

    private static func findServerName(_ b: [UInt8], recordEnd: Int) -> (name: String, offset: Int)? {
        // 5: kayıt başlığı, 4: el sıkışma başlığı, 2: sürüm, 32: random
        var i = 5 + 4 + 2 + 32
        func u8() -> Int? { guard i < recordEnd else { return nil }; defer { i += 1 }; return Int(b[i]) }
        func u16() -> Int? { guard i + 1 < recordEnd else { return nil }; defer { i += 2 }; return Int(b[i]) << 8 | Int(b[i + 1]) }

        guard let sessionLen = u8() else { return nil }
        i += sessionLen
        guard let suitesLen = u16() else { return nil }
        i += suitesLen
        guard let compLen = u8() else { return nil }
        i += compLen
        guard let extTotal = u16() else { return nil }
        let extEnd = min(i + extTotal, recordEnd)

        while i + 4 <= extEnd {
            guard let type = u16(), let len = u16() else { return nil }
            let dataStart = i
            if type == 0x0000 {
                // server_name_list uzunluğu (2), name_type (1), ad uzunluğu (2)
                i += 3
                guard let nameLen = u16(), i + nameLen <= extEnd else { return nil }
                let name = String(decoding: b[i..<(i + nameLen)], as: UTF8.self)
                return (name, i)
            }
            i = dataStart + len
        }
        return nil
    }

    /// Gönderilecek parçaları döndürür. Her eleman ayrı bir TCP gönderimi olmalıdır.
    public static func fragment(_ buf: [UInt8], info: ClientHelloInfo, mode: FragmentMode) -> [[UInt8]] {
        let record = Array(buf[0..<info.recordLength])
        let rest = Array(buf[info.recordLength...])

        // SNI yoksa yine de kaydın başından bölmek çoğu DPI'yi atlatır.
        let split: Int
        if let off = info.serverNameOffset, let name = info.serverName, !name.isEmpty {
            split = off + max(1, name.utf8.count / 2)
        } else {
            split = min(info.recordLength - 1, 6)
        }

        switch mode {
        case .recordHeader:
            // İlk kayıt: 5 bayt başlık + 1 bayt yük. Araya giren ikinci başlık SNI'yi 5 bayt kaydırır.
            let (a, b) = splitRecord(record, at: 6)
            let out = a + b + rest
            let cut = split + 5
            return [Array(out[0..<cut]), Array(out[cut...])]
        case .tcpSegment:
            return [Array(record[0..<split]), Array(record[split...]) + rest]
        case .tlsRecord:
            let (a, b) = splitRecord(record, at: split)
            return [a + b + rest]
        case .both:
            let (a, b) = splitRecord(record, at: split)
            return [a, b + rest]
        }
    }

    /// Bir TLS kaydını, yük içinde `at` noktasından iki geçerli kayda böler.
    static func splitRecord(_ record: [UInt8], at absolute: Int) -> ([UInt8], [UInt8]) {
        let payload = Array(record[5...])
        let cut = max(1, min(payload.count - 1, absolute - 5))
        func header(_ len: Int) -> [UInt8] { [record[0], record[1], record[2], UInt8(len >> 8), UInt8(len & 0xff)] }
        return (header(cut) + payload[0..<cut], header(payload.count - cut) + payload[cut...])
    }
}
