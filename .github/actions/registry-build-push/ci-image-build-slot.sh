#!/usr/bin/env bash
# ci-image-build-slot.sh -- <command…>
# ถือที่นั่ง image build ของ uplift-server-01 แล้วรันคำสั่ง (docker build) · FINAL-PLAN S2 (ข้อ 3.3 แถว 3 · 3.4 · M3)
#
#   1. semaphore 2 ช่อง: flock $LOCK_DIR/ci-image-build-{0,1}.lock · ได้ช่องไหนก็ได้
#   2. repo ใน heavy_repos ของ pool.conf (หรือ CI_BUILD_HEAVY=1) ⇒ ถือ ci-heavy-0.lock ก่อน แล้วถือทั้ง 2 ช่อง
#      ⇒ ไม่มี image build อื่นซ้อน (Rust 1 งาน ~6 GB · 2 งานใน pool 7G = OOM แน่นอน)
#   3. 🔴 ไม่มีทาง "รันโดยไม่ถือที่นั่ง" · เปิด lock ไม่ได้ = ล้ม exit 75 (ทางเลี่ยงของรุ่นเดิมที่ build ต่อเมื่อรอนาน ตัดทิ้งแล้ว)
#   4. การรอ (คำสั่ง Anon 17 พ.ย. แทน deadline ตายตัว): รอได้ตราบที่ผู้ถือยังทำงาน · ล้ม exit 75 พร้อมชื่อผู้ถือ เมื่อ
#      ก. pid ผู้ถือตายแต่ lock ยังค้าง (เห็น 2 รอบติด · ไม่ควรเกิดกับ flock เพราะ lock ตายตาม fd) หรือ
#      ข. "นิ่ง" CI_BUILD_STALL_MIN นาทีติดกัน (ค่าเริ่ม 10) = log build ของผู้ถือไม่โต และ cpu ของ BuildKit ใน pool
#         (cpu.stat usage_usec ของ $POOL/buildkit และลูก ๆ) ไม่เปลี่ยน และผู้ถือไม่เปลี่ยนตัว
#      ค. (optional) รอรวมเกิน CI_BUILD_LOCK_WAIT_MIN นาที · ไม่ตั้ง/0 = ไม่จำกัด · canary ตั้ง 1 เพื่อพิสูจน์ล้มดัง
#      ระหว่างรอพิมพ์ผู้ถือทุก 60 วิ · ได้แล้วพิมพ์ "Got the CI image-build slot"
#   5. log ของคำสั่ง tee ลงไฟล์ที่ owner file ชี้ ⇒ ผู้รอวัดการโตได้ · lock fd ไม่ส่งต่อให้คำสั่งลูก
#      ⇒ lock อยู่เท่าอายุ pid ใน owner file พอดี
#
# owner file $LOCK_DIR/<ชื่อ>.owner (0666 อ่านได้ทุกคน · ci-status อ่าน):
#   บรรทัด 1 = "pid start_epoch label" (สัญญาเดียวกับ build-queue-v3 · ci-status · pool-guard อ่านบรรทัดแรกเท่านั้น)
#   บรรทัดถัดไป key=value: repo workflow run_id job pid log started started_iso slot heavy
#   ปล่อย = ล้าง owner (truncate) ก่อนปิด fd ⇒ ไม่ล้างของคนถัดไป · ไม่ rm เพราะ ghrunner สร้างไฟล์ใน /data/build ไม่ได้
#
# env (เทสชี้ไปของปลอมได้ทั้งหมด):
#   CI_BUILD_LOCK_DIR (/data/build) · CI_POOL_CGROUP (/sys/fs/cgroup/adhoc.slice) · CI_POOL_CONF (/srv/stacks/bin/pool.conf)
#   CI_PROC (/proc) · CI_BUILD_LOG (ไฟล์ log · ค่าเริ่ม $RUNNER_TEMP/ci-image-build-<run>-<job>.log)
#   CI_BUILD_STALL_MIN (10) · CI_BUILD_LOCK_WAIT_MIN (ว่าง = ไม่จำกัด) · CI_BUILD_HEAVY (1|true = บังคับ heavy · ลดไม่ได้)
#   CI_BUILD_POLL (5 วิ) · CI_BUILD_REPORT_SEC (60) · CI_BUILD_FAKE_CLOCK (เทสเท่านั้น: ไฟล์ epoch · nap บวกเวลาแทนการหลับ)
#   CI_BUILD_PEAK_DIR ($LOCK_DIR/ci-image-peak) · CI_BUILD_AUTO_HEAVY (1 · 0 = ไม่ตัดสิน heavy จาก peak แต่ยังวัด+บันทึก)
#   CI_BUILD_PROBE_SEC (2) · CI_BUILD_WARN_MIB (6656) · CI_BUILD_PROBE_ONCE (เทสเท่านั้น: 1 = วัด 1 ครั้งหลังคำสั่งจบ แทน loop ใน background)
#   IMAGE_REPO (ชื่อ image · ใช้เป็นส่วนหนึ่งของ key peak · ว่าง = "-")
#
# 6. heavy อัตโนมัติจาก peak ของ build ก่อนหน้า (ทุก image build ใช้เพดานหน่วยความจำร่วมกัน = $POOL/buildkit/memory.max
#    สอง build ที่ anon รวมเกินเพดาน = มีตัวถูก OOM-kill ⇒ ตัวที่รู้ว่าใหญ่ต้องรันเดี่ยว)
#    ก. ไฟล์ peak ต่อ image: $CI_BUILD_PEAK_DIR/<repo>__<image> (อักขระนอก [A-Za-z0-9._-] ⇒ _ · ".." ⇒ "__") 1 บรรทัด "peak_mib epoch run_id alone"
#    ข. ก่อนขอที่นั่ง (ถ้าอ่านเพดานเป็นตัวเลขได้ · ไม่งั้นปิดฟีเจอร์ทั้งหมดรอบนั้น = พฤติกรรมเดิม) · repo ยังไม่เป็น heavy และ CI_BUILD_AUTO_HEAVY≠0 ⇒
#       ไม่มีไฟล์ / เก่ากว่า 14 วัน / อ่านไม่ได้ ⇒ heavy · peak > เพดาน/2 ⇒ heavy · ไม่งั้นช่องปกติ (ลด heavy ที่มาจาก heavy_repos/CI_BUILD_HEAVY ไม่ได้)
#    ค. ระหว่างถือที่นั่ง: probe ใน background ทุก CI_BUILD_PROBE_SEC วิ รวม anon+shmem ของ $POOL/buildkit/*/memory.stat เก็บค่าสูงสุด
#       และดูว่ามี build อื่นถือช่องอีกช่องไหม (alone) · ตายตามสคริปต์นี้เสมอ · ไม่ถือ fd ของ lock
#    ง. คำสั่งจบ (ก่อนปล่อย): บันทึก peak (คำสั่งล้ม + oom_kill ของ $POOL/buildkit เพิ่ม ⇒ peak = เพดาน) · พิมพ์ "CI image-build stats: …" 1 บรรทัด
#       alone=1 และ peak > CI_BUILD_WARN_MIB ⇒ ::warning:: + GITHUB_STEP_SUMMARY + $CI_BUILD_PEAK_DIR/alerts.log
#    ทุกขั้นนี้ไม่เปลี่ยน exit code และไม่ทำให้ build ล้ม
# exit: ของคำสั่ง · 75 = ไม่ได้ที่นั่ง (ผู้ถือนิ่ง/ตาย · เกินเพดาน · เปิด lock ไม่ได้) · 64 = env ผิดรูป
set -euo pipefail

