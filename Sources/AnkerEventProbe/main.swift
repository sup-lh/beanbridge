import Foundation
import OpenBeanKit

func emit(_ text: String) {
    print(String(format: "%.3f", Date().timeIntervalSince1970) + " " + text)
    fflush(stdout)
}

@main struct EventProbe {
    static func main() async {
        do {
            let link = Link()
            try await link.waitPoweredOn()
            let devices = await link.scan(seconds: 5).filter(\.serviceMatch)
            guard devices.count == 1, let device = devices.first else {
                throw LinkError.missing("唯一录音豆")
            }
            try await link.connect(device.peripheral)
            let session = D3200Session(link: link)
            guard let info = try await session.deviceInfo(), info.recording == false else {
                throw LinkError.bluetooth("设备正在录音或状态未知，请先停止")
            }
            try await session.handshake()
            var stream: RealtimeStream?
            var flagsSeen: Set<String> = []
            link.sync {
                link.onEvent = { p in
                    // Do not log device identity, crypto material, file headers or audio bytes.
                    if p.type == 0x2E || (p.type == 0x01 && p.id == 0x01) || (Rx.isTransport(p) && p.id == Rx.fileHead) { return }
                    if Rx.isTransport(p) && (p.id == Rx.fileSlice || p.id == Rx.fileSliceMark) {
                        var i = 9
                        while p.raw.count - i >= 165 {
                            let signature = String(format: "%02X/%02X flag=%02X", p.type, p.id, p.raw[i + 4])
                            if flagsSeen.insert(signature).inserted { emit("AUDIO_METADATA " + signature) }
                            i += 166
                        }
                        return
                    }
                    emit(p.description + " payload=" + p.payload.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " "))
                    if case let .recordingStarted(id) = DeviceEvent(packet: p) {
                        flagsSeen.removeAll()
                        // startRealtime uses link.sync, so run outside the BLE queue.
                        Task {
                            do {
                                let started = try session.startRealtime(fileId: id) { _, _ in }
                                link.sync { stream = started }
                                emit("STREAM_STARTED")
                            } catch { emit("STREAM_ERROR \(error)") }
                        }
                    } else if case .recordingStopped = DeviceEvent(packet: p) {
                        let stopped = stream
                        stream = nil
                        Task {
                            _ = stopped?.stop()
                            emit("RECORDING_STOPPED_NO_SEND")
                        }
                    }
                }
            }
            emit("READY: record, tap until vibration, stop; no transcription or sending")
            try await Task.sleep(nanoseconds: 240_000_000_000)
            link.disconnect()
            emit("PROBE_FINISHED; device recording is not stopped by this tool")
        } catch { emit("ERROR \(error)"); exit(1) }
    }
}
