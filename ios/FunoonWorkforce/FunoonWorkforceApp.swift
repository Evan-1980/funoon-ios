import SwiftUI
import UIKit
import UserNotifications

@main
@MainActor
struct FunoonWorkforceApp: App {
    @StateObject private var tracker = Tracker()
    @Environment(\.scenePhase) private var scene
    init() {
        UNUserNotificationCenter.current().delegate = TaskNotificationDelegate.shared
    }
    var body: some Scene {
        WindowGroup {
            ContentView(tracker: tracker)
                .environment(\.layoutDirection,.rightToLeft)
                .task { await tracker.refresh() }
                .onChange(of: scene) { phase in if phase == .active { Task { await tracker.refresh() } } }
        }
    }
}
@MainActor
struct ContentView: View {
    @ObservedObject var tracker: Tracker
    @State private var revoke = false
    private let green = Color(red: 0.086,green: 0.463,blue: 0.365)
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 18) {
                panel {
                    Image(systemName: "location.square.fill").font(.system(size: 42)).foregroundStyle(green)
                    Text(tracker.company).font(.title2.bold())
                    Text("متابعة الحركة والمهام · إصدار تجربة 1.1.1").font(.caption).foregroundStyle(.secondary)
                    Text(tracker.member).font(.headline)
                }
                panel {
                    Text("حالة الدوام").font(.subheadline).foregroundStyle(.secondary)
                    Text(tracker.site).font(.headline)
                    action("فتح البرنامج لتسجيل الحضور أو الانصراف",symbol: "arrow.up.right.square",primary: false) { UIApplication.shared.open(Configuration.origin.appendingPathComponent("/").appending(queryItems: [URLQueryItem(name: "view",value: "punch")])) }
                    action("تحديث حالة الدوام",symbol: "arrow.clockwise",primary: false) { Task { await tracker.refresh() } }.disabled(tracker.busy)
                }
                panel {
                    Text("تذكيرات مهامي").font(.headline)
                    Text(tracker.reminderStatus).font(.subheadline).foregroundStyle(.secondary)
                    action("فتح المهام المثبتة",symbol: "pin.fill",primary: false) { UIApplication.shared.open(Configuration.origin.appendingPathComponent("/").appending(queryItems: [URLQueryItem(name: "view",value: "tasks")])) }
                    action("مزامنة تذكيرات المهام",symbol: "bell.badge",primary: true) { Task { await tracker.syncTasks() } }.disabled(tracker.busy || !tracker.paired)
                    action("إيقاف تذكيرات الهاتف",symbol: "bell.slash",primary: false) { Task { await TaskReminders.clear();tracker.reminderStatus = "أوقفت تذكيرات الهاتف. تبقى المهام داخل البرنامج." } }
                    Text("تُجدول حتى 20 مهمة بعد المزامنة. تتحدث عند فتح التطبيق؛ التعديلات والإلغاء يحتاجان مزامنة جديدة. الإشعارات تتبع إعدادات الآيفون والتركيز ويمكن مسحها. تبقى بطاقة المهمة مثبتة في البرنامج.").font(.caption).foregroundStyle(.secondary)
                }
                panel {
                    Text("مشاركة الموقع").font(.subheadline).foregroundStyle(.secondary)
                    Label(tracker.message,systemImage: tracker.sharing ? "location.fill" : "pause.circle").font(.title3.bold()).foregroundStyle(green)
                    if !tracker.lastUpdate.isEmpty { Text("آخر إرسال: " + tracker.lastUpdate).font(.caption).foregroundStyle(.secondary).environment(\.layoutDirection,.leftToRight) }
                    Toggle("أوافق على مشاركة موقعي أثناء الدوام، بما في ذلك أثناء الحركة وقفل الشاشة.",isOn: $tracker.consent).font(.subheadline).tint(green).disabled(tracker.sharing)
                    action("بدء مشاركة الموقع",symbol: "location.fill",primary: true) { Task { await tracker.start() } }.disabled(!tracker.paired || tracker.attendanceID == nil || !tracker.consent || tracker.busy || tracker.sharing)
                    action("إيقاف المشاركة الآن",symbol: "stop.circle",primary: false) { tracker.stop() }.disabled(!tracker.sharing && !tracker.busy)
                    action("إعدادات أذونات الموقع",symbol: "gearshape",primary: false) { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    Text("تعرض الإدارة آخر قراءة حديثة حسب صلاحيات المواقع. يلزم الإنترنت للإرسال. يتوقف التتبع عند الانصراف أو إلغاء الجهاز.").font(.caption).foregroundStyle(.secondary)
                }
                panel {
                    Text("الهاتف والحساب").font(.headline)
                    if !tracker.pairCode.isEmpty {
                        Text(tracker.pairCode).font(.title2.monospaced().bold()).environment(\.layoutDirection,.leftToRight)
                        Text("وافق على الربط من المتصفح ثم ارجع للتطبيق. الرمز صالح لخمس دقائق.").font(.subheadline)
                        if let url = tracker.verificationURL { action("فتح صفحة الموافقة",symbol: "safari",primary: false) { UIApplication.shared.open(url) } }
                    }
                    if !tracker.paired { action("ربط حسابي",symbol: "person.crop.circle.badge.checkmark",primary: true) { Task { await tracker.pair() } }.disabled(tracker.busy || tracker.verificationURL != nil) }
                    action("صفحة الأجهزة والصلاحيات",symbol: "iphone",primary: false) { UIApplication.shared.open(Configuration.origin.appendingPathComponent("/").appending(queryItems: [URLQueryItem(name: "view",value: "mobile")])) }
                    if tracker.paired { action("إلغاء ربط هذا الهاتف",symbol: "xmark.shield",primary: false) { revoke = true }.disabled(tracker.busy) }
                    Text("لا يطلب التطبيق كلمة مرورك؛ يربط حسابك عبر متصفح الهاتف. الصلاحية صالحة 30 يوماً.").font(.caption).foregroundStyle(.secondary)
                }
                if !tracker.error.isEmpty { Label(tracker.error,systemImage: "info.circle").font(.subheadline).foregroundStyle(Color.brown).accessibilityAddTraits(.updatesFrequently) }
                Text("لا يبدأ GPS عند فتح التطبيق. اضغط بدء المشاركة بعد تسجيل الحضور. إغلاق التطبيق بالقوة أو قيود النظام قد يوقفان التحديثات؛ افتحه وتحقق من الحالة.").font(.caption).foregroundStyle(.secondary)
            }.padding(22)
        }.background(Color(red: 0.955,green: 0.970,blue: 0.961)).tint(green)
        .alert("إلغاء ربط الهاتف؟",isPresented: $revoke) { Button("إلغاء الربط",role: .destructive) { Task { await tracker.disconnect() } };Button("عودة",role: .cancel) {} } message: { Text("تتوقف المشاركة وتُلغى صلاحية هذا الهاتف. يمكنك ربطه لاحقاً.") }
    }
    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading,spacing: 16,content: content).frame(maxWidth: .infinity,alignment: .leading).padding(22).background(.white,in: RoundedRectangle(cornerRadius: 20)) }
    private func action(_ title: String,symbol: String,primary: Bool,run: @escaping () -> Void) -> some View { Button(action: run) { Label(title,systemImage: symbol).font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical,16) }.foregroundStyle(primary ? Color.white : green).background(primary ? green : green.opacity(0.08),in: RoundedRectangle(cornerRadius: 12)).buttonStyle(.plain) }
}

@MainActor
final class TaskNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TaskNotificationDelegate()
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.identifier.hasPrefix("funoon-task-") ? [.banner,.list,.sound] : [])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier.hasPrefix("funoon-task-"),
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in
                UIApplication.shared.open(Configuration.origin.appendingPathComponent("/")
                    .appending(queryItems: [URLQueryItem(name: "view",value: "tasks")]))
            }
        }
        completionHandler()
    }
}