LOCK_DIR=${CI_BUILD_LOCK_DIR:-/data/build}
POOL=${CI_POOL_CGROUP:-/sys/fs/cgroup/adhoc.slice}
CONF=${CI_POOL_CONF:-/srv/stacks/bin/pool.conf}
PROC=${CI_PROC:-/proc}
POLL=${CI_BUILD_POLL:-5}
REPORT_SEC=${CI_BUILD_REPORT_SEC:-60}
STALL_MIN=${CI_BUILD_STALL_MIN:-10}
WAIT_MIN=${CI_BUILD_LOCK_WAIT_MIN:-}
SLOTS=(ci-image-build-0 ci-image-build-1)
HEAVY_LOCK=ci-heavy-0

say() { printf '%s\n' "$*"; }
err() { printf '::error::%s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*"; }

[ "${1:-}" = "--" ] && shift
[ $# -gt 0 ] || { err "ci-image-build-slot: ไม่มีคำสั่งให้รัน (ใช้: ci-image-build-slot.sh -- docker build …)"; exit 64; }
[[ $STALL_MIN =~ ^[1-9][0-9]*$ ]] || { err "CI_BUILD_STALL_MIN ต้องเป็นจำนวนเต็ม ≥ 1 (ได้ '$STALL_MIN')"; exit 64; }
[[ -z $WAIT_MIN || $WAIT_MIN =~ ^[0-9]+$ ]] || { err "CI_BUILD_LOCK_WAIT_MIN ต้องเป็นจำนวนเต็มนาที หรือว่าง (ได้ '$WAIT_MIN')"; exit 64; }
[[ $POLL =~ ^[1-9][0-9]*$ && $REPORT_SEC =~ ^[1-9][0-9]*$ ]] || { err "CI_BUILD_POLL/CI_BUILD_REPORT_SEC ต้องเป็นจำนวนเต็ม ≥ 1"; exit 64; }

# ── นาฬิกา (เทสใช้นาฬิกาปลอม: nap เลื่อนเวลาในไฟล์แล้วหลับจริงสั้น ๆ ให้ process อื่นในเทสขยับ) ──
now() { if [ -n "${CI_BUILD_FAKE_CLOCK:-}" ]; then cat "$CI_BUILD_FAKE_CLOCK"; else date +%s; fi; }
nap() {
  if [ -n "${CI_BUILD_FAKE_CLOCK:-}" ]; then
    local t; t=$(cat "$CI_BUILD_FAKE_CLOCK")
    printf '%s\n' "$((t + $1))" > "$CI_BUILD_FAKE_CLOCK.tmp.$$" && mv -f "$CI_BUILD_FAKE_CLOCK.tmp.$$" "$CI_BUILD_FAKE_CLOCK"
    sleep 0.05
  else
    sleep "$1"
  fi
}

# ── pool.conf: ข้อมูล allow-list ห้าม source · ใช้แค่ heavy_repos · บรรทัดผิดเมินทีละบรรทัด + เตือน ──
read_conf() {
  HEAVY_REPOS=uplift-figcraft
  [ -r "$CONF" ] || { say "ไม่พบ $CONF ⇒ heavy_repos=$HEAVY_REPOS (ค่าเริ่ม)"; return 0; }
  local line k v n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ $line =~ ^([a-z0-9_]+)=([^[:space:]]+)$ ]]; then k=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}; else k='?' v=""; fi
    case "$k" in
      heavy_repos)
        if [[ $v =~ ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$ ]]; then HEAVY_REPOS=$v
        else warn "pool.conf บรรทัด $n: heavy_repos ผิดรูป เมิน"; fi ;;
      pool_max | r1 | r2 | r3 | cpu_quota | agent_slice_max | r1_psi_pct | r1_anon_pct) ;; # ของตัวอื่น
      *) warn "pool.conf บรรทัด $n: ไม่รู้จักหรือผิดรูป เมิน" ;;
    esac
  done < "$CONF"
}

