import Foundation
import CoreLocation
import UIKit
import Combine

@MainActor
final class Tracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var company = "شركة فنون الرافدين"
    @Published var member = "اربط هاتفك بحساب الشركة"
    @Published var site = "لا يوجد حضور مفتوح"
    @Published var paired = false
    @Published var sharing = false
    @Published var busy = false
    @Published var consent = false
    @Published var message = "مشاركة الموقع متوقفة"
    @Published var error = ""
    @Published var lastUpdate = ""
    @Published var pairCode = ""
    @Published var verificationURL: URL?
    @Published var attendanceID: String?
    @Published var reminderStatus = "مزامنة تذكيرات المهام اختيارية وتحتاج السماح بالإشعارات."
    private let gps = CLLocationManager()
    private var token: String?
    private var session: String?
    private var generation = 0
    private var latest: CLLocation?
    private var lastAttempt = Date.distantPast
    private var lastSent = Date.distantPast
    private var lastStatus = Date.distantPast
    private var endsAt = Date.distantPast
    private var maxAccuracy: Double = 100
    private var sending = false
    private var heartbeat: Timer?
    private var pairTask: Task<Void,Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    override init() { super.init();gps.delegate = self;gps.desiredAccuracy = kCLLocationAccuracyBest;gps.distanceFilter = kCLDistanceFilterNone;gps.activityType = .automotiveNavigation;gps.pausesLocationUpdatesAutomatically = false;gps.showsBackgroundLocationIndicator = true }
    func refresh() async {
        guard !busy && verificationURL == nil else { return };busy = true;defer { busy = false }
        do {
            token = try SecureStore.read()
            guard let token else { paired = false;return }
            let r = try await API.send("status",secret: token)
            apply(r);error = ""
            if TaskReminders.enabled { _ = try? await TaskReminders.sync(secret: token) }
            if sharing && (attendanceID == nil || r["sharing"] as? Bool != true) { stop(reason: "أُغلق الدوام أو بدأت المشاركة من جهاز آخر") }
        } catch {
            self.error = friendly(error)
            if let e = error as? APIError, [401,403].contains(e.status) { await TaskReminders.clear();SecureStore.clear();token = nil;paired = false;stop(reason: e.message) }
        }
    }
    private func apply(_ r: [String:Any]) {
        paired = true;company = r["companyName"] as? String ?? company;maxAccuracy = (r["maxAccuracy"] as? NSNumber)?.doubleValue ?? 100
        if let m = r["member"] as? [String:Any] { member = (m["name"] as? String ?? "") + " · " + (m["code"] as? String ?? "") }
        if let a = r["openAttendance"] as? [String:Any] { attendanceID = a["id"] as? String;site = a["siteName"] as? String ?? "حضور مفتوح" }
        else { attendanceID = nil;site = "لا يوجد حضور مفتوح؛ سجّل الحضور أولاً" }
    }
    func pair() async {
        guard !busy && !sharing else { return };busy = true;error = "";pairTask?.cancel()
        do {
            await TaskReminders.clear()
            let secret = try SecureStore.create();try SecureStore.write(secret);token = secret
            let r = try await API.send("pair",method: "POST",body: ["proofHash":SecureStore.hash(secret),"label":UIDevice.current.model,"platform":"ios"])
            guard let id = r["pairId"] as? String, let code = r["code"] as? String, let expiry = API.date(r["expiresAt"] as? String ?? ""),let url = URL(string: r["verificationUrl"] as? String ?? ""),url.scheme == "https",url.host == Configuration.origin.host else { throw APIError(status: 502,message: "تعذر فتح صفحة ربط الهاتف") }
            pairCode = stride(from: 0,to: code.count,by: 4).map { String(code.dropFirst($0).prefix(4)) }.joined(separator: "-")
            verificationURL = url
            busy = false
            await UIApplication.shared.open(url)
            pairTask = Task { [weak self] in
                while !Task.isCancelled && Date() < expiry {
                    do {
                        try await Task.sleep(nanoseconds: 3_000_000_000)
                        guard !Task.isCancelled else { return }
                        let ack = try await API.send("pair-status",method: "POST",body: ["pairId":id],secret: secret)
                        if ack["state"] as? String == "approved" { self?.pairCode = "";self?.verificationURL = nil;await self?.refresh();return }
                    } catch {
                        if Task.isCancelled { return }
                        if let e = error as? APIError,e.terminal { self?.error = e.message;self?.pairCode = "";self?.verificationURL = nil;return }
                    }
                }
                self?.pairCode = "";self?.verificationURL = nil;self?.error = "انتهى رمز الربط؛ ابدأ ربطاً جديداً"
            }
        } catch { busy = false;self.error = friendly(error) }
    }
    func start() async {
        guard !busy && !sharing && paired && consent,let attendance = attendanceID,let token,UIApplication.shared.applicationState == .active else { return }
        guard CLLocationManager.locationServicesEnabled() else { error = "فعّل خدمات الموقع من إعدادات الهاتف";return }
        let authorization = gps.authorizationStatus
        if authorization == .notDetermined { gps.requestWhenInUseAuthorization();error = "بعد منح الإذن، اضغط بدء المشاركة مجدداً";return }
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else { error = "اسمح للتطبيق بالموقع أثناء الاستخدام من الإعدادات";return }
        guard gps.accuracyAuthorization == .fullAccuracy else { error = "فعّل الموقع الدقيق من إعدادات التطبيق ثم ابدأ المشاركة";return }
        busy = true;error = "";let run = generation
        do {
            let r = try await API.send("start",method: "POST",body: ["attendanceId":attendance,"consent":true],secret: token)
            guard let sid = r["sessionId"] as? String,let end = API.date(r["endsAt"] as? String ?? "") else { throw APIError(status: 502,message: "تعذر بدء الجلسة") }
            guard run == generation,consent,UIApplication.shared.applicationState == .active else { Task { _ = try? await API.send("stop",method: "POST",body: ["sessionId":sid],secret: token) };busy = false;return }
            session = sid;endsAt = end;sharing = true;busy = false;lastAttempt = .distantPast;lastSent = .distantPast;lastStatus = Date();lastUpdate = "";message = "بانتظار قراءة GPS دقيقة…"
            gps.allowsBackgroundLocationUpdates = true;gps.startUpdatingLocation()
            heartbeat?.invalidate();heartbeat = Timer.scheduledTimer(withTimeInterval: 5,repeats: true) { [weak self] _ in Task { @MainActor in self?.attempt() } }
        } catch { busy = false;self.error = friendly(error) }
    }
    func stop(reason: String = "مشاركة الموقع متوقفة") {
        let secret = token,sid = session;generation += 1;sharing = false;consent = false;session = nil;sending = false;latest = nil
        gps.stopUpdatingLocation();gps.allowsBackgroundLocationUpdates = false;heartbeat?.invalidate();heartbeat = nil;message = reason
        if let secret,let sid { beginBackgroundRequest();Task { [weak self] in _ = try? await API.send("stop",method: "POST",body: ["sessionId":sid],secret: secret);self?.endBackgroundRequest() } }
    }
    func disconnect() async {
        stop();guard !busy else { return };busy = true;defer { busy = false }
        await TaskReminders.clear()
        do { if let token { _ = try await API.send("disconnect",method: "POST",body: [:],secret: token) };SecureStore.clear();token = nil;paired = false;attendanceID = nil;site = "لا يوجد حضور مفتوح";member = "اربط هاتفك بحساب الشركة";error = "" }
        catch { self.error = "توقفت المشاركة على الهاتف. تعذر إلغاء الربط عبر الإنترنت؛ أعد المحاولة أو ألغِ الجهاز من صفحة الأجهزة." }
    }
    func syncTasks() async {
        guard !busy,paired,let token else { reminderStatus = "اربط الهاتف بحسابك أولاً";return }
        busy = true;defer { busy = false }
        do { let count = try await TaskReminders.sync(secret: token,askPermission: true);reminderStatus = "تمت جدولة \(count) تذكير. حدّثها بعد تغيير المهام." }
        catch { reminderStatus = friendly(error) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager,didUpdateLocations locations: [CLLocation]) { Task { @MainActor [weak self] in self?.receive(locations) } }
    private func receive(_ points: [CLLocation]) {
        guard sharing else { return }
        guard let point = points.last,point.horizontalAccuracy >= 0,Date().timeIntervalSince(point.timestamp) >= -15,Date().timeIntervalSince(point.timestamp) <= 90 else { return }
        if point.horizontalAccuracy > maxAccuracy { message = "دقة الموقع ضعيفة؛ تحقق من تفعيل الموقع الدقيق";return }
        if #available(iOS 15.0,*),point.sourceInformation?.isSimulatedBySoftware == true { message = "قراءة تجريبية؛ استخدم موقع الهاتف الفعلي";return }
        if latest == nil || point.timestamp > latest!.timestamp { latest = point };attempt()
    }
    private func attempt() {
        guard sharing,!sending,let token,let sid = session else { return }
        if Date() >= endsAt { stop(reason: "انتهت المدة المسموحة للدوام؛ سجّل الانصراف");return }
        let now = Date(),point = latest
        let sample = point != nil && now.timeIntervalSince(point!.timestamp) <= 90 && point!.timestamp > lastSent && now.timeIntervalSince(lastAttempt) >= 15
        guard sample || now.timeIntervalSince(lastStatus) >= 30 else { return }
        if sample { lastAttempt = now } else { lastStatus = now }
        let run = generation;sending = true;beginBackgroundRequest()
        Task { [weak self] in
            defer { self?.endBackgroundRequest() }
            do {
                if sample,let point {
                    guard Date().timeIntervalSince(point.timestamp) <= 90 else { if self?.generation == run { self?.sending = false };return }
                    let r = try await API.send("location",method: "PUT",body: ["sessionId":sid,"latitude":point.coordinate.latitude,"longitude":point.coordinate.longitude,"accuracy":point.horizontalAccuracy,"positionTime":point.timestamp.timeIntervalSince1970 * 1000],secret: token)
                    guard let self,self.generation == run,self.sharing else { return };self.sending = false;self.lastSent = point.timestamp;self.lastUpdate = r["receivedAt"] as? String ?? "";self.message = "موقعك يُشارك أثناء الدوام · دقة ±\(Int(point.horizontalAccuracy)) م"
                } else {
                    let r = try await API.send("status",secret: token)
                    guard let self,self.generation == run,self.sharing else { return };self.sending = false
                    if !(r["openAttendance"] is [String:Any]) || r["sharing"] as? Bool != true { self.stop(reason: "أُغلق الدوام أو بدأت المشاركة من جهاز آخر") }
                    else if point == nil || now.timeIntervalSince(point!.timestamp) > 90 { self.message = "لا توجد قراءة حديثة؛ تحقق من GPS والاتصال" }
                }
            } catch {
                guard let self,self.generation == run,self.sharing else { return };self.sending = false
                if let e = error as? APIError,e.terminal { self.stop(reason: e.message) }
                else { self.message = "تعذر إرسال الموقع؛ تحقق من الإنترنت. القراءات القديمة لا تُرسل." }
            }
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager,didFailWithError error: Error) { Task { @MainActor [weak self] in if let e = error as? CLError,e.code == .denied { self?.stop(reason: "أُلغي إذن الموقع؛ راجع الإعدادات") } else { self?.message = "GPS غير متاح مؤقتاً؛ تحقق من الموقع الدقيق" } } }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { Task { @MainActor [weak self] in guard let self else { return };if self.sharing && ![CLAuthorizationStatus.authorizedAlways,.authorizedWhenInUse].contains(self.gps.authorizationStatus) { self.stop(reason: "أُلغي إذن الموقع") } } }
    private func friendly(_ error: Error) -> String { (error as? APIError)?.message ?? "تعذر الاتصال بالبرنامج؛ تحقق من الإنترنت وحاول مجدداً" }
    private func beginBackgroundRequest() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FunoonLocationSend") { [weak self] in Task { @MainActor in self?.endBackgroundRequest() } }
    }
    private func endBackgroundRequest() { if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask);backgroundTask = .invalid } }
}
