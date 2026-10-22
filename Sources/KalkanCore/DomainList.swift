import Foundation

public enum DomainList {
    /// "Yalnızca listedeki siteler" kipinin başlangıç listesi.
    public static let defaults: [String] = discord + ["wattpad.com"]

    /// Discord'un kullandığı alan adları.
    /// `discord.com`, `discordapp.com`, `cdn.discordapp.com`, `gateway.discord.gg`, `updates.discord.com`
    /// Discord.app/Contents/Resources/app.asar içinden REA ile çıkarıldı; geri kalanı
    /// web istemcisinin (discord.com'dan uzaktan yüklenen) kullandığı bilinen alan adlarıdır.
    public static let discord: [String] = [
        "discord.com",
        "discordapp.com",
        "discord.gg",
        "discordapp.net",
        "discord.media",
        "discordcdn.com",
        "discord.co",
        "discord.dev",
        "discord.new",
        "discord.gift",
        "discord.gifts",
        "discordstatus.com",
        "discordactivities.com",
        "discordsays.com",
        "discordmerch.com",
        "dis.gd",
    ]

    /// `host` listedeki bir alan adına ya da alt alan adına uyuyor mu.
    public static func matches(_ host: String, in list: [String]) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return list.contains { h == $0 || h.hasSuffix("." + $0) }
    }
}
