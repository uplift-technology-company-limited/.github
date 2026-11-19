#!/usr/bin/env bash
# fixture test ของ ci-image-build-slot.sh · lock dir ปลอม + cgroup ปลอม + นาฬิกาปลอม (ไม่แตะ /data/build /sys จริง)
# รัน: bash .github/actions/registry-build-push/ci-image-build-slot.test.sh
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SUT=$HERE/ci-image-build-slot.sh
PASS=0 FAIL=0 PIDS=() RC=0 OUT=""
export RC OUT # อ่านใน check ผ่าน eval (shellcheck มองไม่เห็น)

ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /' | tail -25; }
check() { if eval "$2"; then ok "$1"; else no "$1" "$OUT"; fi; }

setup() {
  T=$(mktemp -d)
  L=$T/locks P=$T/pool CLK=$T/clock CONF=$T/pool.conf
  mkdir -p "$L" "$P/buildkit"
  printf 'usage_usec 1000\nuser_usec 500\n' > "$P/buildkit/cpu.stat"
  echo 1000000 > "$CLK"
  printf 'pool_max=7G\nheavy_repos=uplift-figcraft\n' > "$CONF"
}
teardown() {
  local p; for p in "${PIDS[@]}"; do kill "$p" 2> /dev/null; done
  wait 2> /dev/null; PIDS=(); rm -rf "$T"
}
clock() { cat "$CLK"; }

# hold <ชื่อ> <ปล่อยเมื่อนาฬิกา ≥> [grow|cpu|still] [pid_ใน_owner]
#   grow = เขียน log ทุกครั้งที่นาฬิกาขยับ · cpu = เพิ่ม usage_usec ของ buildkit/<id> · still = นิ่ง
hold() {
  local name=$1 until=$2 mode=${3:-still} fake_pid=${4:-} log=$T/holder-$1.log
  : >> "$L/$name.lock"
  (
    exec 9< "$L/$name.lock"; flock 9
    : > "$log"
    printf '%s %s %s\nlog=%s\n' "${fake_pid:-$BASHPID}" "$(clock)" "test holder $name" "$log" > "$L/$name.owner"
    last="" u=0
    mkdir -p "$P/buildkit/h-$name"
    while c=$(clock) && [ "$c" -lt "$until" ]; do
      if [ "$c" != "$last" ]; then
        case $mode in
          grow) echo "step at $c" >> "$log" ;;
          cpu) u=$((u + 7)); printf 'usage_usec %s\n' "$u" > "$P/buildkit/h-$name/cpu.stat" ;;
        esac
        last=$c
      fi
      sleep 0.01
    done
    : > "$L/$name.owner"
  ) &
  PIDS+=($!)
  local _; for _ in $(seq 200); do [ -s "$L/$name.owner" ] && return 0; sleep 0.01; done
  echo "hold $name ไม่ขึ้น" >&2
}

# run [env KEY=VAL…] -- <คำสั่ง…> ⇒ OUT RC
run() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  OUT=$(env -i PATH="$PATH" CI_BUILD_AUTO_HEAVY=0 HOME="$T" GITHUB_REPOSITORY=org/app GITHUB_WORKFLOW="deploy dev" GITHUB_RUN_ID=42 GITHUB_JOB=build \
    RUNNER_TEMP="$T" GITHUB_ENV="$T/github_env" CI_BUILD_LOCK_DIR="$L" CI_POOL_CGROUP="$P" CI_POOL_CONF="$CONF" \
    CI_BUILD_FAKE_CLOCK="$CLK" CI_BUILD_LOG="$T/build.log" "${envs[@]}" timeout 60 bash "$SUT" -- "$@" 2>&1)
  RC=$?
}
waited() { sed -n 's/.*หลังรอ \([0-9]*\) วิ.*/\1/p; s/.*Got the CI image-build slot after \([0-9]*\) s.*/\1/p' <<< "$OUT" | head -1; }

# 1 ช่องว่าง ⇒ ได้ทันที · owner มีครบ · log ถูก tee · ปล่อยแล้ว owner ว่าง
setup
run -- bash -c 'echo built; cat '"$L"'/ci-image-build-0.owner'
check "ว่าง: rc 0" '[ $RC = 0 ]'
check "ว่าง: พิมพ์ Got the CI image-build slot after 0 s" 'grep -q "Got the CI image-build slot after 0 s (ci-image-build-0)" <<< "$OUT"'
check "ว่าง: owner บรรทัด 1 = pid start label" 'grep -Eq "^[0-9]+ 1000000 ci org/app · deploy dev · run 42 · job build$" <<< "$OUT"'
check "ว่าง: owner มี repo workflow run_id job pid log started" 'for k in repo=org/app "workflow=deploy dev" run_id=42 job=build pid= log='"$T"'/build.log started=1000000 slot=ci-image-build-0 heavy=0; do grep -qx "$k.*" <<< "$OUT" || exit 1; done'
check "ว่าง: log build ถูก tee ลงไฟล์" 'grep -qx built "$T/build.log"'
check "ว่าง: ปล่อยแล้ว owner ว่าง" '[ ! -s "$L/ci-image-build-0.owner" ]'
check "ว่าง: เขียน CI_IMAGE_BUILD_WAIT_S ลง GITHUB_ENV" 'grep -qx CI_IMAGE_BUILD_WAIT_S=0 "$T/github_env"'
check "ว่าง: lock เป็น 0666" '[ "$(stat -c %a "$L/ci-image-build-0.lock")" = 666 ]'
teardown

