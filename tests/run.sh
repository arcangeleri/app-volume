#!/bin/sh
# 소리 처리(mixTap)와 앱 묶음 키(appKey)를 값으로 확인한다. 오디오 장치·권한 없이 돈다. 실패하면 종료 코드 1
set -e
cd "$(dirname "$0")/.."
out=$(mktemp -d)
swiftc -swift-version 5 Sources/Audio.swift Sources/Tap.swift tests/main.swift -o "$out/run-tests"
"$out/run-tests"
