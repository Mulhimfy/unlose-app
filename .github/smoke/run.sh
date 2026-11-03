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

MODE=${MODE:-full}   # full: everything; apps: onboarding + the app-folder scan only
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
  local want=$1 tries=${2:-4} exact=${3:-}
  alive || { say "device gone before '$want'"; return 1; }
  for _ in $(seq "$tries"); do
    dump
    local b
    b=$(python3 - "$want" "$OUT/ui.xml" "$exact" <<'PY'
import re, sys
want, path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
exact = mode == 'exact'
try:
    xml = open(path, encoding='utf-8', errors='ignore').read()
except OSError:
    sys.exit()
for node in re.findall(r'<node [^>]*>', xml):
    t = re.search(r' text="([^"]*)"', node); d = re.search(r' content-desc="([^"]*)"', node)
    label = ((t.group(1) if t else '') + ' ' + (d.group(1) if d else '')).replace('&#10;', ' ')
    pkg = re.search(r' package="([^"]*)"', node)
    if exact and (pkg is None or pkg.group(1) != 'com.unlose.app'):
        continue
    if mode == 'full':
        # a button: its text or description is just the label (maybe repeated), not a sentence that mentions it
        hit = False
        for f in ((t.group(1) if t else ''), (d.group(1) if d else '')):
            parts = [x.strip().lower() for x in f.split('&#10;') if x.strip()]
            if parts and all(x == want.lower() for x in parts):
                hit = True
    else:
        hit = (want in label.split()) if exact else (want.lower() in label.lower())
    if hit:
        m = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
        if m:
            x1, y1, x2, y2 = map(int, m.groups())
            if x2 - x1 < 4 or y2 - y1 < 4:
                continue  # off screen (another tab, a scrolled-away row)
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
if [ "$MODE" = full ]; then
sleep 3
shot 05_home 2
tap "Start recovery"; shot 06_choice 2
tap "Scan for everything" 4 full
shot 07_scanning 3
sleep 20
shot 08_scan_done
tap "See what came back"; shot 09_results 4
tap "Select all"; shot 10_selected 2
tap "Recover"
shot 11_recovering 1
sleep 8
shot 12_recovered
adb shell ls -la "/sdcard/DCIM/Photos\ Recovery" "/sdcard/Documents/Photos\ Recovery" "/sdcard/Music/Photos\ Recovery" > "$OUT/restored_files.txt" 2>&1
cat "$OUT/restored_files.txt" | tee -a "$LOG"
tap "Done"; sleep 2
tap "Maybe later" 2 full; sleep 1
tap "Files"; shot 13_files 3
tap "Videos"; shot 14_videos 3
adb shell input keyevent KEYCODE_BACK; sleep 2
shot 15_home_after 2
tap "Start recovery"; sleep 2
tap "Deep"; sleep 1
tap "Scan for everything" 4 full
sleep 30
shot 16_deep_done
tap "See what came back"; shot 17_deep_results 4
tap "Thumbnail"; shot 18_thumbs 3
adb shell input keyevent KEYCODE_BACK; sleep 2
tap "Restored" 4 exact; shot 19_restored_tab 4
tap "Tools" 4 exact; shot 20_tools 3
tap "Memory card"; shot 21_card 3
adb shell input keyevent KEYCODE_BACK; sleep 2
tap "Cloud bins"; shot 22_cloud 3
adb shell input keyevent KEYCODE_BACK; sleep 2
tap "Vault" 4 exact; shot 23_vault_intro 2
tap "Set a passcode"; sleep 2
for d in 1 2 3 4; do tap "$d" 2 exact; done; sleep 1
for d in 1 2 3 4; do tap "$d" 2 exact; done; sleep 2
shot 24_vault 2
tap "Lock now"; shot 25_vault_locked 2
for d in 1 2 3 4; do tap "$d" 2 exact; done; sleep 2
shot 26_vault_open 2
tap "Settings" 4 exact; shot 27_settings 3
tap "Light"; shot 28_light 3

fi

# ---- other apps' folders (Android/data): direct on 10-, folder grant on 11-12, Shizuku on 13+ ----
SDK=$(adb shell getprop ro.build.version.sdk | tr -d '\r')
say "sdk $SDK"
TG=/sdcard/Android/data/org.telegram.messenger/cache
seed_tg() {
  adb shell mkdir -p $TG
  adb push "${PICS[18]}" "$TG/-6012345678_2041.jpg" >/dev/null && say "seeded $TG/-6012345678_2041.jpg"
  adb push "${PICS[19]}" "$TG/5a1f0c9e2b7d" >/dev/null && say "seeded $TG/5a1f0c9e2b7d (no name extension)"
}
R="/sdcard/DCIM/Photos\ Recovery"
apps_scan() {
  sleep 4; shot 35_apps_ready 1
  tap "Scan inside apps" 4 full; sleep 30; shot 36_apps_scan
  tap "See what came back"; shot 37_apps_results 4
  BEFORE=$(adb shell ls "$R" 2>/dev/null | wc -l)
  tap "Select all"; sleep 1
  tap "Recover"; sleep 12; shot 38_apps_recovered
  say "restored photos: $BEFORE before, $(adb shell ls "$R" 2>/dev/null | wc -l) after"
  tap "Done"; sleep 1; tap "Maybe later" 2 full
}
if [ "$SDK" -ge 33 ]; then
  seed_tg
  SZ=$(curl -sL https://api.github.com/repos/RikkaApps/Shizuku/releases/latest | python3 -c "import sys,json; print(next(a['browser_download_url'] for a in json.load(sys.stdin)['assets'] if a['name'].endswith('.apk')))" 2>/dev/null)
  say "shizuku: $SZ"
  if [ -n "$SZ" ] && curl -sL -o /tmp/shizuku.apk "$SZ" && adb install -r /tmp/shizuku.apk | tail -1 | tee -a "$LOG"; then
    adb shell monkey -p moe.shizuku.privileged.api -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; sleep 8
    shot 30_shizuku_app 1
    timeout 30 adb shell sh /sdcard/Android/data/moe.shizuku.privileged.api/start.sh > "$OUT/shizuku_start.txt" 2>&1
    if ! grep -qi "exit with 0" "$OUT/shizuku_start.txt"; then
      LIB=$(adb shell pm path moe.shizuku.privileged.api | head -1 | sed 's/package://; s/base.apk//' | tr -d '\r')
      for abi in x86_64 x86 arm64; do timeout 30 adb shell "${LIB}lib/$abi/libshizuku.so" >> "$OUT/shizuku_start.txt" 2>&1 && break; done
    fi
    tail -3 "$OUT/shizuku_start.txt" | tee -a "$LOG"
    say "adb shell sees Android/data: $(adb shell ls /sdcard/Android/data 2>&1 | head -3 | tr '\n' ' ')"
    sleep 4
    adb shell am force-stop $PKG
    adb shell am start -W -n $PKG/.MainActivity | tail -1 | tee -a "$LOG"
    sleep 5
    tap "Tools" 4 exact; sleep 1
    tap "Inside apps"; shot 31_apps 3
    tap "Allow access" 4 full; sleep 4; shot 32_shizuku_prompt 1
    tap "Allow all the time" 3 full || tap "Allow" 3 full
    apps_scan
  fi
elif [ "$SDK" -ge 30 ]; then
  # Android 11 keeps even adb out of Android/data: seed as root, then back to the normal shell.
  adb root >/dev/null 2>&1; sleep 4; adb wait-for-device
  seed_tg
  # like a real app folder: group ext_data_rw, readable by the storage provider
  adb shell chown -R 1023:1078 /data/media/0/Android/data/org.telegram.messenger
  adb shell chmod -R 2775 /data/media/0/Android/data/org.telegram.messenger
  adb shell ls -lR /data/media/0/Android/data/org.telegram.messenger | head -8 | tee -a "$LOG"
  adb unroot >/dev/null 2>&1; sleep 4; adb wait-for-device
  adb logcat -v time >> "$OUT/logcat_live.txt" 2>&1 &
  LOGCAT_PID=$!
  adb shell am force-stop $PKG
  adb shell am start -W -n $PKG/.MainActivity | tail -1 | tee -a "$LOG"
  sleep 5
  tap "Tools" 4 exact; sleep 1
  tap "Inside apps"; shot 31_apps 3
  tap "Allow access" 4 full; sleep 5; shot 32_folder_picker 1
  tap "Use this folder" 4 full; sleep 3; shot 33_folder_confirm 1
  tap "Allow" 4 full; sleep 3
  apps_scan
fi
adb shell ps -A | grep -i unlose | tee -a "$LOG"
grep -E "PhotosRecovery" "$OUT/logcat_live.txt" | tail -12 >> "$LOG" || true

# A scan with animations on, for a look at the real motion (no taps needed).
alive && { for k in window_animation_scale transition_animation_scale animator_duration_scale; do adb shell settings put global $k 1; done; }

timeout 20 adb shell dumpsys meminfo $PKG | grep -E "TOTAL|Java Heap|Native Heap|Graphics" > "$OUT/meminfo.txt" || true
kill $LOGCAT_PID 2>/dev/null || true
grep -E "FATAL EXCEPTION|E/flutter|ANR in|AndroidRuntime|unlose" "$OUT/logcat_live.txt" | head -120 > "$OUT/errors.txt" || true
say "errors: $(wc -l < "$OUT/errors.txt")"
exit 0