# 2 ช่อง 0 เต็ม ⇒ ได้ช่อง 1 ทันที
setup; hold ci-image-build-0 9999999
run -- true
check "ช่อง 0 เต็ม: ได้ช่อง 1 ทันที" '[ $RC = 0 ] && grep -q "after 0 s (ci-image-build-1)" <<< "$OUT"'
teardown

# 3 เต็มทั้งสอง ⇒ รอ ⇒ ได้เมื่อผู้ถือปล่อย (นิ่งแต่ไม่ถึง 10 นาที)
setup; hold ci-image-build-0 $((1000000 + 300)); hold ci-image-build-1 9999999
run -- true
w=$(waited)
check "เต็ม: รอแล้วได้เมื่อผู้ถือปล่อย (~300 วิ · ได้ $w)" '[ $RC = 0 ] && [ "$w" -ge 300 ] && [ "$w" -le 310 ]'
check "เต็ม: พิมพ์ผู้ถือทุก 60 วิ (≥ 4 ครั้ง)" '[ "$(grep -c "^Still waiting" <<< "$OUT")" -ge 4 ] && grep -q "test holder ci-image-build-0" <<< "$OUT"'
teardown

# 4 ผู้ถือเดิน (log โต) ⇒ รอเกิน 10 นาทีไม่ล้ม
setup; hold ci-image-build-0 $((1000000 + 1500)) grow; hold ci-image-build-1 9999999 grow
run -- true
w=$(waited)
check "log โต: รอ 25 นาทีไม่ล้ม (ได้ $w วิ)" '[ $RC = 0 ] && [ "$w" -ge 1500 ]'
teardown

# 5 ผู้ถือเดินด้วย cpu ของ BuildKit (log ไม่โต) ⇒ ไม่ล้ม · cpu อ่านจากลูกเมื่อ parent ไม่มี cpu.stat
setup; rm -f "$P/buildkit/cpu.stat"; hold ci-image-build-0 $((1000000 + 1200)) cpu; hold ci-image-build-1 9999999
run -- true
w=$(waited)
check "cpu ขยับ: รอ 20 นาทีไม่ล้ม (ได้ $w วิ)" '[ $RC = 0 ] && [ "$w" -ge 1200 ]'
teardown

# 6 ผู้ถือนิ่ง 10 นาที ⇒ exit 75 พร้อมชื่อผู้ถือ · คำสั่งไม่ถูกรัน
setup; hold ci-image-build-0 9999999; hold ci-image-build-1 9999999
run -- touch "$T/ran"
w=$(waited)
check "นิ่ง: exit 75" '[ $RC = 75 ]'
check "นิ่ง: ล้มที่ ~600 วิ (ได้ $w)" '[ "$w" -ge 600 ] && [ "$w" -le 610 ]'
check "นิ่ง: ::error:: + ชื่อผู้ถือทั้งสองช่อง" 'grep -q "^::error::ผู้ถือ ช่อง image build นิ่ง 10 นาที" <<< "$OUT" && grep -q "test holder ci-image-build-0" <<< "$OUT" && grep -q "test holder ci-image-build-1" <<< "$OUT"'
check "นิ่ง: ไม่ build" '[ ! -e "$T/ran" ]'
teardown

# 7 CI_BUILD_STALL_MIN=3 ⇒ ล้มที่ ~180 วิ
setup; hold ci-image-build-0 9999999; hold ci-image-build-1 9999999
run CI_BUILD_STALL_MIN=3 -- true
w=$(waited)
check "STALL_MIN=3: exit 75 ที่ ~180 วิ (ได้ $w)" '[ $RC = 75 ] && [ "$w" -ge 180 ] && [ "$w" -le 190 ]'
teardown

# 8 CI_BUILD_LOCK_WAIT_MIN=1 ⇒ exit 75 ~60 วิ แม้ผู้ถือเดิน
setup; hold ci-image-build-0 9999999 grow; hold ci-image-build-1 9999999 grow
run CI_BUILD_LOCK_WAIT_MIN=1 -- touch "$T/ran"
w=$(waited)
check "WAIT_MIN=1: exit 75 ที่ ~60 วิ (ได้ $w)" '[ $RC = 75 ] && [ "$w" -ge 60 ] && [ "$w" -le 70 ]'
check "WAIT_MIN=1: ::error:: ระบุเพดาน + ผู้ถือ · ไม่ build" 'grep -q "^::error::รอ ช่อง image build เกิน CI_BUILD_LOCK_WAIT_MIN=1 นาที" <<< "$OUT" && grep -q "test holder ci-image-build-1" <<< "$OUT" && [ ! -e "$T/ran" ]'
teardown

