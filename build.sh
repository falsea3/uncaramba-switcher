#!/bin/zsh
set -e
cd "$(dirname "$0")"

APP=build/UnCarambaSwitcher.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

[[ -f model/ru.bin && -f model/en.bin ]] || tools/build_model.sh
mkdir -p "$APP/Contents/Resources"
cp model/ru.bin model/en.bin assets/AppIcon.icns "$APP/Contents/Resources/"

# Package.swift нужен SourceKit-LSP/SwiftPM и не является исходником приложения.
SOURCES=(
  Sources/Language/Brain.swift
  Sources/Language/Layouts.swift
  Sources/Language/Model.swift
  Sources/Configuration/Store.swift
  Sources/Input/Switcher.swift
  Sources/Services/Updater.swift
  Sources/UI/Settings.swift
  Sources/App/main.swift
)
swiftc -O -swift-version 5 "${SOURCES[@]}" -o "$APP/Contents/MacOS/UnCarambaSwitcher" -framework Cocoa -framework Carbon -framework SwiftUI

VERSION=${VERSION:-1.0}
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.uncaramba-switcher</string>
  <key>CFBundleName</key><string>UnCarambaSwitcher</string>
  <key>CFBundleExecutable</key><string>UnCarambaSwitcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

# Подписываем постоянным сертификатом: тогда macOS помнит разрешения (Универсальный доступ, Мониторинг ввода)
# между пересборками. С ad-hoc подписью («-») разрешение привязано к конкретной сборке и слетает после каждой.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
if [[ -n "$IDENTITY" ]]; then
  codesign --force --deep -s "$IDENTITY" "$APP"
else
  echo "⚠︎ Нет сертификата разработчика — подписываю ad-hoc, разрешения придётся выдавать после каждой сборки."
  codesign --force --deep -s - "$APP"
fi
echo "Готово: $PWD/$APP"

if [[ "$1" == "--install" ]]; then
  mkdir -p ~/Applications
  pkill -x UnCarambaSwitcher 2>/dev/null || true
  for i in {1..50}; do pgrep -x UnCarambaSwitcher >/dev/null || break; sleep 0.1; done
  rm -rf ~/Applications/UnCarambaSwitcher.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/UnCarambaSwitcher.app
  echo "Установлено в ~/Applications и запущено."
fi
