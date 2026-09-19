#!/bin/bash
# 生成占位描述文件：rules_apple 对设备构建强制要求每个 bundle 都有 provisioning_profile
# 工件（ios_rules.bzl 无条件挂 partial），且会解析它的 plist 取 entitlements。
# 身份设成 ad-hoc（--ios_signing_cert_name=-）时 rules_apple 不拿它签名
# （codesigning_support.bzl:528），所以这里只需要一个结构合法、键齐全的容器。
# 自签一张一次性证书只为产出 CMS 结构；不涉及任何 Apple 凭据，产物也不进仓库。
set -euo pipefail
OUTS=("Signing/app.mobileprovision" "Signing/ext.mobileprovision")
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/profile.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>AppIDName</key><string>BuildPlaceholder</string>
  <key>ApplicationIdentifierPrefix</key><array><string>0000000000</string></array>
  <key>CreationDate</key><date>2026-01-01T00:00:00Z</date>
  <key>Platform</key><array><string>iOS</string></array>
  <key>Entitlements</key><dict/>
  <key>ExpirationDate</key><date>2040-01-01T00:00:00Z</date>
  <key>Name</key><string>BuildPlaceholder</string>
  <key>TeamIdentifier</key><array><string>0000000000</string></array>
  <key>TeamName</key><string>BuildPlaceholder</string>
  <key>TimeToLive</key><integer>3650</integer>
  <key>UUID</key><string>00000000-0000-0000-0000-000000000000</string>
  <key>Version</key><integer>1</integer>
</dict></plist>
PLIST
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -subj "/CN=BuildPlaceholder" 2>/dev/null
mkdir -p Signing
# 已有真实描述文件时不覆盖（占位件 ~2.2KB；真实件含证书链，明显更大）。
# 原先无条件覆写，把本地调试用的真描述文件冲掉过一次（2026-09-19）。
if [ "${1:-}" != "--force" ]; then
  for OUT in "${OUTS[@]}"; do
    if [ -f "$OUT" ] && [ "$(wc -c < "$OUT" | tr -d ' ')" -gt 4096 ]; then
      echo "keep $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes: looks real; pass --force to overwrite)"
      exit 0
    fi
  done
fi
for OUT in "${OUTS[@]}"; do
  openssl smime -sign -in "$TMP/profile.plist" -signer "$TMP/cert.pem" -inkey "$TMP/key.pem" \
    -nodetach -outform der -out "$OUT" 2>/dev/null
  echo "wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
done
