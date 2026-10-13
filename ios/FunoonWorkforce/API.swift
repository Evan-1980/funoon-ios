import Foundation
import Security
import CryptoKit
import UserNotifications

enum Configuration {
    static let origin = URL(string: "https://funoon-workforce.evan80.chatgpt.site")!
}
@MainActor
enum TaskReminders {
    static let prefix = "funoon-task-"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "taskRemindersEnabled") }
    static func clear() async {
        UserDefaults.standard.set(false, forKey: "taskRemindersEnabled")
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix(prefix) }.map(\.identifier))
        let shown = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers: shown.filter { $0.request.identifier.hasPrefix(prefix) }.map { $0.request.identifier })
        UserDefaults.standard.removeObject(forKey: "taskReminderIDs")
    }
    static func sync(secret: String, askPermission: Bool = false) async throws -> Int {
        let center = UNUserNotificationCenter.current()
        if askPermission {
            guard try await center.requestAuthorization(options: [.alert,.sound]) else { throw APIError(status: 400,message: "اسمح بإشعارات التطبيق من إعدادات الآيفون") }
            UserDefaults.standard.set(true, forKey: "taskRemindersEnabled")
        }
        guard enabled else { return 0 }
        let response = try await API.send("tasks",secret: secret)
        guard enabled, try SecureStore.read() == secret, let rows = response["rows"] as? [[String:Any]], let expires = API.date(response["deviceExpiresAt"] as? String ?? "") else { return 0 }
        let old = Set(UserDefaults.standard.stringArray(forKey: "taskReminderIDs") ?? [])
        var keep = Set<String>(), requests: [UNNotificationRequest] = []
        for row in rows.prefix(20) {
            guard let id = row["id"] as? String, let revision = row["revision"] as? Int, let due = API.date(row["remind_at"] as? String ?? ""), due <= expires, expires > Date() else { continue }
            let key = prefix + id + ":" + String(revision);keep.insert(key)
            if due <= Date(),old.contains(key) { continue }
            let content = UNMutableNotificationContent();content.title = "فنون الرافدين · تذكير بمهمة";content.body = "حان موعد تذكيرك. افتح البرنامج لمراجعة مهام حسابك.";content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1,due.timeIntervalSinceNow), repeats: false)
            requests.append(UNNotificationRequest(identifier: key,content: content,trigger: trigger))
        }
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix(prefix) }.map(\.identifier))
        let shown = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers: shown.filter { $0.request.identifier.hasPrefix(prefix) && !keep.contains($0.request.identifier) }.map { $0.request.identifier })
        guard enabled,try SecureStore.read() == secret else { return 0 }
        for request in requests { try await center.add(request) }
        UserDefaults.standard.set(Array(keep),forKey: "taskReminderIDs")
        return requests.count
    }
}
struct APIError: Error, LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
    var terminal: Bool { [401,403,409,410].contains(status) }
}
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
enum API {
    private static let redirects = NoRedirect()
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 25
        return URLSession(configuration: c, delegate: redirects, delegateQueue: nil)
    }()
    static func send(_ route: String, method: String = "GET", body: [String:Any]? = nil, secret: String? = nil) async throws -> [String:Any] {
        let url = Configuration.origin.appendingPathComponent("api/mobile/" + route)
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let secret { r.setValue(secret, forHTTPHeaderField: "X-Funoon-Device-Token") }
        if let body { r.setValue("application/json", forHTTPHeaderField: "Content-Type");r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (bytes,response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse, bytes.count <= 131072 else { throw APIError(status: 502,message: "تعذر قراءة حالة برنامج الشركة") }
        let result = (try? JSONSerialization.jsonObject(with: bytes)) as? [String:Any]
        guard (200...299).contains(http.statusCode), let result else { throw APIError(status: http.statusCode,message: result?["error"] as? String ?? "تعذر الاتصال؛ اربط الهاتف من جديد إذا انتهت الصلاحية") }
        return result
    }
    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter();f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
enum SecureStore {
    private static let service = "com.funoon.workforce.device"
    static func read() throws -> String? {
        let q: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"capability",kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data, let s = String(data: bytes,encoding: .utf8) else { throw APIError(status: 500,message: "تعذر فتح صلاحية الجهاز المحفوظة") }
        return s
    }
    static func write(_ secret: String) throws {
        clear()
        let q: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"capability",kSecValueData as String:Data(secret.utf8),kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        guard SecItemAdd(q as CFDictionary,nil) == errSecSuccess else { throw APIError(status: 500,message: "تعذر حفظ صلاحية الجهاز") }
    }
    static func clear() { SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"capability"] as CFDictionary) }
    static func create() throws -> String {
        var bytes = [UInt8](repeating: 0,count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault,$0.count,$0.baseAddress!) }
        guard status == errSecSuccess else { throw APIError(status: 500,message: "تعذر إنشاء رمز جهاز آمن") }
        return bytes.map { String(format: "%02x",$0) }.joined()
    }
    static func hash(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x",$0) }.joined() }
}
