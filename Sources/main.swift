import AppKit
import ServiceManagement

// 메뉴바 앱 믹서: 지금 소리를 내는 프로세스를 앱 단위 슬라이더로 보여 주고,
// 100% 미만으로 내리거나 음소거한 앱에만 프로세스 탭을 걸어 볼륨을 곱해 기본 출력 장치로 다시 낸다.
// Audio.swift(Core Audio 조회) · Tap.swift(탭과 볼륨 곱하기) · Mixer.swift(상태와 탭 관리) · Menu.swift(메뉴 화면)

let mixer = Mixer()

// 확인용: 로그인 항목을 바꾸거나 상태를 출력하고 끝낸다. 실패하면 종료 코드 1
if let index = CommandLine.arguments.firstIndex(of: "--login") {
    let value = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : "status"
    var error: Error?
    switch value {
    case "on": error = setLogin(true)
    case "off": error = setLogin(false)
    case "status": break
    default:
        print("사용법: mixer --login on|off|status")
        exit(2)
    }
    if let error = error {
        print("로그인 항목 변경 실패: \(error.localizedDescription)")
    }
    print("로그인 항목 상태: \(SMAppService.mainApp.status.rawValue) (0 미등록, 1 등록됨, 2 승인 필요, 3 찾을 수 없음)")
    exit(error == nil ? 0 : 1)
}

// 확인용: 목록만 출력하고 끝낸다
if CommandLine.arguments.contains("--list") {
    for process in listProcesses() {
        print("pid \(process.pid)  표시 \(mixer.isListed(process))  출력 \(process.isOutputting)  묶음 \(process.key)  이름 \(appName(process.key))")
    }
    exit(0)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate(mixer: mixer)
application.delegate = delegate
application.run()
