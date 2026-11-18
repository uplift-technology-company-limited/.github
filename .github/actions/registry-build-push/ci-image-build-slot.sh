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
trap release_all EXIT
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

# ── main ─────────────────────────────────────────────────────────────────
read_conf
HEAVY=0
case ",$HEAVY_REPOS," in *",$REPO,"*) HEAVY=1 ;; esac
case "${CI_BUILD_HEAVY:-}" in 1 | true) HEAVY=1 ;; esac

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
START=$(now)
for n in "${OWNED[@]}"; do write_owner "$n" > /dev/null || true; done # เวลาเริ่ม = ตอนได้ครบ
say "Got the CI image-build slot after ${WAITED} s (${HELD[*]}) · log $LOG"
if [ -n "${GITHUB_ENV:-}" ]; then echo "CI_IMAGE_BUILD_WAIT_S=$WAITED" >> "$GITHUB_ENV" 2> /dev/null || true; fi

: >> "$LOG" 2> /dev/null || warn "เขียน $LOG ไม่ได้ ⇒ ผู้รอวัดได้แค่ cpu"
chmod 0644 "$LOG" 2> /dev/null || true
# คำสั่งลูกไม่ได้ fd ของ lock ⇒ lock ตายตาม pid นี้ (pid ใน owner file) ไม่ค้างกับ process ลูก
set +e
(
  for fd in "${HELD_FD[@]}"; do exec {fd}<&-; done
  "$@" 2>&1 | tee -a "$LOG"
  exit "${PIPESTATUS[0]}"
)
rc=$?
set -e
release_all
exit "$rc"