# 9 heavy (heavy_repos ใน pool.conf) ⇒ ถือ ci-heavy-0 + ทั้ง 2 ช่องระหว่าง build
setup; printf 'heavy_repos=uplift-figcraft,app\n' > "$CONF"
run -- bash -c 'for n in ci-heavy-0 ci-image-build-0 ci-image-build-1; do if flock -n '"$L"'/$n.lock true; then echo FREE $n; else echo HELD $n; fi; done; grep -h "^heavy=" '"$L"'/*.owner'
check "heavy: ถือ ci-heavy-0 + 0 + 1" '[ $RC = 0 ] && [ "$(grep -c "^HELD" <<< "$OUT")" = 3 ] && ! grep -q "^FREE" <<< "$OUT"'
check "heavy: owner ทั้งสามเขียน heavy=1" '[ "$(grep -c "^heavy=1" <<< "$OUT")" = 3 ]'
check "heavy: ปล่อยครบ" '! grep -q . "$L"/*.owner'
teardown

# 10 heavy รอช่องที่ 2 ⇒ ถือ heavy+ช่อง 0 ไว้ รอช่อง 1 จนปล่อย
setup; printf 'heavy_repos=app\n' > "$CONF"; hold ci-image-build-1 $((1000000 + 120))
run -- true
w=$(waited)
check "heavy: รอช่องที่สองจนว่าง (~120 วิ · ได้ $w)" '[ $RC = 0 ] && [ "$w" -ge 120 ] && [ "$w" -le 130 ] && grep -q "(ci-heavy-0 ci-image-build-0 ci-image-build-1)" <<< "$OUT"'
teardown

# 11 ระหว่าง heavy ถือ ⇒ build ธรรมดารอ (เพดาน 1 นาที ⇒ 75) · heavy ตัวที่สองก็รอ
setup; printf 'heavy_repos=app\n' > "$CONF"
( env -i PATH="$PATH" CI_BUILD_AUTO_HEAVY=0 GITHUB_REPOSITORY=org/app GITHUB_RUN_ID=1 GITHUB_JOB=h1 RUNNER_TEMP="$T" CI_BUILD_LOCK_DIR="$L" CI_POOL_CGROUP="$P" \
  CI_POOL_CONF="$CONF" CI_BUILD_LOG="$T/h1.log" bash "$SUT" -- sleep 4 > "$T/h1.out" 2>&1 ) &
PIDS+=($!)
for _ in $(seq 200); do [ -s "$L/ci-image-build-1.owner" ] && break; sleep 0.02; done
run GITHUB_REPOSITORY=org/other CI_BUILD_LOCK_WAIT_MIN=1 -- touch "$T/ran"
check "heavy ถืออยู่: build ธรรมดารอแล้วล้ม 75 · ผู้ถือ = job h1" '[ $RC = 75 ] && grep -q "job h1" <<< "$OUT" && [ ! -e "$T/ran" ]'
run CI_BUILD_LOCK_WAIT_MIN=1 -- true
check "heavy ถืออยู่: heavy ตัวที่สองรอ ci-heavy-0 แล้วล้ม 75" '[ $RC = 75 ] && grep -q "รอ ci-heavy-0 (heavy) เกิน" <<< "$OUT"'
teardown

# 12 CI_BUILD_HEAVY=1 บังคับ heavy ได้ (เพิ่มได้อย่างเดียว) · pool.conf หาย ⇒ ค่าเริ่ม uplift-figcraft
setup
run CI_BUILD_HEAVY=1 -- true
check "CI_BUILD_HEAVY=1: ถือแบบ heavy" '[ $RC = 0 ] && grep -q "(ci-heavy-0 ci-image-build-0 ci-image-build-1)" <<< "$OUT"'
rm -f "$CONF"
run GITHUB_REPOSITORY=org/uplift-figcraft -- true
check "pool.conf หาย: uplift-figcraft ยัง heavy" '[ $RC = 0 ] && grep -q "ไม่พบ" <<< "$OUT" && grep -q "(ci-heavy-0 ci-image-build-0 ci-image-build-1)" <<< "$OUT"'
teardown

# 13 pool.conf parse แบบ allow-list: ไม่ source · บรรทัดผิดเมิน + เตือน · heavy_repos ผิดรูปใช้ค่าเริ่ม
setup
printf '%s\n' '# c' 'heavy_repos=app;touch '"$T"'/pwned' 'heavy_repos = app' 'bogus=1' '$(touch '"$T"'/pwned2)' 'pool_max=7G' > "$CONF"
run -- true
check "conf: บรรทัดผิดถูกเมินพร้อมเตือน · ไม่รันโค้ดในไฟล์" '[ $RC = 0 ] && [ "$(grep -c "^::warning::pool.conf บรรทัด" <<< "$OUT")" = 4 ] && [ ! -e "$T/pwned" ] && [ ! -e "$T/pwned2" ]'
check "conf: heavy_repos ผิดรูป ⇒ app ไม่ heavy" 'grep -q "after 0 s (ci-image-build-0)$\|after 0 s (ci-image-build-0) ·" <<< "$OUT"'
teardown

