#!/bin/sh
# 실행 파일(mixer)과 앱 폴더(app-volume.app)를 만든다. 한 단계라도 실패하면 멈춘다.
# Info.plist 에 오디오 캡처 권한 안내 문구와 메뉴바 전용 설정이 들어 있다.
set -e
cd "$(dirname "$0")"

# 최소 버전을 Info.plist 의 LSMinimumSystemVersion(14.2)과 맞춘다. 안 주면 빌드한 맥의 OS 버전이 최소 버전이 된다.
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.2" Sources/*.swift -o mixer \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist

# 예전 빌드의 파일이 남지 않게 앱 폴더를 새로 만든다
rm -rf app-volume.app
mkdir -p app-volume.app/Contents/MacOS
cp mixer app-volume.app/Contents/MacOS/mixer
cp Info.plist app-volume.app/Contents/Info.plist
# 임시 서명. 권한이 이 앱 폴더에 붙는다. 다시 빌드하면 서명이 바뀌어 권한을 다시 물을 수 있다.
codesign --force --sign - app-volume.app
