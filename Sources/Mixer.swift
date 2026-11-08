import AppKit
import CoreAudio

// 앱별 볼륨·음소거 상태를 저장하고, 볼륨을 낮추거나 음소거한 앱의 프로세스에만 탭을 건다.
final class Mixer {
    var gains: [String: Float] = (UserDefaults.standard.dictionary(forKey: "gains") as? [String: Float]) ?? [:]
    var muted: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "muted") ?? [])
    var taps: [AudioObjectID: Tap] = [:]
    var processes: [AudioProcess] = []

    // 탭을 못 만든 프로세스와 실패한 시각. 1초마다 만들고 부수기를 반복하지 않도록 retryInterval 뒤에 다시 시도한다.
    var failedAt: [AudioObjectID: Date] = [:]
    let retryInterval: TimeInterval = 10

    func gain(_ key: String) -> Float { gains[key] ?? 1 }

    // 실제로 곱하는 값. 음소거면 슬라이더 값과 상관없이 0
    func effectiveGain(_ key: String) -> Float { muted.contains(key) ? 0 : gain(key) }

    // 이 앱의 프로세스 중 탭을 못 만들어 볼륨이 적용되지 않은 것이 있는지
    func hasFailure(_ key: String) -> Bool {
        processes.contains { $0.key == key && failedAt[$0.object] != nil }
    }

    // 메뉴에 보일 프로세스: 독에 뜨는 일반 앱은 항상, 시스템 데몬은 소리를 내거나 볼륨을 낮춰 둔 때만
    func isListed(_ process: AudioProcess) -> Bool {
        if process.isOutputting || effectiveGain(process.key) < 1 { return true }
        return NSRunningApplication.runningApplications(withBundleIdentifier: process.key)
            .contains { $0.activationPolicy == .regular }
    }

    func setGain(_ key: String, _ value: Float) {
        gains[key] = value >= 0.98 ? 1 : value
        muted.remove(key)
        applyChange(key)
    }

    func setMuted(_ key: String, _ value: Bool) {
        if value { muted.insert(key) } else { muted.remove(key) }
        applyChange(key)
    }

    // 사용자가 바꾼 값을 저장하고, 그 앱은 실패했어도 기다리지 않고 바로 다시 탭을 시도한다
    func applyChange(_ key: String) {
        UserDefaults.standard.set(gains, forKey: "gains")
        UserDefaults.standard.set(Array(muted), forKey: "muted")
        for process in processes where process.key == key {
            failedAt[process.object] = nil
        }
        refresh()
    }

    func refresh() {
        processes = listProcesses()
        let alive = Set(processes.map { $0.object })
        for (object, tap) in taps where !alive.contains(object) {
            tap.stop()
            taps[object] = nil
        }
        for object in failedAt.keys where !alive.contains(object) {
            failedAt[object] = nil
        }
        for process in processes {
            let gain = effectiveGain(process.key)
            if gain < 1 {
                if let tap = taps[process.object] {
                    tap.gain = gain
                } else if let failed = failedAt[process.object], Date().timeIntervalSince(failed) < retryInterval {
                    continue
                } else if let tap = Tap(processObject: process.object, gain: gain) {
                    taps[process.object] = tap
                    failedAt[process.object] = nil
                } else {
                    failedAt[process.object] = Date()
                }
            } else {
                if let tap = taps[process.object] {
                    tap.stop()
                    taps[process.object] = nil
                }
                failedAt[process.object] = nil
            }
        }
    }

    // 탭은 만들 때의 기본 출력 장치에 붙는다. 장치가 바뀌면 모두 부수고 새 장치로 다시 만든다.
    // 블루투스 연결처럼 알림이 연달아 오면 첫 알림부터 0.3초 안에 온 것을 한 번으로 합친다.
    var restartPending = false

    func restartSoon() {
        if restartPending { return }
        restartPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            restartPending = false
            restartAll()
        }
    }

    func restartAll() {
        stopAll()
        failedAt = [:]
        refresh()
    }

    func stopAll() {
        for tap in taps.values { tap.stop() }
        taps = [:]
    }
}
