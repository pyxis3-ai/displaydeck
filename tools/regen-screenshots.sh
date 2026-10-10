#!/bin/bash
set -e
cd "$(dirname "$0")/.."
DD="com.local.DisplayDeck"
TMP=$(mktemp -d)

echo "building capture tools…"
clang -fobjc-arc -O2 -framework Cocoa -framework ApplicationServices tools/ddshot.m  -o "$TMP/ddshot"
clang -fobjc-arc          -framework Cocoa                              tools/ddcrop.m  -o "$TMP/ddcrop"

relaunch(){ osascript -e 'quit app "DisplayDeck"' 2>/dev/null || true; sleep 2; open -a DisplayDeck; sleep 3; }

echo "capturing main menu + submenus…"
relaunch
"$TMP/ddshot" "$TMP/menu.png" > "$TMP/rows.tsv"
"$TMP/ddshot" "$TMP/forcehidpi.png" "Force HiDPI"
"$TMP/ddshot" "$TMP/windowsnap.png" "Snap Window"
"$TMP/ddshot" "$TMP/arrange.png"    "Arrange Windows"
"$TMP/ddshot" "$TMP/keepawake.png"  "Keep Awake"
"$TMP/ddshot" "$TMP/resolution.png" "Resolution"
"$TMP/ddshot" "$TMP/settings.png"   "Settings"

echo "cropping Brightness/Warmth + Transparency sections from the menu…"
W=$(sips -g pixelWidth "$TMP/menu.png" | awk '/pixelWidth/{print $2}')
BW=$(awk -F'\t' '$3=="Keep Awake" {top=$1+$2} index($3,"Resolution")==1 && top!="" {print top, $1-top; exit}' "$TMP/rows.tsv")
TR=$(awk -F'\t' '$3=="Transparency" {top=$1} $3=="All Apps" && top!="" {print top, $1+$2-top; exit}' "$TMP/rows.tsv")
[ -n "$BW" ] && [ -n "$TR" ] || { echo "couldn't find the Brightness or Transparency rows in the menu" >&2; exit 1; }
"$TMP/ddcrop" "$TMP/menu.png" 0 "${BW% *}" "$W" "${BW#* }" "$TMP/brightness-warmth.png"
"$TMP/ddcrop" "$TMP/menu.png" 0 "${TR% *}" "$W" "${TR#* }" "$TMP/transparency.png"

echo "capturing Remote Access with the relay IP masked…"
REAL=$(defaults read "$DD" RemoteRelayHost 2>/dev/null || echo "")
restore_relay(){ [ -n "$REAL" ] && defaults write "$DD" RemoteRelayHost "$REAL" || defaults delete "$DD" RemoteRelayHost 2>/dev/null || true; }
trap restore_relay EXIT
defaults write "$DD" RemoteRelayHost "relay.example.com"
relaunch
"$TMP/ddshot" "$TMP/remote.png" "Remote Access"
restore_relay; trap - EXIT
relaunch

echo "installing into assets/ and docs/assets/…"
for d in assets/screenshots docs/assets/screenshots; do
  cp "$TMP"/{menu,forcehidpi,windowsnap,arrange,keepawake,resolution,settings,remote,brightness-warmth,transparency}.png "$d/"
done
rm -rf "$TMP"
echo "done - review with: git diff --stat assets docs/assets"
