#!/bin/bash
# db/backup.sh —— Evoltrya OS 的备份,【分两部分取】(MES-9b,2026-10-19,Tim 的裁定 1)。迁移之前跑它,等它自己打出的 BACKUP_EXIT=。
#
# ═══════════════════════════════════════════════════════════════════════════
# 【为什么分两部分】2026-10-19 的两次整库备份(21:28、21:53)都在开跑约 25 分钟后、在 `COPY public.change_log` 那一段被服务端断开
#   (`SSL SYSCALL error: EOF detected`),每次都在线上留下一个 idle-in-transaction 的后端攥着 638 把锁(docs/handbacks/MES-9b.md)。
#   change_log 是库里最大、而且只会长的那一张(64,239 行 / 48 MB),整库一次取完要一条连接撑二十几分钟 —— 而那正是被断开的那段时长。
#   所以:**没有任何一条连接需要撑过几分钟。**
#     ① 一次 pg_dump,取【除了 public.change_log 的数据以外】的一切(--exclude-table-data;表结构照取);
#     ② change_log 的数据按 seq 切成连续的小段,每段一条 \copy(实测 5,000 个 seq ≈ 4,000 行 ≈ 1.8 MB ≈ 26 秒,远低于 3 分钟的目标),
#        每段写成主 dump 旁边一个编号的文件;一段失败只重试那一段一次,再失败就停(退 1)。
#   ★ 开跑那一刻先读 change_log 的 count(*) · min(seq) · max(seq) 并记下来;各段只取 seq ≤ 那个 max 的行。
#     验证:主 dump 自己的退出码 0;每一段自己的退出码 0;**各段文件的行数加起来 = 那个 count,首尾 seq = 那个 min 与 max** —— 三样都要对。
#     (change_log 只追加:开跑之后新写的行 seq 更大,不在这一份里,这是一份【截至开跑那一刻】的变更记录,照直记在清单里。)
#
# 【沿用的四道检查】(原 ~/evoltrya-backups/backup.sh 的 BK-FIX / CHECK-1,一条没减)
#   隔离名优先(<名>.INCOMPLETE,验证通过才改成好名字,mv 原子)· 体积下限 100 KB · `pg_restore --list` 读得出 · TOC 条目数比上一份少不超过 10%。
#   change_log 的段也走隔离名:整组验证通过之前,目录里没有一个叫 evoltrya-backup-*.change_log.*.copy 的文件。
#
# 【还原】(docs/fresh-install-checklist.md「从备份还原」那一节,逐字同一份):
#   1. pg_restore -d <空库> evoltrya-backup-<时刻>.dump —— 建全部结构与数据,change_log 是一张【空表】(它的序列值是主 dump 那一刻的);
#   2. 按编号顺序把每一段装回去:  for f in evoltrya-backup-<时刻>.change_log.*.copy; do psql -d <库> -c "\copy public.change_log FROM '$f'"; done
#      (text 格式,列顺序就是表的列顺序;change_log 只拒改与删,不拒插入);
#   3. 对一遍清单:SELECT count(*), min(seq), max(seq) FROM public.change_log 必须等于 <时刻>.change_log.manifest 里的那三个数;
#   4. SELECT setval(pg_get_serial_sequence('public.change_log', 'seq'), (SELECT max(seq) FROM public.change_log)) —— 序列不能落在已有的 seq 之下
#      (seq 是 GENERATED ALWAYS 的 identity;COPY FROM 照样写得进给定的值)。
#   以上四步由 db/scripts/2026-10-19-backup-injections.sh 在一个本地库上真的跑过(整组 → 还原 → 三个数与每一行的 md5 都对上)。
#
# 失败一律 exit 1,并把隔离名下的残骸留给人看(或删掉主 dump 的残骸,与原脚本相同)。判词只认最后一行 BACKUP_EXIT=。
# 用法:db/run_detached.sh --log <log> --label 备份 --token BACKUP --timeout 2700 -- db/backup.sh
# ═══════════════════════════════════════════════════════════════════════════
set -u

HOST="${BACKUP_HOST:-aws-1-ap-southeast-1.pooler.supabase.com}"
PORT="${BACKUP_PORT:-5432}"
USER="${BACKUP_USER:-postgres.wvywpohbwkiinmipmuku}"
DB="${BACKUP_DB:-postgres}"
# 故障注入(只给 db/scripts/2026-10-19-backup-injections.sh 用):chunk1-fail-once · chunk1-fail-twice · drop-row
FAULT="${BACKUP_FAULT:-}"
DSN="host=${HOST} port=${PORT} user=${USER} dbname=${DB}"
DATE=$(date +%Y-%m-%d-%H%M)
OUTDIR="${BACKUP_DIR:-$HOME/evoltrya-backups}"
CHUNK_SEQ="${CHUNK_SEQ:-5000}"     # 每段的 seq 宽度 —— 实测 5,000 个 seq ≈ 26 秒(2026-10-19 22:59)