# 14 ไม่มีทาง "building anyway": เปิด lock ไม่ได้ ⇒ 75 ไม่ build
setup; : > "$L/ci-image-build-0.lock"; chmod 000 "$L/ci-image-build-0.lock"
if [ "$(id -u)" != 0 ]; then
  run -- touch "$T/ran"
  check "lock เปิดไม่ได้: exit 75 ไม่ build" '[ $RC = 75 ] && grep -q "^::error::เปิด .*ci-image-build-0.lock ไม่ได้" <<< "$OUT" && [ ! -e "$T/ran" ]'
fi
chmod 644 "$L/ci-image-build-0.lock"
OUT=$(grep -n -i -E 'anyway|run.?anyway' "$SUT" "$HERE/action.yml" "$HERE/../bq-slot/action.yml" || true)
check "ไม่มีข้อความ/ทาง building anyway ใน script + action.yml (bq-slot ไม่มี run anyway)" '[ -z "$OUT" ]'
teardown

# 15 ผู้ถือตายแต่ lock ค้าง (fd ค้างกับ process อื่น) ⇒ 75 เร็ว ไม่รอ 10 นาที
setup
sleep 0 & dead=$!; wait $dead
hold ci-image-build-0 9999999 grow "$dead"; hold ci-image-build-1 9999999 grow "$dead"
run -- true
w=$(waited)
check "ผู้ถือตาย: exit 75 ภายในไม่กี่รอบ (ได้ $w วิ) พร้อม (ตายแล้ว)" '[ $RC = 75 ] && [ "$w" -le 15 ] && grep -q "ตายแล้วแต่ lock ยังค้าง" <<< "$OUT" && grep -q "(ตายแล้ว)" <<< "$OUT"'
teardown

# 16 ผู้ถือตายแค่ช่องเดียว ช่องอื่นยังเดิน ⇒ ไม่ล้ม ได้ช่องที่เดินเมื่อปล่อย
setup
sleep 0 & dead=$!; wait $dead
hold ci-image-build-0 9999999 still "$dead"; hold ci-image-build-1 $((1000000 + 200)) grow
run -- true
check "ตายช่องเดียว: ไม่ล้ม ได้ช่อง 1" '[ $RC = 0 ] && grep -q "(ci-image-build-1)" <<< "$OUT"'
teardown

# 17 คำสั่งลูกไม่ได้ fd ของ lock · rc ของคำสั่งส่งต่อ · owner ว่างหลังล้ม
setup
run -- bash -c 'ls -l /proc/self/fd/ | grep -c "\.lock" || true; exit 7'
check "rc ของคำสั่งส่งต่อ (7)" '[ $RC = 7 ]'
check "คำสั่งลูกไม่มี fd ของ .lock" 'grep -qx 0 <<< "$OUT"'
check "หลังล้ม owner ว่าง lock ว่าง" '[ ! -s "$L/ci-image-build-0.owner" ] && flock -n "$L/ci-image-build-0.lock" true'
teardown

# 18 env ผิดรูป ⇒ 64
setup
run CI_BUILD_STALL_MIN=abc -- true; check "STALL_MIN=abc ⇒ 64" '[ $RC = 64 ]'
run CI_BUILD_LOCK_WAIT_MIN=1m -- true; check "LOCK_WAIT_MIN=1m ⇒ 64" '[ $RC = 64 ]'
run -- ; check "ไม่มีคำสั่ง ⇒ 64" '[ $RC = 64 ]'
teardown

# 19 นาฬิกาจริง (ไม่ปลอม) · POLL 1 · สองตัวขนานได้ ตัวที่สามรอแล้วได้
setup
for j in a b; do
  ( env -i PATH="$PATH" CI_BUILD_AUTO_HEAVY=0 GITHUB_REPOSITORY=org/app GITHUB_JOB=$j RUNNER_TEMP="$T" CI_BUILD_LOCK_DIR="$L" CI_POOL_CGROUP="$P" \
    CI_POOL_CONF="$CONF" CI_BUILD_POLL=1 bash "$SUT" -- sleep 2 > "$T/$j.out" 2>&1 ) &
  PIDS+=($!)
done
sleep 0.5
OUT=$(env -i PATH="$PATH" CI_BUILD_AUTO_HEAVY=0 GITHUB_REPOSITORY=org/app GITHUB_JOB=c RUNNER_TEMP="$T" CI_BUILD_LOCK_DIR="$L" CI_POOL_CGROUP="$P" \
  CI_POOL_CONF="$CONF" CI_BUILD_POLL=1 timeout 20 bash "$SUT" -- true 2>&1); RC=$?
w=$(waited)
check "นาฬิกาจริง: ตัวที่สามรอจนว่าง (ได้ $w วิ)" '[ $RC = 0 ] && [ "$w" -ge 1 ] && [ "$w" -le 4 ]'
wait
check "นาฬิกาจริง: a b ได้ทันทีทั้งคู่" 'grep -q "after 0 s" "$T/a.out" && grep -q "after 0 s" "$T/b.out"'
teardown

