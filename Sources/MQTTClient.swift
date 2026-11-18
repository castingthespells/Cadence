import Foundation
import Network

/// 极简 MQTT 3.1.1 客户端：只实现连接、订阅、发布、心跳这四件事。
/// 走 TLS，不做 QoS 1/2 重传——状态消息每秒都会重发，丢一两条没有影响。
final class MQTTClient {

    enum Status: Equatable {
        case connecting
        case online
        case offline(String)
    }

    var onStatus: ((Status) -> Void)?
    var onPayload: ((String) -> Void)?

    private let host: String
    private let port: UInt16
    private let topic: String
    private let clientID: String

    private let queue = DispatchQueue(label: "cadence.mqtt")
    private var conn: NWConnection?
    private var buffer = Data()
    private var packetID: UInt16 = 0
    private var wantOnline = false
    private var retry: TimeInterval = 1
    private var pingTimer: DispatchSourceTimer?

    init(host: String, port: UInt16, topic: String) {
        self.host = host
        self.port = port
        self.topic = topic
        self.clientID = "cad-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
    }

    deinit {
        pingTimer?.cancel()
    }

    // MARK: - 对外

    func start() {
        queue.async {
            self.wantOnline = true
            guard self.conn == nil else { return }
            self.open()
        }
    }

    func stop() {
        queue.async {
            self.wantOnline = false
            self.pingTimer?.cancel()
            self.pingTimer = nil
            self.conn?.cancel()
            self.conn = nil
            self.buffer.removeAll()
        }
    }

    func publish(_ text: String) {
        queue.async {
            guard let conn = self.conn, let data = text.data(using: .utf8) else { return }
            var body = Self.mqttString(self.topic)
            body.append(data)
            conn.send(content: self.packet(0x30, body), completion: .idempotent)
        }
    }

    // MARK: - 连接

    private func open() {
        buffer.removeAll()
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 8
        tcp.noDelay = true
        let params = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)

        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 8883,
            using: params
        )
        self.conn = conn
        report(.connecting)

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendConnect()
            case .failed(let error):
                self.drop("连接失败：\(error.localizedDescription)")
            case .waiting:
                // 网络还没通，让它继续等，不主动放弃
                break
            case .cancelled:
                break
            default:
                break
            }
        }
        conn.start(queue: queue)
        receive(on: conn)
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if let error {
                self.drop(error.localizedDescription)
                return
            }
            if isComplete {
                self.drop("连接被断开")
                return
            }
            self.receive(on: conn)
        }
    }

    private func sendConnect() {
        var body = Self.mqttString("MQTT")
        body.append(contentsOf: [0x04, 0x02])              // 协议版本 3.1.1，clean session
        body.append(contentsOf: [0, 60])                    // keepalive 60 秒
        body.append(Self.mqttString(clientID))
        conn?.send(content: packet(0x10, body), completion: .idempotent)
    }

    private func sendSubscribe() {
        packetID &+= 1
        var body = Data()
        body.append(UInt8(packetID >> 8))
        body.append(UInt8(packetID & 0xFF))
        body.append(Self.mqttString(topic))
        body.append(0x00)                                   // QoS 0
        conn?.send(content: packet(0x82, body), completion: .idempotent)
    }

    private func startPing() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 25, repeating: 25)
        timer.setEventHandler { [weak self] in
            guard let self, let conn = self.conn else { return }
            conn.send(content: self.packet(0xC0, Data()), completion: .idempotent)
        }
        timer.resume()
        pingTimer = timer
    }

    private func drop(_ reason: String) {
        pingTimer?.cancel()
        pingTimer = nil
        conn?.cancel()
        conn = nil
        buffer.removeAll()
        guard wantOnline else { return }
        report(.offline(reason))
        // 退避重连，最长 15 秒
        let delay = retry
        retry = min(retry * 2, 15)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantOnline, self.conn == nil else { return }
            self.open()
        }
    }

    private func report(_ status: Status) {
        if case .online = status { retry = 1 }
        DispatchQueue.main.async { self.onStatus?(status) }
    }

    // MARK: - 解包

    private func drain() {
        while true {
            let base = buffer.startIndex
            guard buffer.count >= 2 else { return }

            var mult = 1
            var length = 0
            var cursor = base + 1
            var headerDone = false
            while cursor < buffer.endIndex {
                let byte = buffer[cursor]
                length += Int(byte & 0x7F) * mult
                mult *= 128
                cursor += 1
                if byte & 0x80 == 0 { headerDone = true; break }
            }
            guard headerDone else { return }
            guard buffer.endIndex - cursor >= length else { return }

            let type = buffer[base] & 0xF0
            let body = buffer.subdata(in: cursor..<(cursor + length))
            buffer.removeSubrange(base..<(cursor + length))
            handle(type: type, body: body)
        }
    }

    private func handle(type: UInt8, body: Data) {
        switch type {
        case 0x20:                                          // CONNACK
            let code = body.count >= 2 ? body[body.startIndex + 1] : 1
            guard code == 0 else {
                drop("中转拒绝连接（错误码 \(code)）")
                return
            }
            sendSubscribe()
            startPing()
            report(.online)
        case 0x30:                                          // PUBLISH
            guard body.count >= 2 else { return }
            let start = body.startIndex
            let topicLength = Int(body[start]) << 8 | Int(body[start + 1])
            let payloadStart = start + 2 + topicLength
            guard payloadStart <= body.endIndex else { return }
            let payload = body.subdata(in: payloadStart..<body.endIndex)
            guard let text = String(data: payload, encoding: .utf8) else { return }
            DispatchQueue.main.async { self.onPayload?(text) }
        default:
            break
        }
    }

    // MARK: - 编码

    private func packet(_ type: UInt8, _ body: Data) -> Data {
        var out = Data([type])
        out.append(Self.varint(body.count))
        out.append(body)
        return out
    }

    private static func varint(_ value: Int) -> Data {
        var remaining = value
        var out = Data()
        repeat {
            var byte = UInt8(remaining % 128)
            remaining /= 128
            if remaining > 0 { byte |= 0x80 }
            out.append(byte)
        } while remaining > 0
        return out
    }

    private static func mqttString(_ text: String) -> Data {
        let utf8 = Array(text.utf8)
        var out = Data([UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)])
        out.append(contentsOf: utf8)
        return out
    }
}
