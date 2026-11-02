#!/usr/bin/env bash
# Seeds an emulator with files the way phones really keep deleted things (system trash,
# a gallery bin, thumbnail caches, an app's hidden "Sent" folder, a hidden folder, a packed
# thumbnail cache), then drives Unlose through onboarding, a quick scan, recovery and a deep
# scan. Taps go by the labels the app exposes to accessibility (uiautomator), not by pixels.
#   run.sh <apk> <out dir> <folder of sample jpgs>
APK=$1
OUT=$2
PHOTOS=$3
PKG=com.unlose.app
mkdir -p "$OUT"
LOG="$OUT/steps.txt"
say() { echo "$*" | tee -a "$LOG"; }

adb wait-for-device
# Logcat streams to a file from the start, so a freeze or crash still leaves its last lines.
adb logcat -v time > "$OUT/logcat_live.txt" 2>&1 &
LOGCAT_PID=$!
adb shell settings put global hide_error_dialogs 1
adb shell input keyevent KEYCODE_HOME
sleep 20
adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null 2>&1 || true
read -r W H <<<"$(adb shell wm size | grep -oE '[0-9]+x[0-9]+' | tail -1 | tr x ' ')"
say "screen ${W}x${H} density $(adb shell wm density | grep -oE '[0-9]+' | tail -1)"

