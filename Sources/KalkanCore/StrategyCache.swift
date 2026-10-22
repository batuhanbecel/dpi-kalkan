import Foundation

/// Hangi sitede hangi bölme yönteminin işe yaradığını proxy çalıştığı sürece hatırlar.
/// Bazı sunucular (ör. bankalar) TLS kayıt bölmeyi reddediyor; onlar için TCP segment bölme seçilir.
final class StrategyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var working: [String: FragmentMode] = [:]

    /// Denenecek yöntemler: önce bu sitede çalışmış olan, sonra tercih edilen, en son sunucuya görünmeyen TCP bölme.
    func order(for host: String, preferred: FragmentMode) -> [FragmentMode] {
        lock.lock()
        let known = working[host]
        lock.unlock()
        var result: [FragmentMode] = []
        for mode in [known, preferred, .tcpSegment].compactMap({ $0 }) where !result.contains(mode) {
            result.append(mode)
        }
        return result
    }

    func remember(_ mode: FragmentMode, for host: String) {
        lock.lock()
        working[host] = mode
        lock.unlock()
    }
}
