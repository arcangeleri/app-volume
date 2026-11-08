import CoreAudio
import Foundation

// tests/run.sh 가 Sources/Audio.swift·Tap.swift 와 같이 컴파일해 돌린다

// 채널 수·프레임 수대로 버퍼 목록을 만든다. 처음 값은 99 로 채워 덮어썼는지 보이게 한다
func makeList(_ layout: [(channels: Int, frames: Int)]) -> UnsafeMutableAudioBufferListPointer {
    let list = AudioBufferList.allocate(maximumBuffers: max(layout.count, 1))
    list.count = layout.count
    for (index, buffer) in layout.enumerated() {
        let data = UnsafeMutablePointer<Float>.allocate(capacity: buffer.channels * buffer.frames)
        data.initialize(repeating: 99, count: buffer.channels * buffer.frames)
        list[index] = AudioBuffer(mNumberChannels: UInt32(buffer.channels),
                                  mDataByteSize: UInt32(buffer.channels * buffer.frames * MemoryLayout<Float>.size),
                                  mData: data)
    }
    return list
}

func values(_ buffer: AudioBuffer) -> [Float] {
    Array(UnsafeBufferPointer(start: buffer.mData!.assumingMemoryBound(to: Float.self),
                              count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size))
}

var failures = 0
func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    if got == want {
        print("통과 \(name)")
    } else {
        failures += 1
        print("실패 \(name): \(got) (기대 \(want))")
    }
}

// 탭 입력: 인터리브 스테레오 3프레임, 왼쪽 1·2·3, 오른쪽 10·20·30
let input = makeList([(2, 3)])
let inputData = input[0].mData!.assumingMemoryBound(to: Float.self)
for (index, value) in [1, 10, 2, 20, 3, 30].enumerated() { inputData[index] = Float(value) }

let stereo = makeList([(2, 3)])
mixTap(input, into: stereo, left: 0, right: 1, gain: 0.5)
check("2채널 인터리브에 볼륨 곱하기", values(stereo[0]), [0.5, 5, 1, 10, 1.5, 15])

let split = makeList([(1, 3), (1, 3)])
mixTap(input, into: split, left: 0, right: 1, gain: 1)
check("채널별 버퍼 왼쪽", values(split[0]), [1, 2, 3])
check("채널별 버퍼 오른쪽", values(split[1]), [10, 20, 30])

let four = makeList([(4, 2)])
mixTap(input, into: four, left: 0, right: 1, gain: 1)
check("4채널은 셋째부터 0", values(four[0]), [1, 10, 0, 0, 2, 20, 0, 0])

let pair = makeList([(4, 2)])
mixTap(input, into: pair, left: 2, right: 3, gain: 1)
check("스테레오 쌍이 3·4번", values(pair[0]), [0, 0, 1, 10, 0, 0, 2, 20])

let outOfRange = makeList([(2, 2)])
mixTap(input, into: outOfRange, left: 6, right: 7, gain: 1)
check("쌍 번호가 채널 수를 넘으면 1·2번", values(outOfRange[0]), [1, 10, 2, 20])

let sameChannel = makeList([(2, 2)])
mixTap(input, into: sameChannel, left: 0, right: 0, gain: 1)
check("좌우가 같은 채널이면 섞기", values(sameChannel[0]), [5.5, 0, 11, 0])

let mono = makeList([(1, 3)])
mixTap(input, into: mono, left: 0, right: 1, gain: 1)
check("모노는 좌우 섞기", values(mono[0]), [5.5, 11, 16.5])

let longer = makeList([(2, 4)])
mixTap(input, into: longer, left: 0, right: 1, gain: 1)
check("입력보다 긴 프레임은 0", values(longer[0]), [1, 10, 2, 20, 3, 30, 0, 0])

let empty = makeList([])
let silent = makeList([(2, 1)])
mixTap(empty, into: silent, left: 0, right: 1, gain: 1)
check("입력이 없으면 0", values(silent[0]), [0, 0])

let keys = [
    ("com.google.Chrome.helper", "com.google.Chrome"),
    ("com.google.Chrome.helper.renderer", "com.google.Chrome"),
    ("com.hnc.Discord.helper.Renderer", "com.hnc.Discord"),
    ("com.foo.App.HelperTool", "com.foo.App"),
    ("com.helperapp.x", "com.helperapp.x"),
    ("com.helperapp.player.helper", "com.helperapp.player"),
    ("com.apple.WebKit.GPU", "com.apple.WebKit.GPU"),
    ("systemsoundserverd", "systemsoundserverd"),
]
for (bundleID, want) in keys {
    check("appKey \(bundleID)", appKey(bundleID: bundleID, pid: 1), want)
}

print(failures == 0 ? "전부 통과" : "실패 \(failures)건")
exit(failures == 0 ? 0 : 1)