# ═══ heavy อัตโนมัติจาก peak (เพดานปลอม 8053063680 = 7680 MiB · ครึ่ง = 3840) ═══
CAPB=8053063680
PK=
# peakenv: ตั้ง cap ปลอม · dir peak ปลอม · probe 1 ครั้ง (deterministic) ⇒ ใช้กับ run ผ่าน PENV
mkcap() { echo "$CAPB" > "$P/buildkit/memory.max"; PK=$T/peaks; PENV=(CI_BUILD_AUTO_HEAVY=1 CI_BUILD_PEAK_DIR="$PK" CI_BUILD_PROBE_ONCE=1 IMAGE_REPO=img); }
mkstat() { # $1=dir $2=anon $3=shmem
  mkdir -p "$P/buildkit/$1"; printf 'anon %s\nanon_thp 5\nfile 9\nshmem %s\n' "$2" "$3" > "$P/buildkit/$1/memory.stat"
}
mkpeak() { # $1=เนื้อหา $2=epoch ของ mtime
  mkdir -p "$PK"; printf '%s\n' "$1" > "$PK/app__img"; touch -d "@$2" "$PK/app__img"
}
HV='(ci-heavy-0 ci-image-build-0 ci-image-build-1)'

# 20 ไม่มีไฟล์ peak ⇒ heavy + พิมพ์เหตุผล
setup; mkcap
run "${PENV[@]}" -- true
check "peak: ไม่มีไฟล์ ⇒ heavy" '[ $RC = 0 ] && grep -qF "$HV" <<< "$OUT" && grep -q "first build of this image (no peak recorded)" <<< "$OUT"'
teardown

# 21 peak ≤ cap/2 และสด ⇒ ช่องปกติ
setup; mkcap; echo 5000000 > "$CLK"; mkpeak "3840 4999999 1 1" 4999999
run "${PENV[@]}" -- true
check "peak: 3840 ≤ ครึ่งเพดาน ⇒ ช่องปกติ" '[ $RC = 0 ] && grep -q "after 0 s (ci-image-build-0)" <<< "$OUT" && grep -q "last peak 3840 MiB <= half of cap 7680 MiB => normal slot" <<< "$OUT"'
teardown

# 22 peak > cap/2 ⇒ heavy
setup; mkcap; echo 5000000 > "$CLK"; mkpeak "3841 4999999 1 1" 4999999
run "${PENV[@]}" -- true
check "peak: 3841 > ครึ่งเพดาน ⇒ heavy" '[ $RC = 0 ] && grep -qF "$HV" <<< "$OUT" && grep -q "last peak 3841 MiB > half of cap 7680 MiB" <<< "$OUT"'
teardown

# 23 ไฟล์เก่ากว่า 14 วัน ⇒ heavy (ตรงขอบ 14 วันพอดี ยังสด)
setup; mkcap; echo 5000000 > "$CLK"; mkpeak "100 1 1 1" $((5000000 - 14 * 86400 - 1))
run "${PENV[@]}" -- true
check "peak: เก่ากว่า 14 วัน ⇒ heavy" '[ $RC = 0 ] && grep -qF "$HV" <<< "$OUT" && grep -q "peak record older than 14 days" <<< "$OUT"'
mkpeak "100 1 1 1" $((5000000 - 14 * 86400))
run "${PENV[@]}" -- true
check "peak: อายุ 14 วันพอดี ยังสด ⇒ ช่องปกติ" '[ $RC = 0 ] && grep -q "after 0 s (ci-image-build-0)" <<< "$OUT"'
teardown

# 24 ไฟล์ไม่ถูกต้อง ⇒ เตือน + heavy
for bad in "hello" "-5 1 1 1" "15361 1 1 1" "100 1 1" "100 1 1 1 1" ""; do
  setup; mkcap; echo 5000000 > "$CLK"; mkpeak "$bad" 4999999
  run "${PENV[@]}" -- true
  check "peak ไม่ถูกต้อง ('$bad') ⇒ ::warning:: + heavy" '[ $RC = 0 ] && grep -q "^::warning::peak record" <<< "$OUT" && grep -qF "$HV" <<< "$OUT" && grep -q "peak record invalid" <<< "$OUT"'
  teardown
done
setup; mkcap; echo 5000000 > "$CLK"; mkpeak "15360 1 1 1" 4999999
run "${PENV[@]}" -- true
check "peak = 2×เพดานพอดี ยังถูกต้อง ⇒ heavy เพราะเกินครึ่ง (ไม่เตือน)" '! grep -q "^::warning::peak record" <<< "$OUT" && grep -q "> half of cap" <<< "$OUT"'
teardown

