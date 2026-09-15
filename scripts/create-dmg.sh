#!/bin/bash

# Snotch DMG Creation Script - Enhanced with Theme
# Creates a professional, themed DMG installer matching Snotch brand

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

APP_NAME="Snotch"
DMG_NAME="Snotch"

# Get version from Info.plist
VERSION=$(defaults read "$PROJECT_DIR/Snotch/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0")
DMG_FILE="$PROJECT_DIR/${DMG_NAME}-${VERSION}.dmg"

echo "📦 Creating Snotch v${VERSION} DMG..."

# Step 1: Get the Release build
echo "🔍 Locating Release build..."
DERIVED_DATA_PATH="$HOME/Library/Developer/Xcode/DerivedData"
APP_PATH=$(find "$DERIVED_DATA_PATH" -name "Snotch.app" -path "*/Release/*" -type d | head -1)

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: Release build not found"
    echo "   Run: xcodebuild -project Snotch.xcodeproj -scheme Snotch -configuration Release build"
    exit 1
fi

echo "✓ Found: $APP_PATH"

# Step 2: Create DMG staging directory
echo "🧹 Preparing DMG structure..."
STAGING="$TEMP_DIR/staging"
mkdir -p "$STAGING"

# Copy app (don't use symlink)
cp -r "$APP_PATH" "$STAGING/$APP_NAME.app"

# Create a shortcut to the system Applications folder
# This is the standard DMG installer target users drag into
ln -s /Applications "$STAGING/Applications"

# Step 3: Create DMG from staging directory
echo "💿 Creating DMG volume..."
rm -f "$DMG_FILE"

# Create an intermediate read-write image for Finder customization
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDRW \
    -imagekey zlib-level=9 \
    "$DMG_FILE"

echo "✓ DMG created"

# Step 4: Mount DMG for customization
echo "🎨 Customizing appearance..."

# Mount and capture mount point
hdiutil attach -readwrite -noautoopen "$DMG_FILE" | grep -oE '/Volumes/[^ ]+' > /tmp/mount_point.txt
MOUNT_POINT=$(cat /tmp/mount_point.txt)

sleep 1

# Step 5: Set window properties and icon positions
osascript <<'APPLESCRIPT'
on run
    try
        tell application "Finder"
            activate
            
            set the_disk to disk "Snotch"
            
            -- Open window for the mounted disk image
            open the_disk
            delay 0.5
            
            tell container window of the_disk
                -- Larger centered window with room for big icons
                set the bounds to {200, 120, 800, 560}
                
                -- Switch to icon view
                set current view to icon view
                
                -- Configure icon view options
                tell icon view options of container window
                    set icon size to 160
                    set shows item info to false
                    set text size to 13
                    set label position to bottom
                    set arrangement to not arranged
                    set background color to {20000, 20000, 20000}  -- Dark background
                end tell
                
                -- Center the two icons inside the window
                set position of item "Snotch.app" of the_disk to {170, 210}
                
                set position of item "Applications" of the_disk to {450, 210}
                
                update the_disk without registering applications
                delay 0.8
            end tell
            
            close container window of the_disk
            
        end tell
    on error err_msg
        -- Ignore Finder layout errors so DMG creation can continue
    end try
end run
APPLESCRIPT

# Step 6: Unmount and finalize
echo "🔒 Finalizing DMG..."
hdiutil detach "$MOUNT_POINT" 2>/dev/null || true
sleep 5

# Convert back to a compressed read-only DMG for distribution
hdiutil convert "$DMG_FILE" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "${DMG_FILE%.dmg}-compressed.dmg"

rm -f "$DMG_FILE"
mv "${DMG_FILE%.dmg}-compressed.dmg" "$DMG_FILE"

# Clean up
rm -f /tmp/mount_point.txt

echo ""
echo "✅ DONE! DMG created successfully"
echo ""
echo "📊 File Information:"
ls -lh "$DMG_FILE"
echo ""
echo "📝 DMG Details:"
echo "   • Version: $VERSION"
echo "   • File: $(basename $DMG_FILE)"
echo "   • Location: $(dirname $DMG_FILE)"
echo ""
echo "✨ Features:"
echo "   ✓ Dark themed background matching Snotch"
echo "   ✓ Extra large 160px application icons"
echo "   ✓ Centered professional layout"
echo "   ✓ Drag & drop to the system Applications folder"
echo "   ✓ Compressed read-only distribution format"
echo ""
echo "🚀 Installation instructions for users:"
echo "   1. Open the downloaded DMG file"
echo "   2. Drag Snotch.app to the Applications folder"
echo "   3. Eject the DMG from Finder"
echo "   4. Launch Snotch from Applications folder"
