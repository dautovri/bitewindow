#!/bin/zsh
# One continuous Simulator take of the real Debug app (sample spots from
# -BCSeedSpots, live forecast data). Usage: record.sh <udid> <lang> <locale> <outdir>
set -u
U=$1 L=$2 LOC=$3 OUT=$4; BID=com.dautovri.bitecurve
mkdir -p $OUT; M=$OUT/$L.marks; : > $M
xcrun simctl status_bar $U override --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 --operatorName ""
xcrun simctl terminate $U $BID >/dev/null 2>&1

xcrun simctl launch $U $BID -BCSkipWelcome YES -BCSeedSpots YES -BCPro YES -AppleLanguages "($L)" -AppleLocale $LOC >/dev/null; sleep 9
xcrun simctl io $U recordVideo --codec=h264 --force $OUT/$L.mp4 2>/dev/null & REC=$!
sleep 1.5; T0=$(python3 -c 'import time;print(time.time())')
mark(){ python3 -c "import time;print('$1', round(time.time()-$T0,2))" >> $M; }
mark list; sleep 5
mark detail; axe tap --udid $U -x 200 -y 239 >/dev/null; sleep 6
mark factors; axe swipe --start-x 220 --start-y 760 --end-x 220 --end-y 300 --duration 1.0 --udid $U >/dev/null; sleep 5
axe gesture swipe-from-left-edge --screen-width 440 --screen-height 956 --udid $U >/dev/null; sleep 1.5
mark planner; axe tap --udid $U -x 40 -y 83 >/dev/null; sleep 6
axe gesture swipe-from-left-edge --screen-width 440 --screen-height 956 --udid $U >/dev/null; sleep 1.5
mark map; axe tap --udid $U -x 172 -y 916 >/dev/null; sleep 6
mark log; axe tap --udid $U -x 266 -y 916 >/dev/null; sleep 5
sleep 4
kill -INT $REC; wait $REC; mark end
cat $M