# 25 เพดานหาย / max / ไม่ใช่เลข ⇒ ไม่รู้เพดาน: รันเดี่ยว (heavy) + warning · ไม่วัด ไม่เขียน peak · AUTO_HEAVY=0 ⇒ พฤติกรรมเดิม
for capv in MISSING max abc; do
  setup; mkcap; PK=$T/peaks
  if [ $capv = MISSING ]; then rm -f "$P/buildkit/memory.max"; else echo "$capv" > "$P/buildkit/memory.max"; fi
  mkstat r1 1000000000 0
  run "${PENV[@]}" -- true
  check "เพดาน=$capv: ไม่รู้เพดาน ⇒ heavy + warning ไม่มี stats ไม่เขียน peak" '[ $RC = 0 ] && grep -q "peak-aware heavy: off" <<< "$OUT" && grep -q "::warning::peak-aware heavy: อ่านเพดาน" <<< "$OUT" && grep -qF "$HV" <<< "$OUT" && ! grep -q "CI image-build stats" <<< "$OUT" && [ ! -e "$PK" ]'
  run "${PENV[@]}" CI_BUILD_AUTO_HEAVY=0 -- true
  check "เพดาน=$capv + AUTO_HEAVY=0: พฤติกรรมเดิม ช่องปกติ ไม่มี warning" '[ $RC = 0 ] && grep -q "after 0 s (ci-image-build-0)" <<< "$OUT" && ! grep -q "::warning::peak-aware" <<< "$OUT" && [ ! -e "$PK" ]'
  run "${PENV[@]}" CI_BUILD_HEAVY=1 -- true
  check "เพดาน=$capv: CI_BUILD_HEAVY=1 ยัง heavy ตามกฎเดิม (ไม่มี warning ซ้ำ)" '[ $RC = 0 ] && grep -qF "$HV" <<< "$OUT" && ! grep -q "::warning::peak-aware" <<< "$OUT" && [ ! -e "$PK" ]'
  teardown
done

# 26 CI_BUILD_AUTO_HEAVY=0 + ไม่มีไฟล์ ⇒ ช่องปกติ แต่เขียน peak
setup; mkcap; mkstat r1 1073741824 0
run "${PENV[@]}" CI_BUILD_AUTO_HEAVY=0 -- true
check "AUTO_HEAVY=0: ช่องปกติ + เขียน peak" '[ $RC = 0 ] && grep -q "after 0 s (ci-image-build-0)" <<< "$OUT" && grep -q "CI_BUILD_AUTO_HEAVY=0" <<< "$OUT" && grep -Eq "^1024 [0-9]+ 42 1$" "$PK/app__img"'
teardown

# 27 peak จาก memory.stat ปลอม: 2 RUN dir รวม anon+shmem · alone=1 เมื่อช่องอื่นว่าง
setup; mkcap; echo 5000000 > "$CLK"; mkpeak "100 1 1 1" 4999999
mkstat run-a 1073741824 104857600; mkstat run-b 2147483648 0   # 1024+100+2048 = 3172 MiB
run "${PENV[@]}" -- true
check "peak: รวม anon+shmem ของ 2 dir = 3172 · alone=1" '[ $RC = 0 ] && grep -Eq "^3172 [0-9]+ 42 1$" "$PK/app__img" && grep -q "peak_mib=3172 cap_mib=7680 alone=1 heavy=0 rc=0" <<< "$OUT"'
teardown

# 28 ช่องอื่นมีผู้ถือ pid ยังอยู่ ⇒ alone=0
setup; mkcap; echo 5000000 > "$CLK"; mkpeak "100 1 1 1" 4999999
hold ci-image-build-1 9999999; mkstat run-a 1073741824 0
run "${PENV[@]}" -- true
check "peak: ช่องอื่นมีผู้ถือที่ยังอยู่ ⇒ alone=0" '[ $RC = 0 ] && grep -Eq "^1024 [0-9]+ 42 0$" "$PK/app__img" && grep -q "alone=0 heavy=0" <<< "$OUT"'
teardown

# 29 ช่องอื่นมี owner แต่ pid ตายแล้ว ⇒ alone=1
setup; mkcap; echo 5000000 > "$CLK"; mkpeak "100 1 1 1" 4999999
sleep 0 & dead=$!; wait $dead
hold ci-image-build-1 9999999 still "$dead"
run "${PENV[@]}" -- true
check "peak: ช่องอื่นผู้ถือตาย ⇒ alone=1" '[ $RC = 0 ] && grep -q "alone=1 heavy=0" <<< "$OUT"'
teardown

