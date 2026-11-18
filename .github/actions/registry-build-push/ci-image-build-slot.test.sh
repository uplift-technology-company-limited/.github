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
  OUT=$(env -i PATH="$PATH" HOME="$T" GITHUB_REPOSITORY=org/app GITHUB_WORKFLOW="deploy dev" GITHUB_RUN_ID=42 GITHUB_JOB=build \
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
( env -i PATH="$PATH" GITHUB_REPOSITORY=org/app GITHUB_RUN_ID=1 GITHUB_JOB=h1 RUNNER_TEMP="$T" CI_BUILD_LOCK_DIR="$L" CI_POOL_CGROUP="$P" \
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
  ( env -i PATH="$PATH" GITHUB_REPOSITORY=org/app GITHUB_JOB=$j RUNNER_TEMP="$T" CI_BUILD_LOCK_DIR="$L" CI_POOL_CGROUP="$P" \
    CI_POOL_CONF="$CONF" CI_BUILD_POLL=1 bash "$SUT" -- sleep 2 > "$T/$j.out" 2>&1 ) &
  PIDS+=($!)
done
sleep 0.5
OUT=$(env -i PATH="$PATH" GITHUB_REPOSITORY=org/app GITHUB_JOB=c RUNNER_TEMP="$T" CI_BUILD_LOCK_DIR="$L" CI_POOL_CGROUP="$P" \
  CI_POOL_CONF="$CONF" CI_BUILD_POLL=1 timeout 20 bash "$SUT" -- true 2>&1); RC=$?
w=$(waited)
check "นาฬิกาจริง: ตัวที่สามรอจนว่าง (ได้ $w วิ)" '[ $RC = 0 ] && [ "$w" -ge 1 ] && [ "$w" -le 4 ]'
wait
check "นาฬิกาจริง: a b ได้ทันทีทั้งคู่" 'grep -q "after 0 s" "$T/a.out" && grep -q "after 0 s" "$T/b.out"'
teardown

printf '\n%d ผ่าน · %d ล้ม\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