FINALFILE="${OUTDIR}/evoltrya-backup-${DATE}.dump"
OUTFILE="${FINALFILE}.INCOMPLETE"
CLBASE="${OUTDIR}/evoltrya-backup-${DATE}.change_log"
MANIFEST="${CLBASE}.manifest"
MIN_BYTES="${BACKUP_MIN_BYTES:-100000}"   # 只有注入脚本把它调低(本地的小库)
MAX_DROP_PCT=10

fail() { echo "❌ 备份失败:$*"; exit 1; }

# ── 上一份【成功】备份的 TOC 条目数(动手之前先量)──
PREV_DUMP=$(ls -t "${OUTDIR}"/evoltrya-backup-*.dump 2>/dev/null | head -1)
PREV_ENTRIES=""
if [ -n "${PREV_DUMP}" ]; then
    PREV_ENTRIES=$(pg_restore --list "${PREV_DUMP}" 2>/dev/null | grep -c '^[0-9]')
    echo "参照:上一份备份 $(basename "${PREV_DUMP}"),${PREV_ENTRIES} 条 TOC"
else
    echo "参照:目录里没有更早的备份 —— 条目数这一条【比不了】,本次跳过它(不是通过)"
fi

# ── 开跑那一刻:change_log 的行数与首尾 seq(记下来,最后拿来对)──
START=$(psql "${DSN}" -X -At -F'|' -c "SELECT count(*), min(seq), max(seq), to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') FROM public.change_log") \
    || fail "读不出 change_log 的 count/min/max"
CL_COUNT=$(echo "${START}" | cut -d'|' -f1); CL_MIN=$(echo "${START}" | cut -d'|' -f2)
CL_MAX=$(echo "${START}" | cut -d'|' -f3); CL_AT=$(echo "${START}" | cut -d'|' -f4)
[ -n "${CL_COUNT}" ] && [ -n "${CL_MIN}" ] && [ -n "${CL_MAX}" ] || fail "change_log 的读数是空的:${START}"
echo "开跑:change_log count=${CL_COUNT} min(seq)=${CL_MIN} max(seq)=${CL_MAX}(读于 ${CL_AT} CST)"

# ── ① 主 dump:除了 change_log 的数据以外的一切 ──
echo "① 主 dump(不含 public.change_log 的数据)→ $(basename "${OUTFILE}")"
T0=$(date +%s)
pg_dump -h "${HOST}" -p "${PORT}" -U "${USER}" -d "${DB}" -F c --exclude-table-data=public.change_log -f "${OUTFILE}"
DUMP_STATUS=$?
echo "   MAIN_DUMP_EXIT=${DUMP_STATUS}($(( $(date +%s) - T0 )) 秒)"
if [ ${DUMP_STATUS} -ne 0 ]; then
    rm -f "${OUTFILE}"
    fail "pg_dump 退出码 ${DUMP_STATUS}(已删除未完成的主 dump)"
fi
SIZE=$(stat -f%z "${OUTFILE}" 2>/dev/null || stat -c%s "${OUTFILE}" 2>/dev/null || echo 0)
[ "${SIZE}" -ge "${MIN_BYTES}" ] || fail "主 dump 只有 ${SIZE} 字节,低于下限 ${MIN_BYTES}(留在隔离名下)"
pg_restore --list "${OUTFILE}" > /dev/null 2>&1 || fail "pg_restore 读不出主 dump(头部损坏;留在隔离名下)"
ENTRIES=$(pg_restore --list "${OUTFILE}" 2>/dev/null | grep -c '^[0-9]')
[ "${ENTRIES}" -gt 0 ] || fail "TOC 里 0 条条目"
if [ -n "${PREV_ENTRIES}" ] && [ "${PREV_ENTRIES}" -gt 0 ]; then
    MIN_ENTRIES=$(( PREV_ENTRIES * (100 - MAX_DROP_PCT) / 100 ))
    [ "${ENTRIES}" -ge "${MIN_ENTRIES}" ] || fail "TOC 只有 ${ENTRIES} 条,上一份 ${PREV_ENTRIES} 条(下限 ${MIN_ENTRIES})"
    echo "   TOC ${ENTRIES} 条(上一份 ${PREV_ENTRIES} 条,下限 ${MIN_ENTRIES})✓"
else
    echo "   TOC ${ENTRIES} 条(没有参照物,这一条比不了)"
fi
pg_restore --list "${OUTFILE}" | grep -q "TABLE DATA public change_log " && fail "主 dump 里竟然带着 change_log 的数据(--exclude-table-data 没生效)"
pg_restore --list "${OUTFILE}" | grep -q "TABLE public change_log " || fail "主 dump 里没有 change_log 的表结构"