# 30 คำสั่งล้ม + oom_kill เพิ่ม ⇒ peak = cap_mib · ล้มแต่ไม่เพิ่ม ⇒ ไม่จด (ค่าเดิมคงไว้) · rc ส่งต่อ
setup; mkcap; echo 5000000 > "$CLK"; mkpeak "100 1 1 1" 4999999
printf 'low 0\noom 0\noom_kill 2\n' > "$P/buildkit/memory.events"; mkstat r 1073741824 0
run "${PENV[@]}" -- bash -c 'printf "low 0\noom 1\noom_kill 3\n" > '"$P"'/buildkit/memory.events; exit 137'
check "OOM: ล้ม + oom_kill เพิ่ม ⇒ บันทึก peak = cap_mib" '[ $RC = 137 ] && grep -Eq "^7680 [0-9]+ 42 1$" "$PK/app__img" && grep -q "hit the build memory cap" <<< "$OUT" && grep -q "peak_mib=7680 cap_mib=7680 alone=1 heavy=0 rc=137" <<< "$OUT"'
printf 'oom_kill 3\n' > "$P/buildkit/memory.events"
run "${PENV[@]}" -- bash -c 'exit 3'
check "ล้มแต่ oom_kill ไม่เพิ่ม ⇒ ไม่จด peak · ค่าเดิม (7680 จากรอบ OOM) คงไว้" '[ $RC = 3 ] && grep -Eq "^7680 [0-9]+ 42 1$" "$PK/app__img" && grep -q "ไม่จด peak รอบนี้" <<< "$OUT" && ! grep -q "hit the build memory cap" <<< "$OUT"'
teardown

# 31 alone=1 และ peak > เกณฑ์ ⇒ warning + step summary + alerts.log · alone=0 ไม่เตือน
setup; mkcap; echo 5000000 > "$CLK"; mkpeak "100 1 1 1" 4999999
mkstat big 7340032000 0   # 7000 MiB > 6656
run "${PENV[@]}" GITHUB_STEP_SUMMARY="$T/summary.md" -- true
check "เตือน: alone=1 peak 7000 > 6656 ⇒ ::warning:: ระบุ OOM-killed" '[ $RC = 0 ] && grep -q "^::warning::image build app/img peaked at 7000 MiB of a 7680 MiB cap and will be OOM-killed (exit 137)" <<< "$OUT"'
check "เตือน: step summary 1 บรรทัด + alerts.log" '[ "$(wc -l < "$T/summary.md")" = 1 ] && grep -q "peaked at 7000 MiB" "$T/summary.md" && grep -Eq "^[0-9]+ app img 7000 7680 42$" "$PK/alerts.log"'
rm -f "$PK/alerts.log" "$T/summary.md"; mkpeak "100 1 1 1" 4999999
hold ci-image-build-1 9999999
run "${PENV[@]}" GITHUB_STEP_SUMMARY="$T/summary.md" -- true
check "ไม่เตือนเมื่อ alone=0 (ช่องอื่นมีผู้ถือ)" '[ $RC = 0 ] && grep -q "alone=0" <<< "$OUT" && ! grep -q "^::warning::image build" <<< "$OUT" && [ ! -e "$T/summary.md" ] && [ ! -e "$PK/alerts.log" ]'
teardown

# 32 sanitise key: / .. ช่องว่าง ⇒ ไฟล์อยู่ใน peak dir เท่านั้น
setup; mkcap; mkstat r 1073741824 0
run "${PENV[@]}" GITHUB_REPOSITORY="org/../etc" IMAGE_REPO="ghcr.io/a b/../../x" -- true
check "key: ไฟล์เดียวใน peak dir · ชื่อไม่มี / .. ช่องว่าง" '[ $RC = 0 ] && [ "$(ls -A "$PK" | wc -l)" = 1 ] && n=$(ls -A "$PK") && [[ $n != */* && $n != *..* && $n != *" "* ]] && [ -s "$PK/$n" ] && [ ! -e "$T/etc" ] && [ ! -e "$T/x" ]'
OUT=$(ls -A "$PK"); check "key: ชื่อหลัง sanitise ตรงตามคาด" '[ "$OUT" = "etc__ghcr.io_a_b_______x" ]'
teardown

# 33 บรรทัดสถิติ + rc คงเดิม (0 และไม่ใช่ 0) · ปล่อย lock ครบ · probe ไม่ค้าง
setup; mkcap; echo 5000000 > "$CLK"; mkpeak "100 1 1 1" 4999999
run "${PENV[@]}" -- bash -c 'echo 5000000 > '"$CLK"'.n; mv '"$CLK"'.n '"$CLK"'; exit 0'
check "stats: รูปแบบครบ wait_s/hold_s · rc=0" '[ $RC = 0 ] && grep -Eq "^CI image-build stats: wait_s=0 hold_s=[0-9]+ peak_mib=0 cap_mib=7680 alone=1 heavy=0 rc=0$" <<< "$OUT"'
run "${PENV[@]}" -- bash -c 'exit 9'
check "stats: rc=9 ส่งต่อ + พิมพ์ rc=9" '[ $RC = 9 ] && grep -q "rc=9$" <<< "$OUT" && [ ! -s "$L/ci-image-build-0.owner" ]'
teardown

# 34 hold_s / wait_s ใช้นาฬิกาปลอม
setup; mkcap; echo 5000000 > "$CLK"; mkpeak "100 1 1 1" 4999999
hold ci-image-build-0 $((5000000 + 100)); hold ci-image-build-1 $((5000000 + 100))
run "${PENV[@]}" -- bash -c 'echo 5000321 > '"$CLK"
check "stats: wait_s≥100 และ hold_s=321-ish" '[ $RC = 0 ] && grep -Eq "wait_s=1[0-9][0-9] hold_s=(2[0-9][0-9]|3[0-9][0-9])" <<< "$OUT"'
teardown

