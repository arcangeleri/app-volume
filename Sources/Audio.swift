import AppKit
import CoreAudio

// Core Audio 조회 도우미: 속성 읽기, 오디오를 연 프로세스 목록, 앱 단위로 묶는 키

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
}

func audioProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
    var address = globalAddress(selector)
    var size = UInt32(MemoryLayout<T>.size)
    return withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr
    }
}

struct AudioProcess {
    let object: AudioObjectID
    let pid: Int32
    let key: String
    let isOutputting: Bool
}

// 앱 단위로 묶는 키(번들 ID). 볼륨도 이 키로 저장한다.
// 크롬 같은 도우미 프로세스(com.google.Chrome.helper, ….helper.renderer)는 본체 번들 ID 로 합친다.
func appKey(bundleID: String, pid: Int32) -> String {
    let id = bundleID.isEmpty ? (NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "") : bundleID
    if id.isEmpty { return "pid-\(pid)" }
    // helper 로 시작하는 마디부터 자른다. 앞 두 마디(com.회사)는 자르지 않는다(com.helperapp.x 는 그대로)
    let parts = id.split(separator: ".", omittingEmptySubsequences: false)
    if let index = parts.firstIndex(where: { $0.lowercased().hasPrefix("helper") }), index >= 2 {
        return parts[..<index].joined(separator: ".")
    }
    return id
}

func appName(_ key: String) -> String {
    if let name = NSRunningApplication.runningApplications(withBundleIdentifier: key).first?.localizedName {
        return name
    }
    return key.split(separator: ".").last.map(String.init) ?? key
}

func listProcesses() -> [AudioProcess] {
    var address = globalAddress(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return [] }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &objects) == noErr else { return [] }
    // 크기를 잰 뒤 받는 사이에 목록이 줄면 HAL 이 실제로 채운 만큼만 쓴다
    objects = Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))

    var result: [AudioProcess] = []
    for object in objects {
        var pid: Int32 = 0
        var running: UInt32 = 0
        var bundleRef: Unmanaged<CFString>?
        // pid 를 못 읽으면 kill(0, 0) 이 성공해 「pid-0」 가짜 항목이 생기므로 뺀다
        guard audioProperty(object, kAudioProcessPropertyPID, &pid), pid > 0 else { continue }
        if pid == getpid() { continue }
        // 오디오 시스템이 닫힌 프로세스를 잠깐 더 들고 있어도 이미 끝난 pid 는 뺀다
        if kill(pid, 0) != 0 && errno == ESRCH { continue }
        _ = audioProperty(object, kAudioProcessPropertyIsRunningOutput, &running)
        _ = audioProperty(object, kAudioProcessPropertyBundleID, &bundleRef)
        let bundleID = bundleRef.map { $0.takeRetainedValue() as String } ?? ""
        result.append(AudioProcess(object: object, pid: pid, key: appKey(bundleID: bundleID, pid: pid), isOutputting: running != 0))
    }
    return result
}
