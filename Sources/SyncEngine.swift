import Foundation
import Combine

/// 一起听：把播放状态通过一个公共中转广播出去，两边互相跟随。
///
/// 两个关键约定：
///
/// 1. 传**绝对状态**（哪首歌、第几秒、播还是停），不是「暂停」「下一首」这种命令。
///    所以不需要协调顺序——比版本号即可，谁后改谁覆盖。
///
/// 2. 不猜两台的时钟差。公共中转单程延迟约 250 毫秒、抖动能到 1 秒，
///    用 ping/pong 估时钟偏差实测会错到 1.2 秒。改为直接对齐「位置 ↔ 本地时刻」：
///    每条心跳记一个 (位置 − 本地时刻)，取最近一批里最大的那个。
///    延迟越小这个值越大，所以取最大值等于自动挑出「链路最顺的那一条」。
final class SyncEngine: ObservableObject {

    struct Snapshot {
        var dur: Int
        var name: String
        var title: String
        var pos: Double
        var playing: Bool
    }

    struct Remote {
        var dur: Int
        var name: String
        var title: String
        var target: Double
        var playing: Bool
        var by: String
        var hardJump: Bool     // 对方主动拖动，或刚恢复播放
    }

    @Published private(set) var active = false
    @Published private(set) var room = ""
    @Published private(set) var link = "未开启"
    @Published private(set) var peerName: String?
    @Published private(set) var peerOnline = false
    @Published private(set) var isAuthor = true
    @Published private(set) var rttMs: Double = 0
    @Published private(set) var missingTitle: String?

    var onRemote: ((Remote) -> Void)?
    var snapshot: (() -> Snapshot?)?

    let myName = Host.current().localizedName ?? "这台 Mac"
    private let myID = String(UUID().uuidString.prefix(8)).lowercased()

    private var client: MQTTClient?
    private var rev = 0
    private var lastRemoteRev = 0
    private var author = ""
    private var lastStateAt = Date.distantPast
    private var lastHeard = Date.distantPast
    private var stateTimer: Timer?
    private var pingTimer: Timer?
    private var joinedAsHost = false
    private var sawState = false

    // 位置对齐用的滑动窗口
    private var anchorWindow: [Double] = []
    private var anchorKey = ""
    private var lastPos: Double = 0
    private var lastAt: Double = 0
    private var hasLast = false
    private var rttWindow: [Double] = []

    private static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")