# 35 probe แบบ background (ไม่ใช่ ONCE): วัดได้ และไม่ค้างหลังสคริปต์จบ (pid ตายหมด)
setup; mkcap; echo 5000000 > "$CLK"; mkpeak "100 1 1 1" 4999999; mkstat r 2147483648 0
run CI_BUILD_PEAK_DIR="$PK" CI_BUILD_PROBE_SEC=1 IMAGE_REPO=img -- bash -c 'sleep 0.3'
check "probe background: วัดได้ 2048 MiB" '[ $RC = 0 ] && grep -Eq "^2048 " "$PK/app__img" && grep -q "peak_mib=2048" <<< "$OUT"'
check "probe background: ไม่มีไฟล์ probe ค้าง" '[ -z "$(ls -A "$T" | grep "ci-image-probe")" ]'
teardown

# 36 ratchet: ไม่ให้ build ที่ต่ำกว่า/cache hit ทับ record สดที่ alone=1
ratchet_run() { run "${PENV[@]}" -- true; }
setup; mkcap; echo 5000000 > "$CLK"; mkpeak "5000 4999999 1 1" 4999999; mkstat r 314572800 0   # 300 MiB
ratchet_run
check "ratchet a: record สด 5000 alone=1 + build ใหม่ 300 ⇒ คง 5000" '[ $RC = 0 ] && grep -Eq "^5000 4999999 1 1$" "$PK/app__img" && grep -q "peak ratchet: new peak 300 MiB < recorded 5000 MiB (fresh, alone=1)" <<< "$OUT" && grep -q "peak_mib=300 " <<< "$OUT"'
teardown
setup; mkcap; echo 5000000 > "$CLK"; mkpeak "5000 1 1 1" $((5000000 - 14 * 86400 - 1)); mkstat r 314572800 0
ratchet_run
check "ratchet b: record หมดอายุ ⇒ เขียน 300 ทับ" '[ $RC = 0 ] && grep -Eq "^300 [0-9]+ 42 1$" "$PK/app__img"'
teardown
setup; mkcap; echo 5000000 > "$CLK"   # ไม่มีไฟล์ · peak 0
ratchet_run
check "ratchet c1: ไม่มี record + peak 0 ⇒ ไม่เขียนไฟล์" '[ $RC = 0 ] && [ ! -e "$PK/app__img" ] && grep -q "peak 0 MiB (no RUN seen · cache hit) ⇒ not recording peak" <<< "$OUT"'
teardown
setup; mkcap; echo 5000000 > "$CLK"; mkpeak "5000 4999999 1 1" 4999999
ratchet_run
check "ratchet c2: มี record + peak 0 ⇒ ไฟล์เดิมไม่เปลี่ยน" '[ $RC = 0 ] && grep -Eq "^5000 4999999 1 1$" "$PK/app__img" && grep -q "not recording peak" <<< "$OUT" && grep -q "peak_mib=0 " <<< "$OUT"'
teardown
setup; mkcap; echo 5000000 > "$CLK"; mkpeak "5000 4999999 1 0" 4999999; mkstat r 314572800 0
ratchet_run
check "ratchet d: record alone=0 ⇒ ทับด้วย 300 ได้" '[ $RC = 0 ] && grep -Eq "^300 [0-9]+ 42 1$" "$PK/app__img"'
teardown
setup; mkcap; echo 5000000 > "$CLK"; mkpeak "300 4999999 1 1" 4999999; mkstat r 5242880000 0   # 5000 MiB
ratchet_run
check "ratchet e: record 300 + build ใหม่ 5000 ⇒ เขียน 5000" '[ $RC = 0 ] && grep -Eq "^5000 [0-9]+ 42 1$" "$PK/app__img"'
teardown
setup; mkcap; echo 5000000 > "$CLK"; mkpeak "5000 4999999 1 1" 4999999
printf 'oom_kill 2\n' > "$P/buildkit/memory.events"; mkstat r 314572800 0
run "${PENV[@]}" -- bash -c 'printf "oom_kill 3\n" > '"$P"'/buildkit/memory.events; exit 137'
check "ratchet f: ชนเพดาน ⇒ เขียน = cap (7680) ทับ 5000" '[ $RC = 137 ] && grep -Eq "^7680 [0-9]+ 42 1$" "$PK/app__img"'
teardown
setup; mkcap; echo 5000000 > "$CLK"; mkpeak "9000 4999999 1 1" 4999999
printf 'oom_kill 2\n' > "$P/buildkit/memory.events"; mkstat r 314572800 0
run "${PENV[@]}" -- bash -c 'printf "oom_kill 3\n" > '"$P"'/buildkit/memory.events; exit 137'
check "ratchet f2: record เดิม 9000 (> cap) ชนเพดาน ⇒ ยังเขียน 7680 (ไม่ถูก ratchet กัน)" '[ $RC = 137 ] && grep -Eq "^7680 [0-9]+ 42 1$" "$PK/app__img"'
teardown

printf '\n%d ผ่าน · %d ล้ม\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