# ── owner file ───────────────────────────────────────────────────────────
oneline() { printf '%s' "$1" | tr '\n\r' '  '; }
REPO_FULL=${GITHUB_REPOSITORY:-unknown/unknown}
REPO=${REPO_FULL##*/}
RUN_ID=${GITHUB_RUN_ID:-0}
JOB=${GITHUB_JOB:-?}
LOG=${CI_BUILD_LOG:-${RUNNER_TEMP:-/tmp}/ci-image-build-$RUN_ID-$JOB-$$.log}
START=""
LABEL="ci $(oneline "$REPO_FULL") · $(oneline "${GITHUB_WORKFLOW:-?}") · run $RUN_ID · job $(oneline "$JOB")"

write_owner() { # $1 = ชื่อ lock ⇒ 0 เขียนได้ · 1 ไม่ได้ (lock ยังถืออยู่ ⇒ แค่เตือน)
  local f=$LOCK_DIR/$1.owner
  { printf '%s %s %s\n' "$$" "$START" "$LABEL"
    printf 'repo=%s\nworkflow=%s\nrun_id=%s\njob=%s\npid=%s\nlog=%s\nstarted=%s\nstarted_iso=%s\nslot=%s\nheavy=%s\n' \
      "$(oneline "$REPO_FULL")" "$(oneline "${GITHUB_WORKFLOW:-?}")" "$RUN_ID" "$(oneline "$JOB")" "$$" "$LOG" \
      "$START" "$(date -u -d "@$START" +%FT%TZ 2> /dev/null || echo "$START")" "$1" "$HEAVY"
  } 2> /dev/null > "$f" || { warn "เขียน $f ไม่ได้ (ถือ lock อยู่ แต่ผู้รอ/ci-status จะไม่เห็นชื่อ) · สร้างไว้ 0666: umask 000; : >> $f"; return 1; }
}
# อ่าน owner ⇒ O_PID O_LABEL O_LOG O_START (ว่างถ้าไม่มี) · parse เอง ไม่ source
read_owner() {
  local f=$LOCK_DIR/$1.owner line first=1 st
  O_PID="" O_LABEL="" O_LOG="" O_START="" O_LINE1=""
  [ -s "$f" ] && [ -r "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ $first = 1 ]; then
      first=0 O_LINE1=$line
      read -r O_PID st O_LABEL <<< "$line" || true
      [[ $O_PID =~ ^[0-9]+$ ]] || O_PID=""
      [[ $st =~ ^[0-9]+$ ]] && O_START=$st
      continue
    fi
    case "$line" in log=/*) O_LOG=${line#log=} ;; esac
  done < "$f" 2> /dev/null || true
}
log_size() { if [ -n "$1" ] && [ -r "$1" ]; then stat -c %s "$1" 2> /dev/null || echo '?'; else echo '?'; fi; }
# cpu ของ BuildKit ใน pool: usage_usec ของ $POOL/buildkit (รวมลูกที่จบไปแล้ว) + ผลรวมของลูกที่ยังอยู่
# ลูกหายกลางทางได้ ⇒ อ่านพลาด = ข้าม (ไม่ใช้ set -e ในส่วนนี้)
cpu_snapshot() {
  local d parent="-" sum=0 u
  u=$(awk '$1=="usage_usec"{print $2; exit}' "$POOL/buildkit/cpu.stat" 2> /dev/null || true)
  [ -n "$u" ] && parent=$u
  for d in "$POOL"/buildkit/*/; do
    [ -r "${d}cpu.stat" ] || continue
    u=$(awk '$1=="usage_usec"{print $2; exit}' "${d}cpu.stat" 2> /dev/null || true)
    [[ $u =~ ^[0-9]+$ ]] && sum=$((sum + u))
  done
  printf '%s:%s' "$parent" "$sum"
}

# ── lock ─────────────────────────────────────────────────────────────────
HELD=() HELD_FD=() OWNED=()
try_lock() { # $1 = ชื่อ ⇒ 0 ได้ · 1 ไม่ว่าง · 2 เปิด lock ไม่ได้
  local f=$LOCK_DIR/$1.lock fd
  [ -e "$f" ] || (umask 000 && : >> "$f") 2> /dev/null || true # ไฟล์ร่วม CI (ghrunner) กับ agent (anon) ⇒ 0666
  exec {fd}< "$f" 2> /dev/null || return 2
  if flock -n "$fd"; then
    HELD+=("$1") HELD_FD+=("$fd")
    if write_owner "$1"; then OWNED+=("$1"); fi
    return 0
  fi
  exec {fd}<&-
  return 1
}
release_all() { # ล้าง owner ก่อนปิด fd ⇒ ไม่ล้างของคนถัดไป
  local n fd
  for n in "${OWNED[@]}"; do : 2> /dev/null > "$LOCK_DIR/$n.owner" || true; done
  for fd in "${HELD_FD[@]}"; do exec {fd}<&-; done
  HELD=() HELD_FD=() OWNED=()
}
PROBE_PID="" PROBE_F=""
stop_probe() { # ฆ่า probe + เก็บไฟล์ชั่วคราว · เรียกซ้ำได้
  if [ -n "$PROBE_PID" ]; then
    kill "$PROBE_PID" 2> /dev/null || true
    wait "$PROBE_PID" 2> /dev/null || true
    PROBE_PID=""
  fi
}
cleanup() { stop_probe; if [ -n "$PROBE_F" ]; then rm -f "$PROBE_F" "$PROBE_F.tmp" 2> /dev/null || true; fi; release_all; }
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

describe() { # $@ = ชื่อ lock ⇒ บรรทัดละผู้ถือ
  local n t; t=$(now)
  for n in "$@"; do
    read_owner "$n"
    if [ -z "$O_LINE1" ]; then
      say "  $n: ถืออยู่ แต่ไม่มี owner file (ไม่รู้ผู้ถือ)"
    else
      say "  $n: ${O_LABEL:-?} · pid ${O_PID:-?}$([ -n "$O_PID" ] && [ ! -d "$PROC/$O_PID" ] && echo ' (ตายแล้ว)') · ถือมา $(((t - ${O_START:-$t}) / 60)) นาที · log ${O_LOG:-?} ($(log_size "$O_LOG") ไบต์)"
    fi
  done
}

T0=""
# acquire <คำอธิบาย> all|any <ชื่อ…> · all = ทีละตัวตามลำดับ (heavy) · any = ช่องไหนก็ได้
# ผู้ถือที่วัด "นิ่ง" = ผู้ถือของทุกชื่อที่ยังไม่ได้ · ตาย = ทุกชื่อที่ยังไม่ได้มีผู้ถือตาย 2 รอบติด
acquire() {
  local what=$1 mode=$2; shift 2
  local want=("$@") n rc t last_report last_prog sig prev_sig="" cpu prev_cpu dead all_dead pending=()
  local -A dead_seen=()
  last_prog=$(now) last_report=$last_prog prev_cpu=$(cpu_snapshot)
  while :; do
    pending=()
    for n in "${want[@]}"; do
      if [[ " ${HELD[*]} " == *" $n "* ]]; then continue; fi
      rc=0; try_lock "$n" || rc=$?
      case $rc in
        0) [ "$mode" = any ] && return 0; continue ;;
        2) err "เปิด $LOCK_DIR/$n.lock ไม่ได้ ⇒ ไม่ build (ห้ามรันโดยไม่ถือที่นั่ง) · แก้: (anon) umask 000; : >> $LOCK_DIR/$n.lock $LOCK_DIR/$n.owner"
           exit 75 ;;
      esac
      pending+=("$n")
    done
    [ ${#pending[@]} -eq 0 ] && return 0
    t=$(now)

    # ความเคลื่อนไหว: ผู้ถือเปลี่ยนตัว · log ของผู้ถือโต · cpu ของ BuildKit ใน pool เปลี่ยน
    sig="" all_dead=1
    for n in "${pending[@]}"; do
      read_owner "$n"
      sig+="$n|$O_LINE1|$(log_size "$O_LOG");"
      dead=0
      if [ -n "$O_PID" ] && [ ! -d "$PROC/$O_PID" ]; then dead=1; fi
      if [ $dead = 1 ]; then dead_seen[$n]=$((${dead_seen[$n]:-0} + 1)); else dead_seen[$n]=0; fi
      [ "${dead_seen[$n]}" -ge 2 ] || all_dead=0
    done
    cpu=$(cpu_snapshot)
    if [ "$sig" != "$prev_sig" ] || [ "$cpu" != "$prev_cpu" ]; then last_prog=$t; fi
    prev_sig=$sig prev_cpu=$cpu

    if [ $all_dead = 1 ]; then
      err "ผู้ถือ $what ตายแล้วแต่ lock ยังค้าง (process ลูกถือ fd ไว้?) หลังรอ $((t - T0)) วิ · ไม่ build · ผู้ถือ:"
      describe "${pending[@]}"; exit 75
    fi
    if [ $((t - last_prog)) -ge $((STALL_MIN * 60)) ]; then
      err "ผู้ถือ $what นิ่ง ${STALL_MIN} นาที (log ไม่โต · BuildKit ใน pool ไม่ใช้ cpu) หลังรอ $((t - T0)) วิ · ไม่ build · ผู้ถือ:"
      describe "${pending[@]}"; exit 75
    fi
    if [ -n "$WAIT_MIN" ] && [ "$WAIT_MIN" -gt 0 ] && [ $((t - T0)) -ge $((WAIT_MIN * 60)) ]; then
      err "รอ $what เกิน CI_BUILD_LOCK_WAIT_MIN=${WAIT_MIN} นาที หลังรอ $((t - T0)) วิ · ไม่ build · ผู้ถือ:"
      describe "${pending[@]}"; exit 75
    fi
    if [ $((t - last_report)) -ge "$REPORT_SEC" ]; then
      say "Still waiting for $what ($((t - T0)) s · นิ่งมา $((t - last_prog)) วิ จากเกณฑ์ $((STALL_MIN * 60))):"
      describe "${pending[@]}"
      last_report=$t
    fi
    nap "$POLL"
  done
}

# ── heavy อัตโนมัติจาก peak + probe (ดูหัวไฟล์ข้อ 6) ──────────────────────────
FEATURE=0 CAP_MIB=0 PEAK_DIR=${CI_BUILD_PEAK_DIR:-$LOCK_DIR/ci-image-peak}
AUTO_HEAVY=${CI_BUILD_AUTO_HEAVY:-1}
PROBE_SEC=${CI_BUILD_PROBE_SEC:-2}; [[ $PROBE_SEC =~ ^[1-9][0-9]*$ ]] || PROBE_SEC=2
WARN_MIB=${CI_BUILD_WARN_MIB:-6656}; [[ $WARN_MIB =~ ^[0-9]+$ ]] || WARN_MIB=6656
IMAGE=${IMAGE_REPO:-}; [ -n "$IMAGE" ] || IMAGE=-
sanitize_key() { # ⇒ KEY · ไม่มี / ไม่มี ".."
  local LC_ALL=C k=$1
  k=${k//[!A-Za-z0-9._-]/_}
  k=${k//../__}
  KEY=${k:0:200}
}
sanitize_key "${REPO}__${IMAGE}"
PEAK_FILE=$PEAK_DIR/$KEY

read_cap() { # ⇒ FEATURE=1 + CAP_MIB ถ้าเพดานเป็นตัวเลข
  local f=$POOL/buildkit/memory.max v=""
  if [ ! -r "$f" ]; then say "peak-aware heavy: off (อ่าน $f ไม่ได้)"; return 0; fi
  read -r v 2> /dev/null < "$f" || true
  if [[ ! $v =~ ^[0-9]+$ ]]; then say "peak-aware heavy: off (เพดาน memory.max = '${v:-ว่าง}' ไม่ใช่ตัวเลข)"; return 0; fi
  CAP_MIB=$((v / 1048576)) FEATURE=1
}

decide_heavy() { # ใช้ HEAVY/CAP_MIB/PEAK_FILE · อาจตั้ง HEAVY=1 · พิมพ์เหตุผลทุกกรณี
  local reason mt age p e r a x line="" n=0
  if [ "$HEAVY" = 1 ]; then say "peak-aware heavy: heavy อยู่แล้ว (heavy_repos/CI_BUILD_HEAVY) ⇒ คงไว้"; return 0; fi
  if [ "$AUTO_HEAVY" = 0 ]; then say "peak-aware heavy: ปิดโดย CI_BUILD_AUTO_HEAVY=0 ⇒ ช่องปกติ (ยังวัดและบันทึก peak)"; return 0; fi
  if [ ! -f "$PEAK_FILE" ]; then
    HEAVY=1; say "peak-aware heavy: heavy · first build of this image (no peak recorded)"; return 0
  fi
  mt=$(stat -c %Y "$PEAK_FILE" 2> /dev/null || true)
  if [[ ! $mt =~ ^[0-9]+$ ]]; then
    warn "peak record $PEAK_FILE อ่าน mtime ไม่ได้ ⇒ ถือว่าไม่ถูกต้อง"; HEAVY=1; say "peak-aware heavy: heavy · peak record invalid"; return 0
  fi
  age=$(($(now) - mt))
  if [ "$age" -gt $((14 * 86400)) ]; then
    HEAVY=1; say "peak-aware heavy: heavy · peak record older than 14 days"; return 0
  fi
  read -r line 2> /dev/null < "$PEAK_FILE" || true
  read -r p e r a x <<< "$line" || true
  if [ -z "$p" ] || [ -z "$e" ] || [ -z "$r" ] || [ -z "$a" ] || [ -n "$x" ] || [[ ! $p =~ ^[0-9]+$ ]] || [ "$p" -gt $((2 * CAP_MIB)) ]; then
    warn "peak record $PEAK_FILE ไม่ถูกต้อง ('$line') ⇒ ถือว่าไม่มี"
    HEAVY=1; say "peak-aware heavy: heavy · peak record invalid"; return 0
  fi
  if [ "$p" -gt $((CAP_MIB / 2)) ]; then
    HEAVY=1; say "peak-aware heavy: heavy · last peak $p MiB > half of cap $CAP_MIB MiB"
  else
    say "peak-aware heavy: last peak $p MiB <= half of cap $CAP_MIB MiB => normal slot"
  fi
  return 0
}

OOM_VAL=0
read_oom() { # ⇒ OOM_VAL (oom_kill ของ $POOL/buildkit · อ่านไม่ได้ = 0)
  local k v f=$POOL/buildkit/memory.events
  OOM_VAL=0
  [ -r "$f" ] || return 0
  while read -r k v; do
    if [ "$k" = oom_kill ] && [[ $v =~ ^[0-9]+$ ]]; then OOM_VAL=$v; fi
  done 2> /dev/null < "$f" || true
  return 0
}

P_PEAK=0 P_OTHER=0 P_BOTH=0 P_OTHER_SLOT=""
probe_sample() { # 1 ตัวอย่าง ⇒ อัปเดต P_PEAK (ไบต์สูงสุด) · P_OTHER (เคยเห็น build อื่นถืออีกช่อง)
  local d a s k v sum=0
  for d in "$POOL"/buildkit/*/; do
    [ -r "${d}memory.stat" ] || continue
    a=0 s=0
    while read -r k v; do
      case $k in anon) a=$v ;; shmem) s=$v ;; esac
    done 2> /dev/null < "${d}memory.stat" || true
    [[ $a =~ ^[0-9]+$ ]] || a=0
    [[ $s =~ ^[0-9]+$ ]] || s=0
    sum=$((sum + a + s))
  done
  if [ "$sum" -gt "$P_PEAK" ]; then P_PEAK=$sum; fi
  if [ $P_BOTH = 0 ] && [ $P_OTHER = 0 ] && [ -n "$P_OTHER_SLOT" ]; then
    read_owner "$P_OTHER_SLOT"
    if [ -n "$O_PID" ] && [ -d "$PROC/$O_PID" ]; then P_OTHER=1; fi
  fi
  return 0
}

start_probe() { # background child · ปิด fd ของ lock · ตายเมื่อ stop_probe หรือเมื่อสคริปต์แม่ตาย
  local n parent=$$
  P_BOTH=0 P_OTHER_SLOT=""
  [[ " ${HELD[*]} " == *" ${SLOTS[0]} "* && " ${HELD[*]} " == *" ${SLOTS[1]} "* ]] && P_BOTH=1
  if [ $P_BOTH = 0 ]; then
    for n in "${SLOTS[@]}"; do [[ " ${HELD[*]} " == *" $n "* ]] || P_OTHER_SLOT=$n; done
  fi
  [ "${CI_BUILD_PROBE_ONCE:-}" = 1 ] && return 0
  PROBE_F=$(mktemp "$(dirname "$LOG")/.ci-image-probe.XXXXXX" 2> /dev/null || mktemp 2> /dev/null || true)
  [ -n "$PROBE_F" ] || { warn "สร้างไฟล์ probe ไม่ได้ ⇒ ไม่วัด peak รอบนี้"; return 0; }
  (
    for fd in "${HELD_FD[@]}"; do exec {fd}<&-; done
    sp=""
    trap '[ -n "$sp" ] && kill "$sp" 2> /dev/null; exit 0' TERM
    while kill -0 "$parent" 2> /dev/null; do
      probe_sample
      printf '%s %s\n' "$P_PEAK" "$P_OTHER" > "$PROBE_F.tmp" 2> /dev/null && mv -f "$PROBE_F.tmp" "$PROBE_F" 2> /dev/null
      sleep "$PROBE_SEC" & sp=$!
      wait "$sp" || true
    done
  ) > /dev/null 2>&1 < /dev/null &
  PROBE_PID=$!
}

collect_probe() { # หลังคำสั่งจบ ⇒ P_PEAK / P_OTHER สุดท้าย
  stop_probe
  if [ "${CI_BUILD_PROBE_ONCE:-}" = 1 ]; then probe_sample; return 0; fi
  local pk ot
  if [ -n "$PROBE_F" ] && [ -r "$PROBE_F" ]; then
    read -r pk ot 2> /dev/null < "$PROBE_F" || true
    [[ $pk =~ ^[0-9]+$ ]] && P_PEAK=$pk
    [[ $ot =~ ^[01]$ ]] && P_OTHER=$ot
  fi
  rm -f "$PROBE_F" "$PROBE_F.tmp" 2> /dev/null || true
  PROBE_F=""
  return 0
}

write_peak() { # $1 peak_mib $2 alone ⇒ เขียนอะตอมมิก (temp ใน dir เดียวกัน แล้ว mv -f) · พลาด = เตือน
  local tmp=$PEAK_DIR/.$KEY.tmp.$$
  if (umask 000; mkdir -p "$PEAK_DIR" && chmod 0777 "$PEAK_DIR" 2> /dev/null; printf '%s %s %s %s\n' "$1" "$(now)" "$RUN_ID" "$2" > "$tmp" && mv -f "$tmp" "$PEAK_FILE") 2> /dev/null; then return 0; fi
  rm -f "$tmp" 2> /dev/null || true
  warn "เขียน peak record $PEAK_FILE ไม่ได้ (build ไม่ได้รับผลกระทบ · build ถัดไปของ image นี้จะถูกมองว่าไม่มีข้อมูล)"
  return 0
}

finish_stats() { # $1 = rc ของคำสั่ง · ห้ามทำให้ build ล้ม (เรียกด้วย || true)
  local rc=$1 peak_mib alone hold_s msg
  collect_probe
  read_oom
  peak_mib=$((P_PEAK / 1048576))
  if [ $P_BOTH = 1 ]; then alone=1; elif [ $P_OTHER = 1 ]; then alone=0; else alone=1; fi
  if [ "$rc" -ne 0 ] && [ "$OOM_VAL" -gt "$OOM0" ]; then
    peak_mib=$CAP_MIB
    say "build hit the build memory cap (oom_kill $OOM0 -> $OOM_VAL) ⇒ record peak = cap $CAP_MIB MiB"
  fi
  hold_s=$(($(now) - SLOT_T))
  write_peak "$peak_mib" "$alone"
  say "CI image-build stats: wait_s=$WAITED hold_s=$hold_s peak_mib=$peak_mib cap_mib=$CAP_MIB alone=$alone heavy=$HEAVY rc=$rc"
  if [ "$alone" = 1 ] && [ "$peak_mib" -gt "$WARN_MIB" ]; then
    msg="image build $REPO/$IMAGE peaked at $peak_mib MiB of a $CAP_MIB MiB cap and will be OOM-killed (exit 137) if it grows — reduce heap / split stages"
    warn "$msg"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "- $msg" >> "$GITHUB_STEP_SUMMARY" 2> /dev/null || true; fi
    printf '%s %s %s %s %s %s\n' "$(now)" "$REPO" "${IMAGE//[[:space:]]/_}" "$peak_mib" "$CAP_MIB" "$RUN_ID" >> "$PEAK_DIR/alerts.log" 2> /dev/null || true
  fi
  return 0
}

# ── main ─────────────────────────────────────────────────────────────────
read_conf
HEAVY=0
case ",$HEAVY_REPOS," in *",$REPO,"*) HEAVY=1 ;; esac
case "${CI_BUILD_HEAVY:-}" in 1 | true) HEAVY=1 ;; esac
read_cap
if [ $FEATURE = 1 ]; then decide_heavy || true; fi

T0=$(now) START=$T0
if [ $HEAVY = 1 ]; then
  say "Waiting for the CI image-build slot on this host (heavy: $REPO ⇒ $HEAVY_LOCK แล้วทั้ง ${SLOTS[*]})…"
  acquire "$HEAVY_LOCK (heavy)" all "$HEAVY_LOCK"
  START=$(now); write_owner "$HEAVY_LOCK" > /dev/null || true # เวลาเริ่มของ heavy = ตอนได้ heavy
  acquire "ทั้งสองช่อง image build (heavy)" all "${SLOTS[@]}"
else
  say "Waiting for the CI image-build slot on this host (${SLOTS[*]} · ช่องไหนก็ได้)…"
  acquire "ช่อง image build" any "${SLOTS[@]}"
fi
WAITED=$(($(now) - T0))
START=$(now) SLOT_T=$START
for n in "${OWNED[@]}"; do write_owner "$n" > /dev/null || true; done # เวลาเริ่ม = ตอนได้ครบ
say "Got the CI image-build slot after ${WAITED} s (${HELD[*]}) · log $LOG"
if [ -n "${GITHUB_ENV:-}" ]; then echo "CI_IMAGE_BUILD_WAIT_S=$WAITED" >> "$GITHUB_ENV" 2> /dev/null || true; fi

: >> "$LOG" 2> /dev/null || warn "เขียน $LOG ไม่ได้ ⇒ ผู้รอวัดได้แค่ cpu"
chmod 0644 "$LOG" 2> /dev/null || true
OOM0=0
if [ $FEATURE = 1 ]; then read_oom || true; OOM0=$OOM_VAL; start_probe || true; fi
# คำสั่งลูกไม่ได้ fd ของ lock ⇒ lock ตายตาม pid นี้ (pid ใน owner file) ไม่ค้างกับ process ลูก
set +e
(
  for fd in "${HELD_FD[@]}"; do exec {fd}<&-; done
  "$@" 2>&1 | tee -a "$LOG"
  exit "${PIPESTATUS[0]}"
)
rc=$?
if [ $FEATURE = 1 ]; then finish_stats "$rc" || true; fi
set -e
release_all
exit "$rc"