    private var brokerHost: String {
        UserDefaults.standard.string(forKey: "syncBroker") ?? "broker.emqx.io"
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    // MARK: - 进出房间

    func createRoom() {
        joinedAsHost = true
        start(code: Self.makeCode())
    }

    func joinRoom(_ raw: String) {
        let code = raw.uppercased().filter { Self.alphabet.contains($0) }
        guard code.count == 8 else {
            link = "房间码是 8 位字符"
            return
        }
        joinedAsHost = false
        start(code: code)
    }

    func leave() {
        if active { send(["k": "bye", "by": myID]) }
        stateTimer?.invalidate(); stateTimer = nil
        pingTimer?.invalidate(); pingTimer = nil
        client?.stop()
        client = nil
        active = false
        room = ""
        link = "未开启"
        peerName = nil
        peerOnline = false
        isAuthor = true
        missingTitle = nil
        rev = 0
        lastRemoteRev = 0
        author = ""
        lastStateAt = .distantPast
        anchorWindow.removeAll()
        anchorKey = ""
        hasLast = false
        rttWindow.removeAll()
        sawState = false
    }

    private static func makeCode() -> String {
        String((0..<8).map { _ in alphabet.randomElement()! })
    }

    private func start(code: String) {
        leave()
        room = code
        active = true
        isAuthor = joinedAsHost
        author = joinedAsHost ? "" : "(none)"
        link = "正在连接中转…"

        let client = MQTTClient(host: brokerHost, port: 8883, topic: "cadence/v1/" + code)
        client.onStatus = { [weak self] status in
            guard let self else { return }
            switch status {
            case .connecting:
                self.link = "正在连接中转…"
            case .online:
                self.link = "已连接"
                dbg("sync online room=\(self.room) me=\(self.myID) host=\(self.joinedAsHost)")
                self.send(["k": "hi", "by": self.myID, "name": self.myName])
                self.ping()
                if self.joinedAsHost && !self.sawState {
                    self.becomeAuthor()
                }
            case .offline(let reason):
                self.link = "中转断开，重试中"
                dbg("sync offline \(reason)")
                self.peerOnline = false
            }
        }
        client.onPayload = { [weak self] text in
            self?.handle(text)
        }
        self.client = client
        client.start()

        stateTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self, self.active else { return }
            if self.isAuthor { self.publishState() }
            if Date().timeIntervalSince(self.lastHeard) > 12 { self.peerOnline = false }
        }
        RunLoop.main.add(stateTimer!, forMode: .common)

        pingTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.ping()
        }
        RunLoop.main.add(pingTimer!, forMode: .common)
    }

    // MARK: - 本地操作 → 广播

    /// 本机用户做了任何改变播放状态的操作后调用
    func noteLocalChange() {
        guard active else { return }
        rev = max(rev, lastRemoteRev) + 1
        author = myID
        if !isAuthor { isAuthor = true }
        missingTitle = nil
        anchorWindow.removeAll()
        anchorKey = ""
        publishState()
    }

    private func becomeAuthor() {
        if author.isEmpty {
            rev = max(rev, lastRemoteRev) + 1
            author = myID
        }
        isAuthor = (author == myID)
        publishState()
    }

    private func publishState() {
        guard active, author == myID else { return }
        guard let snap = snapshot?() else {
            send([
                "k": "st", "rev": rev, "by": myID,
                "dur": 0, "name": "", "title": "",
                "pos": 0.0, "clk": now, "playing": false
            ])
            return
        }
        send([
            "k": "st", "rev": rev, "by": myID,
            "dur": snap.dur,
            "name": snap.name,
            "title": snap.title,
            "pos": snap.pos,
            "clk": now,
            "playing": snap.playing
        ])
    }

    private func ping() {
        guard active else { return }
        send(["k": "pi", "t0": now, "by": myID])
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        client?.publish(text)
    }

    // MARK: - 收到消息

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["k"] as? String else { return }

        let from = object["by"] as? String ?? ""
        if from != myID { lastHeard = Date() }

        switch kind {
        case "hi":
            if from != myID {
                peerName = object["name"] as? String ?? "朋友"
                peerOnline = true
            }

        case "pi":
            guard let t0 = object["t0"] as? Double else { return }
            send(["k": "po", "t0": t0, "tb": now, "by": myID])

        case "po":
            // 往返时间只用来显示链路质量，不参与位置计算
            guard let t0 = object["t0"] as? Double, from != myID else { return }
            rttWindow.append(now - t0)
            if rttWindow.count > 6 { rttWindow.removeFirst() }
            rttMs = (rttWindow.min() ?? 0) * 1000

        case "st":
            receiveState(object, from: from)

        case "bye":
            if from != myID {
                peerName = nil
                peerOnline = false
            }

        default:
            break
        }
    }

    private func receiveState(_ object: [String: Any], from: String) {
        guard from != myID,
              let incomingRev = object["rev"] as? Int else { return }
        // 版本号大的赢；相同时按设备 ID 比，双方得出同一个结论
        if incomingRev < lastRemoteRev,
           Date().timeIntervalSince(lastStateAt) < 20 { return }
        // 同一方的心跳会反复用同一个版本号，必须放行；只有「别人用相同版本号来抢」才按 ID 比
        if incomingRev == lastRemoteRev && from < author { return }

        lastRemoteRev = incomingRev
        lastStateAt = Date()
        rev = max(rev, incomingRev)
        author = from
        sawState = true
        if isAuthor { isAuthor = false }

        let dur = object["dur"] as? Int ?? 0
        let pos = object["pos"] as? Double ?? 0
        let playing = object["playing"] as? Bool ?? false
        let name = object["name"] as? String ?? ""

        // 对方已经什么都不放了
        guard dur > 0 else {
            anchorWindow.removeAll(); anchorKey = ""
            onRemote?(Remote(dur: 0, name: "", title: "", target: 0, playing: false,
                             by: from, hardJump: false))
            return
        }

        let key = "\(dur)|\(name)|\(playing)"
        if key != anchorKey {
            anchorWindow.removeAll()
            anchorKey = key
            hasLast = false
        }

        var hardJump = false
        var target = pos

        if playing {
            // 上一帧外推：按道理这一帧应该走到这里，偏差过大说明对方主动拖了进度
            let drift = hasLast ? pos - (lastPos + (now - lastAt)) : 0
            let anchor = pos - now
            if hasLast && abs(drift) > 1.2 {
                anchorWindow = [anchor]
                hardJump = true
            } else {
                anchorWindow.append(anchor)
                if anchorWindow.count > 32 { anchorWindow.removeFirst() }
            }
            if let best = anchorWindow.max() { target = best + now }
        } else {
            anchorWindow.removeAll()
            hasLast = false
        }

        lastPos = pos
        lastAt = now
        hasLast = playing

        dbg("sync recv rev=\(incomingRev) playing=\(playing) pos=\(String(format: "%.2f", pos)) target=\(String(format: "%.2f", target)) jump=\(hardJump) n=\(anchorWindow.count)")

        onRemote?(Remote(
            dur: dur,
            name: name,
            title: object["title"] as? String ?? "",
            target: target,
            playing: playing,
            by: from,
            hardJump: hardJump
        ))
    }

    func setMissing(_ title: String?) {
        if missingTitle != title { missingTitle = title }
    }
}
