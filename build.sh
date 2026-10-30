#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${THEOS:-}" || ! -d "${THEOS:-}" ]]; then
    THEOS="/Users/xiao/dev/theos-roothide"
fi
export THEOS

MAKE_BIN="$(command -v gmake || command -v make || true)"
if [[ -z "$MAKE_BIN" ]]; then
    echo "error: make or gmake is required" >&2
    exit 1
fi

if [[ ! -d "$THEOS" ]]; then
    echo "error: Theos not found at $THEOS" >&2
    echo "Set THEOS to your local Theos directory before running this script." >&2
    exit 1
fi

PACKAGE_ID="$(awk -F': ' '/^Package:/{print $2; exit}' "$ROOT_DIR/control")"
PACKAGE_VERSION="$(awk -F': ' '/^Version:/{print $2; exit}' "$ROOT_DIR/control")"
if [[ -z "$PACKAGE_ID" || -z "$PACKAGE_VERSION" ]]; then
    echo "error: Package or Version is missing from $ROOT_DIR/control" >&2
    exit 1
fi

if [[ ! "$PACKAGE_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "error: Version must use MAJOR.MINOR.PATCH format: $PACKAGE_VERSION" >&2
    exit 1
fi

# PATCH counts 0-10; past 10 it carries into MINOR (3.0.10 -> 3.1.0), MINOR likewise into MAJOR.
NEXT_MAJOR="${BASH_REMATCH[1]}"
NEXT_MINOR="${BASH_REMATCH[2]}"
NEXT_PATCH="$((10#${BASH_REMATCH[3]} + 1))"
if (( NEXT_PATCH > 10 )); then
    NEXT_PATCH=0
    NEXT_MINOR="$((10#${BASH_REMATCH[2]} + 1))"
fi
if (( NEXT_MINOR > 10 )); then
    NEXT_MINOR=0
    NEXT_MAJOR="$((10#${BASH_REMATCH[1]} + 1))"
fi
NEXT_VERSION="${NEXT_MAJOR}.${NEXT_MINOR}.${NEXT_PATCH}"

# Bark 推送：每次构建结束后推送"typex-版本-状态"；token 只存本地
# build-notify.local.conf（已被 .gitignore 排除）。
# 配置缺失、无 token 或推送失败都只告警，不影响构建结果与退出码。
notify_bark() {
    local message="$1"
    # Local validation can opt out without touching the user's notification config.
    if [[ "${TYPEX_SKIP_BUILD_NOTIFICATION:-0}" == "1" ]]; then return 0; fi
    local conf_file="$ROOT_DIR/build-notify.local.conf"

    if [[ ! -f "$conf_file" ]]; then
        echo "note: $conf_file not found, skip notification" >&2
        return 0
    fi
    # shellcheck disable=SC1090
    source "$conf_file"
    if [[ -z "${BARK_TOKEN:-}" ]]; then
        echo "note: no BARK_TOKEN in build-notify.local.conf, skip notification" >&2
        return 0
    fi
    if curl -fsS --max-time 10 "https://api.day.app/${BARK_TOKEN}/${message}" >/dev/null 2>&1; then
        echo "==> Bark notification sent: $message"
    else
        echo "warning: Bark notification failed (build result is unaffected)" >&2
    fi
    return 0
}

# 编译开始后才推送结果；脚本前置校验失败不推送
BUILD_STARTED=false
CONTROL_TMP=""
finalize() {
    local rc=$?
    trap - EXIT
    rm -f "${CONTROL_TMP:-}"
    if [[ "$BUILD_STARTED" == true ]]; then
        if [[ "$rc" -eq 0 ]]; then
            notify_bark "typex-${NEXT_VERSION}-构建完成"
        else
            notify_bark "typex-${NEXT_VERSION}-构建失败"
        fi
    fi
}
trap finalize EXIT

build_one() {
    local label="$1"
    local scheme="$2"
    local sdk_version="$3"
    local deployment_version="$4"
    local sdk_path="$THEOS/sdks/iPhoneOS${sdk_version}.sdk"
    local output_dir="$ROOT_DIR/packages/$scheme/$label"
    local output_path="$output_dir/${PACKAGE_ID}_${NEXT_VERSION}_${label}_${scheme}_iphoneos-arm64e.deb"

    if [[ ! -d "$sdk_path" ]]; then
        echo "error: required SDK not found: $sdk_path" >&2
        exit 1
    fi

    echo "==> Building $label ($scheme) with iPhoneOS${sdk_version}.sdk"

    # Keep the package root clean so the result can be identified unambiguously.
    find "$ROOT_DIR/packages" -maxdepth 1 -type f -name '*.deb' -delete 2>/dev/null || true
    "$MAKE_BIN" -C "$ROOT_DIR" clean >/dev/null

    (
        cd "$ROOT_DIR"
        THEOS_PACKAGE_SCHEME="$scheme" \
            TARGET="iphone:clang:${sdk_version}:${deployment_version}" \
            "$MAKE_BIN" package FINALPACKAGE=1 PACKAGE_VERSION="$NEXT_VERSION"
    )

    mkdir -p "$output_dir"
    find "$output_dir" -maxdepth 1 -type f -name '*.deb' -delete 2>/dev/null || true

    local package_path
    package_path="$(find "$ROOT_DIR/packages" -maxdepth 1 -type f -name "${PACKAGE_ID}_${NEXT_VERSION}_*.deb" -print -quit)"
    if [[ -z "$package_path" ]]; then
        echo "error: package was not produced for $label ($scheme)" >&2
        exit 1
    fi

    mv "$package_path" "$output_path"
    echo "==> Output: $output_path"
}

BUILD_STARTED=true

# 同时产出 roothide 与 rootless 两个 scheme 的包，各自覆盖 iOS 16 / iOS 17。
for scheme in roothide rootless; do
    build_one ios16 "$scheme" 16.5 16.0
    # Keep the iOS 17 build compatible with the reference package:
    # build against the iOS 16 SDK while retaining iOS 15+ ABI support.
    build_one ios17 "$scheme" 16.5 15.0
done

# Persist the version only after both platform builds have completed.
# CONTROL_TMP 的清理由 finalize（EXIT trap）负责。
CONTROL_TMP="$(mktemp "$ROOT_DIR/control.tmp.XXXXXX")"

awk -v next_version="$NEXT_VERSION" '
    BEGIN { updated = 0 }
    /^Version:/ {
        print "Version: " next_version
        updated = 1
        next
    }
    { print }
    END {
        if (!updated) exit 1
    }
' "$ROOT_DIR/control" > "$CONTROL_TMP"
mv "$CONTROL_TMP" "$ROOT_DIR/control"

echo "==> Build completed successfully: $PACKAGE_VERSION -> $NEXT_VERSION"