# ── ② change_log 的数据,按 seq 连续切段,每段一条短连接 ──
echo "② change_log 按 seq 切段,每段 ${CHUNK_SEQ} 个 seq"
N=0; TOTAL=0; FIRST_SEQ=""; LAST_SEQ=""
: > "${MANIFEST}.INCOMPLETE"
LO=${CL_MIN}
while [ "${LO}" -le "${CL_MAX}" ]; do
    HI=$(( LO + CHUNK_SEQ - 1 )); [ "${HI}" -gt "${CL_MAX}" ] && HI=${CL_MAX}
    F=$(printf "%s.%03d.copy" "${CLBASE}" "${N}")
    TRY=1
    while :; do
        T1=$(date +%s)
        psql "${DSN}" -X -q -v ON_ERROR_STOP=1 -c "\\copy (SELECT * FROM public.change_log WHERE seq BETWEEN ${LO} AND ${HI} ORDER BY seq) TO '${F}.INCOMPLETE'"
        RC=$?
        if [ "${N}" -eq 1 ] && { [ "${FAULT}" = "chunk1-fail-twice" ] || { [ "${FAULT}" = "chunk1-fail-once" ] && [ ${TRY} -eq 1 ]; }; }; then RC=99; fi
        echo "   CHUNK_EXIT=${RC} chunk=$(printf %03d "${N}") seq ${LO}..${HI} try ${TRY} ($(( $(date +%s) - T1 )) 秒)"
        [ ${RC} -eq 0 ] && break
        rm -f "${F}.INCOMPLETE"
        [ ${TRY} -ge 2 ] && fail "第 $(printf %03d "${N}") 段(seq ${LO}..${HI})重试一次仍失败 —— 停下(裁定 1)"
        TRY=2
    done
    if [ "${N}" -eq 0 ] && [ "${FAULT}" = "drop-row" ]; then sed -i '' -e '2d' "${F}.INCOMPLETE"; fi
    ROWS=$(wc -l < "${F}.INCOMPLETE" | tr -d ' ')
    if [ "${ROWS}" -gt 0 ]; then
        S1=$(head -1 "${F}.INCOMPLETE" | cut -f1); S2=$(tail -1 "${F}.INCOMPLETE" | cut -f1)
        [ -z "${FIRST_SEQ}" ] && FIRST_SEQ=${S1}
        LAST_SEQ=${S2}
    fi
    TOTAL=$(( TOTAL + ROWS ))
    echo "$(printf %03d "${N}")|seq ${LO}..${HI}|rows ${ROWS}|exit ${RC}|tries ${TRY}" >> "${MANIFEST}.INCOMPLETE"
    N=$(( N + 1 )); LO=$(( HI + 1 ))
done

# ── 三样都要对 ──
echo "   核对:各段行数合计 ${TOTAL} vs count ${CL_COUNT} · 首 seq ${FIRST_SEQ:-无} vs min ${CL_MIN} · 末 seq ${LAST_SEQ:-无} vs max ${CL_MAX}"
[ "${TOTAL}" = "${CL_COUNT}" ] || fail "各段行数合计 ${TOTAL} ≠ 开跑时的 count ${CL_COUNT}(段文件留在隔离名下)"
[ "${FIRST_SEQ}" = "${CL_MIN}" ] || fail "首段第一行 seq ${FIRST_SEQ} ≠ 开跑时的 min ${CL_MIN}"
[ "${LAST_SEQ}" = "${CL_MAX}" ] || fail "末段最后一行 seq ${LAST_SEQ} ≠ 开跑时的 max ${CL_MAX}"
{
    echo "# change_log 截至 ${CL_AT} CST:count=${CL_COUNT} min(seq)=${CL_MIN} max(seq)=${CL_MAX};${N} 段,合计 ${TOTAL} 行;主 dump $(basename "${FINALFILE}")"
    echo "# 还原:见 db/backup.sh 抬头「还原」与 docs/fresh-install-checklist.md"
    cat "${MANIFEST}.INCOMPLETE"
} > "${MANIFEST}.tmp" && rm -f "${MANIFEST}.INCOMPLETE"

# ── 全过了,现在【才】给它们好名字(主 dump 最后改,于是"叫 evoltrya-backup-*.dump" = 整组验证过)──
for i in $(seq 0 $(( N - 1 ))); do
    F=$(printf "%s.%03d.copy" "${CLBASE}" "${i}")
    mv "${F}.INCOMPLETE" "${F}" || fail "改名失败:$(basename "${F}")"
done
mv "${MANIFEST}.tmp" "${MANIFEST}" || fail "改名失败:清单"
mv "${OUTFILE}" "${FINALFILE}" || fail "改名失败:主 dump"

echo "✅ 备份成功:$(basename "${FINALFILE}") + ${N} 段 change_log($(basename "${MANIFEST}"))"
ls -lh "${FINALFILE}"
# 只保留最近 14 份(主 dump 连同它的段与清单一起删)
for old in $(ls -t "${OUTDIR}"/evoltrya-backup-*.dump 2>/dev/null | tail -n +15); do
    rm -f -- "${old}" "${old%.dump}".change_log.*
done
echo "(已保留最近 14 份备份)"
exit 0