# ---- seed ----
S=$(mktemp -d)
mapfile -t PICS < <(ls "$PHOTOS"/*.jpg | head -24)
NOW=$(date +%s)
EXP=$((NOW + 20 * 86400))
SOON=$((NOW + 2 * 86400))
mk() { adb shell mkdir -p "\"$1\""; }
push() { adb push "$1" "$2" >/dev/null && say "seeded $2"; }
mk /sdcard/DCIM/Camera
for i in 0 1 2 3; do push "${PICS[$i]}" "/sdcard/DCIM/Camera/.trashed-$EXP-IMG_2026102${i}_1015${i}.jpg"; done
push "${PICS[4]}" "/sdcard/DCIM/Camera/.trashed-$SOON-IMG_20261004_090000.jpg"
push "${PICS[5]}" "/sdcard/DCIM/Camera/IMG_visible_in_gallery.jpg"
mk /sdcard/Android/.Trash/com.sec.android.gallery3d/1698765432000
push "${PICS[6]}" "/sdcard/Android/.Trash/com.sec.android.gallery3d/1698765432000/a1b2c3d4e5f60718293a"
push "${PICS[7]}" "/sdcard/Android/.Trash/com.sec.android.gallery3d/1698765432000/f9e8d7c6b5a49382716f"
mk /sdcard/DCIM/.thumbnails
for i in 8 9 10; do
  # small copies: the app can still show and recover them
  push "${PICS[$i]}" "/sdcard/DCIM/.thumbnails/16987654${i}.jpg"
done
cat "${PICS[11]}" "${PICS[12]}" "${PICS[13]}" > "$S/thumbdata"
push "$S/thumbdata" "/sdcard/DCIM/.thumbnails/.thumbdata4--1967290299"
WA="/sdcard/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/Sent"
mk "$WA"
adb shell touch "\"$WA/.nomedia\""
for i in 14 15 16; do push "${PICS[$i]}" "$WA/IMG-2026100${i}-WA00${i}.jpg"; done
mk /sdcard/Pictures/.private
push "${PICS[17]}" "/sdcard/Pictures/.private/secret.jpg"
printf '%%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%%%EOF\n' > "$S/doc.pdf"
head -c 4096 /dev/urandom >> "$S/doc.pdf"
mk /sdcard/Download
push "$S/doc.pdf" "/sdcard/Download/.trashed-$EXP-Rental agreement.pdf"
if command -v ffmpeg >/dev/null; then
  ffmpeg -loglevel error -f lavfi -i testsrc=duration=3:size=640x360:rate=24 -pix_fmt yuv420p "$S/v.mp4" && \
    push "$S/v.mp4" "/sdcard/DCIM/Camera/.trashed-$EXP-VID_20261020_101500.mp4"
  ffmpeg -loglevel error -f lavfi -i sine=frequency=440:duration=3 -c:a aac "$S/a.m4a" && \
    { mk /sdcard/Recordings; push "$S/a.m4a" "/sdcard/Recordings/.trashed-$EXP-Voice note.m4a"; }
fi
rm -rf "$S"

# Animations off: Flutter reports "disable animations" and Unlose holds its loops still,
# so the accessibility tree goes idle and uiautomator can read it.
for k in window_animation_scale transition_animation_scale animator_duration_scale; do adb shell settings put global $k 0; done
# The emulator's vibrator HAL takes the whole emulator down on a haptic tap (seen on API 30 and 34):
# turn system haptics off; Flutter's HapticFeedback respects it.
adb shell settings put system haptic_feedback_enabled 0

# ---- install, grant ----
adb install -r "$APK" | tail -1 | tee -a "$LOG"
adb shell appops set --uid $PKG MANAGE_EXTERNAL_STORAGE allow
adb shell appops get $PKG MANAGE_EXTERNAL_STORAGE | tee -a "$LOG"

shot() {
  sleep "${2:-0}"
  timeout 20 adb exec-out screencap -p > "$OUT/$1.png"
  say "shot $1 ($(stat -c %s "$OUT/$1.png") bytes)"
}
alive() { [ "$(timeout 10 adb get-state 2>/dev/null)" = device ]; }
dump() {
  rm -f "$OUT/ui.xml"
  timeout 25 adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
  timeout 10 adb exec-out cat /sdcard/ui.xml > "$OUT/ui.xml" 2>/dev/null
}
# tap the centre of the first node whose text or content-desc contains $1
tap() {
  local want=$1 tries=${2:-4}
  alive || { say "device gone before '$want'"; return 1; }
  for _ in $(seq "$tries"); do
    dump
    local b
    b=$(python3 - "$want" "$OUT/ui.xml" <<'PY'
import re, sys
want, path = sys.argv[1], sys.argv[2]
try:
    xml = open(path, encoding='utf-8', errors='ignore').read()
except OSError:
    sys.exit()
for node in re.findall(r'<node [^>]*>', xml):
    t = re.search(r' text="([^"]*)"', node); d = re.search(r' content-desc="([^"]*)"', node)
    label = ((t.group(1) if t else '') + ' ' + (d.group(1) if d else '')).replace('&#10;', ' ')
    if want.lower() in label.lower():
        m = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
        if m:
            x1, y1, x2, y2 = map(int, m.groups())
            print((x1 + x2) // 2, (y1 + y2) // 2)
            break
PY
)
    if [ -n "$b" ]; then
      adb shell input tap $b
      say "tap '$want' at $b"
      return 0
    fi
    sleep 2
  done
  say "NOT FOUND: '$want'"
  return 1
}

# ---- drive ----
adb shell am start -W -n $PKG/.MainActivity | tail -1 | tee -a "$LOG"
shot 01_onboarding 8
tap "Continue"; shot 02_onboarding 2
tap "Continue"; shot 03_onboarding 2
tap "Get started"; shot 04_permission 2
sleep 3
shot 05_home 2
tap "Start scan"
shot 06_scanning 3
sleep 20
shot 07_scan_done
tap "See what came back"; shot 08_results 4
tap "Select all"; shot 09_selected 2
tap "Recover"
shot 10_recovering 1
sleep 8
shot 11_recovered
adb shell ls -la /sdcard/DCIM/Unlose /sdcard/Documents/Unlose /sdcard/Music/Unlose > "$OUT/restored_files.txt" 2>&1
cat "$OUT/restored_files.txt" | tee -a "$LOG"
tap "Done"; sleep 2
tap "Files"; shot 12_files 3
tap "Videos"; shot 13_videos 3
adb shell input keyevent KEYCODE_BACK; sleep 2
shot 14_home_after 2
tap "Deep scan"; sleep 1
tap "Start scan"
sleep 30
shot 15_deep_done
tap "See what came back"; shot 16_deep_results 4
tap "Thumbnail"; shot 17_thumbs 3
adb shell input keyevent KEYCODE_BACK; sleep 2
tap "Restored files"; shot 18_restored 4
adb shell input keyevent KEYCODE_BACK; sleep 2
tap "Settings"; shot 19_settings 3
tap "Light"; shot 20_light 3
adb shell input keyevent KEYCODE_BACK; sleep 2
shot 21_home_light 2

# A scan with animations on, for a look at the real motion (no taps needed).
alive && { for k in window_animation_scale transition_animation_scale animator_duration_scale; do adb shell settings put global $k 1; done; }

timeout 20 adb shell dumpsys meminfo $PKG | grep -E "TOTAL|Java Heap|Native Heap|Graphics" > "$OUT/meminfo.txt" || true
kill $LOGCAT_PID 2>/dev/null || true
grep -E "FATAL EXCEPTION|E/flutter|ANR in|AndroidRuntime|unlose" "$OUT/logcat_live.txt" | head -120 > "$OUT/errors.txt" || true
say "errors: $(wc -l < "$OUT/errors.txt")"
exit 0
