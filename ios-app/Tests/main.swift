import Foundation

var assertions = 0
func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
    guard try condition() else { fatalError("FAILED: \(name)") }
    assertions += 1
}
func rejects(_ name: String, _ operation: () throws -> Void) {
    do { try operation() } catch { assertions += 1; return }
    fatalError("Expected rejection: \(name)")
}

let config = try AppConfiguration(baseURL: "https://support.example.com", scheme: "ifengadmin")
try check(config.adminURL.absoluteString == "https://support.example.com/app/", "actual admin route")
let targetURL = config.conversationURL(accountID: 2, conversationID: 123)
try check(targetURL.absoluteString == "https://support.example.com/app/?account_id=2&conversation_id=123", "account and conversation")
let alternate = try AppConfiguration(baseURL: "https://support.example.net:8443/", scheme: "ifengadmin")
try check(alternate.conversationURL(accountID: 3, conversationID: 44).host == "support.example.net", "configurable domain")
try check(alternate.adminURL.port == 8443, "configured port")
let bareServer = try config.selectingServer("  help.example.net  ")
let runtimePort = try config.selectingServer("https://help.example.net:8443/")
try check(bareServer.adminURL.absoluteString == "https://help.example.net/app/", "bare server domain")
try check(runtimePort.adminURL.port == 8443, "runtime server port")
for address in ["", "bad domain.example.com", "http://help.example.net", "https://user:secret@help.example.net", "https://help.example.net/app/", "https://help.example.net?token=x"] {
    rejects("invalid runtime server") { _ = try config.selectingServer(address) }
}

for origin in ["http://support.example.com", "https://u:p@support.example.com", "https://support.example.com/app/", "https://support.example.com?a=b", "https://support.example.com/#token", ""] {
    rejects("bad origin") { _ = try AppConfiguration(baseURL: origin, scheme: "ifengadmin") }
}
for scheme in ["http", "https", "中文", "0app", "app://", "javascript"] {
    rejects("bad scheme") { _ = try AppConfiguration(baseURL: "https://support.example.com", scheme: scheme) }
}
let link = try ConversationTarget.parse(URL(string: "ifengadmin://conversation/123?account_id=2")!, scheme: "ifengadmin")
try check(link == ConversationTarget(conversationID: 123, accountID: 2), "deep link")
let noAccount = try ConversationTarget.parse(URL(string: "ifengadmin://conversation/123")!, scheme: "ifengadmin")
try check(noAccount.accountID == nil, "use logged-in account")
do {
    _ = try ConversationTarget.parse(URL(string: "ifengadmin://")!, scheme: "ifengadmin")
    fatalError("home link not recognized")
} catch LinkError.openHome { assertions += 1 }
for value in ["other://conversation/1", "ifengadmin://conversation/0", "ifengadmin://conversation/-1", "ifengadmin://conversation/1/extra", "ifengadmin://conversation/9007199254740992", "ifengadmin://conversation/1?account_id=2&account_id=3", "ifengadmin://conversation/1?token=x", "ifengadmin://conversation/1?account_id=abc", "ifengadmin://user@conversation/1", "ifengadmin://conversation/1#x", "ifengadmin://conversation/1%2F2"] {
    rejects("bad deep link \(value)") { _ = try ConversationTarget.parse(URL(string: value)!, scheme: "ifengadmin") }
}
let policy = NavigationPolicy(configuration: config)
try check(policy.destination(for: targetURL, userInitiated: false) == .internalPage, "internal route")
try check(policy.destination(for: URL(string: "https://external.example.com")!, userInitiated: true) == .externalBrowser, "external tap")
try check(policy.destination(for: URL(string: "https://external.example.com")!, userInitiated: false) == .blocked, "external redirect blocked")
try check(policy.destination(for: URL(string: "http://support.example.com")!, userInitiated: true) == .blocked, "TLS downgrade blocked")
try check(policy.destination(for: URL(string: "https://support.example.com.evil.net")!, userInitiated: false) == .blocked, "host spoof blocked")
try check(policy.destination(for: URL(string: "mailto:test@example.com")!, userInitiated: true) == .externalApplication, "mail link")
try check(policy.destination(for: URL(string: "javascript:alert(1)")!, userInitiated: true) == .blocked, "script link blocked")
try check(policy.destination(for: URL(string: "file:///etc/passwd")!, userInitiated: true) == .blocked, "file link blocked")
try check(policy.destination(for: URL(string: "blob:https://support.example.com/123")!, userInitiated: false) == .localPreview, "own blob")
try check(policy.destination(for: URL(string: "blob:https://evil.example.com/123")!, userInitiated: false) == .blocked, "foreign blob")
print("Passed \(assertions) native URL and navigation assertions")
