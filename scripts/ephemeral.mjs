// scripts/ephemeral.mjs —— 一次性账号/授权的【清理计划】,写在造出它之前
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么需要这一支 —— LEAK-1(2026-09-06)】
//
// 七支脚本会造一次性账号或授权。它们各自挂了一个信号处理器,而 LEAK-1 实测:
//   · 三支【一个都没挂】(probe-button-tiers / render-pdf-samples / smoke-routes)
//   · 四支挂了,写法各不相同(有的收 SIGHUP/SIGPIPE,有的不收)
// 七份手写的清理,漂成了"三缺四异"。所以这里收成【一份】。
//
// ★★【真正的机制,实测出来的,不是"异步处理器跑不完"那么笼统】★★
//   survey-phone.mjs 在模块层挂 `SIGTERM → await cleanup()`(先注册),
//   main() 里再调 liveLock.acquireOrExit(),而它挂的是
//   `SIGTERM → { release(); process.exit(130) }` —— **同步的 process.exit**。
//   Node 按注册顺序调用监听器:清理那个先跑,它在第一个 await 上让出;
//   于是第二个监听器立刻 `process.exit(130)`,**进程当场消失,四次 REST 一次没跑。**
//   实测:SIGTERM 之后约 3 秒进程没了,线上留下 ZZ-SMOKE-SURVEY-1/2、
//   一个【活着的】survey-*@test.local admin,以及一份评估。
//   ——所以这不是"不保证",是【一个确定的竞争】,而它每一次都是同一个赢家。
//
// 【三层,一层比一层弱,但没有一层依赖进程活到最后】
//   ① 清理计划【先于】它要清的东西落盘(writeFileSync,同步)。
//      崩在"写完计划、还没造出行"之间,留下的是一条【删不到东西】的计划 —— 无害。
//      反过来(先造行、后写计划)崩在中间,留下的就是一条谁也不知道的授权。
//   ② 正常退出与可捕获的信号:跑完计划,删掉计划文件。
//   ③ SIGKILL / 断电 / 拔电源:**②跑不到,而①还在盘上。**
//      下一支脚本开跑时(或手工 `node scripts/reap-ephemeral.mjs`)照计划补删。
//
// 【SIGKILL 之后【当场】还剩什么 —— 照直说】
//   剩下的是:线上那些行 + 一份盘上的计划。它们【不会】自己消失,
//   要等下一次开跑或手工收割。所以 SIGKILL 之后到下一次开跑之间,
//   那个一次性 admin 账号是【活着的】—— 这是本设计【没有】消除的窗口,
//   不要读成"SIGKILL 也干净"。能消除它的只有数据库侧的过期机制,那要改表结构。
//
// 【还有一层与盘无关的】造授权时把 granted_by 写成【被授权人自己】。
//   真授权的 granted_by 是【另一个】管理员或 NULL;自授 = 一次性运行造的。
//   user_roles.granted_by 是可空 uuid 且【没有外键】(db/tables/user_roles.sql:32),
//   所以这一层不需要任何 DDL。计划文件丢了,这个标记还在行里。
//   ★ 它只对【今以后】造的行成立 —— 存量的 28 条 granted_by 全是 NULL,
//     认不到人,而【猜一个归属比没有归属更坏】,所以存量就照实说不知道。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, unlinkSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
export const PLAN_DIR = join(ROOT, '.ephemeral')

const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]

// ════════════════════════════════════════════════════════════════════════════
// ★ CLAIM-GST-1(2026-09-24,Tim Q8):收尾【有界】—— 每一次网络往返有自己的上限,整个收尾阶段也有 ★
//
// 【为什么】AP-RECON-1 Batch B 的冒烟:路由走查 253 ok / 0 失败,总结行打完之后进程停在
//   exitAfterCleanup 的按名兜底清扫(beforeFinish → sweepScratch)里一次【没有上限】的 fetch 上,
//   一直挂到 run_detached 在 2,400s 把它 SIGTERM 掉(SMOKE_EXIT=124)。日志里 `SMOKE_EXIT=124`
//   排在「✗ 收尾清扫抛出:fetch failed」【之前】—— 先挂住,后报错,报错是被杀的那一下带出来的。
//   而那一记 SIGTERM 救不了它:exitAfterCleanup 是重入安全的,第二次调用拿到的是同一个 promise,
//   它照旧等着那次挂住的往返。
//
// 【现在】三层:
//   ① 每一次收尾往返带 AbortSignal.timeout(15s)(del / req,以及调用方经 cleanupSignal() 拿的);
//   ② 整个收尾阶段(runPlan → beforeFinish)一个 120s 的截止时刻 —— 到点就 abort 掉还在飞的往返、
//      不再等;第二个信号改变不了它(重入拿到的仍是同一个 promise,而那个 promise 自己会到点);
//   ③ 收尾没完成 → 退【6】(EXIT_CLEANUP_INCOMPLETE),并【逐条点名】没删掉的东西:
//      计划里没确认删掉的每一步(ctx + 路径)、以及没跑完的按名兜底清扫。计划文件留在盘上,
//      下一次开跑或 `npm run reap:ephemeral` 照它补删。6 压过 1(路由失败)与信号码,两者都打进日志。
//   为什么是 6:冒烟用 0 / 1 / 2 与信号码(129–143),run_detached 用 124 —— 6 在这支脚本里没有别的意思。
// ════════════════════════════════════════════════════════════════════════════
export const CLEANUP_CALL_TIMEOUT_MS = 15_000
// 截止时刻默认 120s。EPHEMERAL_CLEANUP_DEADLINE_MS 只为【故障注入的证明】开 —— 让截止那一支
// 在注入的那一跑里真的被走到(三步 × 15s 超过 30s);平时不设。写错的值响亮退出,不当成默认。
export const CLEANUP_PHASE_DEADLINE_MS = (() => {
    const v = process.env.EPHEMERAL_CLEANUP_DEADLINE_MS
    if (v === undefined || v === '') return 120_000
    if (!/^[1-9][0-9]*$/.test(v)) { console.error(`✗ EPHEMERAL_CLEANUP_DEADLINE_MS=${v}:不是正整数毫秒`); process.exit(2) }
    return Number(v)
})()
export const EXIT_CLEANUP_INCOMPLETE = 6
const phaseAbort = new AbortController()
let inCleanupPhase = false
/** 收尾从这一刻开始:之后调用方的往返经 cleanupSignal() 拿上限。 */
export function beginCleanupPhase() { inCleanupPhase = true }
export function isCleanupPhase() { return inCleanupPhase }
/** 一次收尾往返的信号:15s 自己的上限,或整个收尾阶段到点 —— 哪个先到算哪个。 */
export function cleanupSignal() {
    return AbortSignal.any([AbortSignal.timeout(CLEANUP_CALL_TIMEOUT_MS), phaseAbort.signal])
}

// 【故障注入:收尾阶段的网络】只给证明用(冒烟的 SMOKE_FORCE_FAIL_AT=cleanup-hang / cleanup-refused)。
//   hang    —— 发往库的往返永远不回,只认 abort(复现 Batch B 那次挂住的形状);
//   refused —— 立刻抛 TypeError('fetch failed')(复现"网络断了")。
//   只拦发往 NEXT_PUBLIC_SUPABASE_URL 的请求。装上之后,这一进程里其余的收尾都在故障之下跑。
export function installCleanupNetworkFault(mode) {
    const real = globalThis.fetch
    globalThis.fetch = (input, init) => {
        const url = typeof input === 'string' ? input : (input?.url ?? String(input))
        if (!url.startsWith(URL_)) return real(input, init)
        if (mode === 'refused') return Promise.reject(new TypeError('fetch failed(故障注入:cleanup-refused)'))
        return new Promise((_, reject) => {
            const sig = init?.signal
            if (!sig) return   // 没有上限的往返:永远挂着 —— 正是这一刀要消灭的形状
            if (sig.aborted) return reject(sig.reason ?? new Error('aborted'))
            sig.addEventListener('abort', () => reject(sig.reason ?? new Error('aborted')), { once: true })
        })
    }
    console.error(`  !! 故障注入:收尾阶段发往库的每一次往返都${mode === 'refused' ? '立刻失败' : '挂住(只认 abort)'}`)
}

const del = (path) => fetch(URL_ + path, {
    method: 'DELETE',
    headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}` },
    signal: cleanupSignal(),
})

// ★ BTN-4:一步不一定是 DELETE —— 软删的表(tasks)硬删不掉,见 planDelete 的 how。
const req = (path, how) => fetch(URL_ + path, {
    method: how.method || 'DELETE',
    headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json' },
    ...(how.body ? { body: how.body } : {}),
    signal: cleanupSignal(),
})

function procName(pid) {
    try { return execFileSync('ps', ['-p', String(pid), '-o', 'comm='], { encoding: 'utf8' }).trim() || null }
    catch { return null }
}

// ── 计划文件 ────────────────────────────────────────────────────────────────
// 一份计划 = 一串【按顺序执行的 DELETE】。顺序是调用方定的,而顺序【要紧】:
// 评估 → 员工 → 授权 → 账号。倒过来删会留下指向已删行的记录,
// 而"先删账号后收权限"留下的正是一条认不到人的授权。
let planPath = null
let plan = null

/** 开一份计划。**在造出任何东西【之前】调用。** */
export function openPlan(script) {
    mkdirSync(PLAN_DIR, { recursive: true })
    planPath = join(PLAN_DIR, `${process.pid}.json`)
    plan = { script, pid: process.pid, proc_name: procName(process.pid),
             started_at: new Date().toISOString(), steps: [] }
    writeFileSync(planPath, JSON.stringify(plan, null, 2))
    return plan
}

/**
 * ★【删除顺序是【声明】出来的,不是碰巧的】★
 *   计划是按"造出来的先后"追加的,而【删】必须按依赖的反序:
 *     performance_reviews → employees → user_roles → auth.users
 *   按追加顺序执行会先删员工、再删指着它的评估 —— 外键当场拒绝,
 *   于是清理"失败"了,而失败的那几步里就有那条 admin 授权。
 *   所以每一步带一个档位,执行前按档位【稳定排序】。
 */
// ROLE: 35 —— ROLE-1(2026-09-23):冒烟不再能借 `admin` 当"什么都看得见"的钥匙
//   (Tim 的 Q8:admin 只剩系统管理三码),于是它自己造一个一次性的全码角色。
//   删角色要排在【收回授权】之后(user_roles 指着它)、删账号之前;role_permissions 随角色级联。
export const ORDER = { REVIEW: 10, EMPLOYEE: 20, GRANT: 30, ROLE: 35, ACCOUNT: 40, OTHER: 25 }

/**
 * 往计划里【追加一步,并当场落盘】。
 * ★ 返回之后,这一步才可以真的去造 —— 反过来就是 LEAK-1 的形状。
 */
export function planDelete(path, ctx, order = ORDER.OTHER, how = null) {
    if (!plan) throw new Error('ephemeral: planDelete 在 openPlan 之前被调用')
    // ★ BTN-4:`how` 让一步可以是【软删】而不是 DELETE。
    //   起因是实测的:`tasks` 上挂着 trg_tasks_no_hard_delete,**任何人都硬删不掉**
    //   (它无条件 RAISE)。于是一支造了任务的探针,用 DELETE 永远清不干净自己 ——
    //   而清不干净会让 runPlan 退 1,把一次【正常收尾】报成一次泄漏。
    //   ☞ 计划文件是【先于那个东西落盘】的,所以 how 必须跟着一起落盘:
    //     SIGKILL 之后补删的那一支,读到的必须是同一句 PATCH。
    plan.steps.push(how ? { path, ctx, order, how } : { path, ctx, order })
    writeFileSync(planPath, JSON.stringify(plan, null, 2))   // 同步:这一句是①那一层的全部
}

/** 按档位稳定排序(同档位保持追加顺序)。 */
const inDeleteOrder = (steps) => steps
    .map((s, i) => ({ s, i }))
    .sort((a, b) => (a.s.order ?? ORDER.OTHER) - (b.s.order ?? ORDER.OTHER) || a.i - b.i)
    .map((x) => x.s)

/** 造一条授权,并把 granted_by 写成被授权人自己(自授 = 一次性)。 */
export function ephemeralGrantBody(userId, roleId) {
    return { user_id: userId, role_id: roleId, granted_by: userId }
}

// ── 执行 ────────────────────────────────────────────────────────────────────
const failures = []
// CLAIM-GST-1:【确认删掉了】的步(2xx / 404 / 406)。收尾没完成时,计划里不在这里的每一步都要点名。
const confirmed = new Set()
// CLAIM-GST-1:本进程自己的收尾有没有没完成的地方(与 reapStalePlans 替别人补删的失败分开记)。
const incompleteNotes = []

async function runSteps(steps, label) {
    for (const s of steps) {
        // 截止时刻到了:后面的步不再发起(每一步都会立刻被 abort),留给点名与下一次补删。
        if (phaseAbort.signal.aborted) {
            failures.push(`${s.ctx}: 收尾阶段已到截止时刻,这一步没有发起`)
            continue
        }
        try {
            // 默认 DELETE;带 how 的走它自己那一句(见 planDelete 的 how)。
            const r = s.how ? await req(s.path, s.how) : await del(s.path)
            // 404/406 = 已经没有了,那正是我们要的终局,不算失败
            if (r.ok || r.status === 404 || r.status === 406) confirmed.add(s)
            if (!r.ok && r.status !== 404 && r.status !== 406) {
                const body = (await r.text()).slice(0, 200)
                failures.push(`${s.ctx}: HTTP ${r.status} ${body}`)
                console.error(`  ✗ ${label} 失败(继续往下清,但记账):${s.ctx} → HTTP ${r.status} ${body}`)
            }
        } catch (e) {
            failures.push(`${s.ctx}: ${e.message}`)
            console.error(`  ✗ ${label} 失败(继续往下清,但记账):${s.ctx} → ${e.message}`)
        }
    }
}

let cleaning = null

/** 跑完这一份计划,成功就把计划文件删掉。**重入安全**:信号可能来两次。 */
export function runPlan() {
    if (cleaning) return cleaning
    cleaning = (async () => {
        if (!plan || !plan.steps.length) { if (planPath && existsSync(planPath)) unlinkSync(planPath); return }
        const before = failures.length
        await runSteps(inDeleteOrder(plan.steps), '清理')
        if (failures.length > before) incompleteNotes.push(`计划里有 ${failures.length - before} 步没确认删掉`)
        if (failures.length) {
            // ★ 承诺没兑现必须让退出码说出来 ★「用完即删」是这几支自己许下的承诺,
            //   而一条留下来的 admin 授权不是一条日志。
            console.error(`\n✗ 一次性账号/授权没有清理干净 ${failures.length} 处 —`)
            console.error('  其中任何一条 user_roles 都是一条【悬空的管理员授权】:')
            for (const f of failures) console.error('   ' + f)
            console.error(`  计划留在 ${planPath} —— 下一次开跑会照它补删;`)
            console.error('  也可以手工:node scripts/reap-ephemeral.mjs')
            process.exitCode = 1
            return                       // ★ 没清干净就【不删】计划文件
        }
        unlinkSync(planPath)
    })()
    return cleaning
}

// ── 收割:别人留下的计划 ────────────────────────────────────────────────────
/**
 * 扫 .ephemeral/,把【持有者已经不在了】的计划执行掉。
 * 判据与 liveLock 逐字一致:pid 还在【且】进程名一致才算活着(防 pid 复用)。
 * 这一段就是③那一层 —— **它不需要留下计划的那个进程做任何事**,
 * 所以 SIGKILL 也好、断电也好,都由它兜底。
 */
export async function reapStalePlans({ quiet = false } = {}) {
    // 【三种结局要分开数】收干净了 / 补删失败了 / 持有者还活着不该动。
    // 把后两种混成一个"还剩 N 份",读的人分不出"出事了"与"一切正常",
    // 而那正是一份【喊狼来了】的报告的开头。
    const out = { reaped: 0, failed: 0, skippedAlive: 0 }
    if (!existsSync(PLAN_DIR)) return out
    for (const name of readdirSync(PLAN_DIR)) {
        if (!name.endsWith('.json')) continue
        const p = join(PLAN_DIR, name)
        let info
        try { info = JSON.parse(readFileSync(p, 'utf8')) } catch { unlinkSync(p); continue }
        if (info.pid === process.pid) continue                     // 自己那一份
        const now = procName(info.pid)
        if (now !== null && now === info.proc_name) { out.skippedAlive++; continue }  // 还活着,别动
        if (!quiet)
            console.error(`· 收割上一次没跑完的清理:${info.script} pid=${info.pid} ` +
                `起于 ${info.started_at},${info.steps.length} 步`)
        const before = failures.length
        await runSteps(inDeleteOrder(info.steps), '收割')
        if (failures.length === before) { unlinkSync(p); out.reaped++ }
        else { out.failed++; if (!quiet) console.error(`  ✗ 这一份没收割干净,留着 ${p} 下次再试`) }
    }
    return out
}

// ── 把清理接到每一条出口上 ──────────────────────────────────────────────────
/**
 * ★ 这一支【自己拥有退出】★ —— 它必须是最后一个动手的。
 *
 * 【为什么要接管 liveLock 的退出】见文件抬头:liveLock 的信号处理器是
 * 同步的 `process.exit(130)`,它会把还在 await 的清理【当场掐死】。
 * 所以用了本支的脚本要调 `acquireOrExit(holder, { ownExit: false })`,
 * 把"什么时候退出"交给这里 —— 清理跑完、锁放掉,才退。
 *
 * 覆盖的出口:SIGINT / SIGTERM / SIGHUP / SIGPIPE(UI-1d 的 EPIPE 就是这一条)、
 * uncaughtException、unhandledRejection、以及正常跑完。
 * **SIGKILL 不在此列,它捕获不到** —— 那一条交给 reapStalePlans。
 */
// ★ PAY-REQ-1(2026-09-23,Tim 裁定:冒烟【无论成败】都要把一次性账号、角色、授权收干净)★
//   installExitHooks 只接了信号与未捕获异常。而脚本自己的失败分支写的是
//   `main().catch(() => process.exit(1))` —— **同步的 process.exit 不经过任何一个钩子**,
//   于是"建完账号 + 授权之后,设置阶段炸了"这一条最常见的失败路径,计划一步都没跑。
//   ROLE-1 那一跑就是这么在线上留下一个持全码角色的账号的(两次)。
//   ☞ 所以退出不再有第二种写法:脚本里【开了计划之后】的每一条出口都调 exitAfterCleanup(code)。
let onFinishHook = () => {}
let beforeFinishHook = async () => {}
let exitingPromise = null

/**
 * 【唯一的退出口】跑计划 → 跑 beforeFinish(异步,名字兜底的清扫之类)→ 跑 onFinish
 * (收子进程、放锁)→ 退出。**重入安全**:第二次调用拿到的是同一个 promise,
 * 不会把清理跑两遍,也不会被第二个信号提前掐断。
 * ★ 顺序即 LEAK-1 的修法:网络往返先跑完,再收子进程,最后才 exit。
 * 退出码:调用方给的非零码优先(信号 143 仍是 143、失败仍是失败);调用方给 0 而清理
 * 没清干净(runPlan 置 process.exitCode = 1)时退 1 —— 一次"成功"不许把一条留下来的授权盖掉。
 */
export function exitAfterCleanup(code = 0) {
    if (exitingPromise) return exitingPromise
    beginCleanupPhase()
    exitingPromise = (async () => {
        const t0 = Date.now()
        // ★ CLAIM-GST-1:收尾阶段有一个截止时刻。到点就 abort 掉还在飞的往返,不再等 ——
        //   这个 promise 自己会到点,所以第二个信号(重入拿到的是同一个 promise)改变不了它。
        let timer
        const deadline = new Promise((res) => { timer = setTimeout(() => res('deadline'), CLEANUP_PHASE_DEADLINE_MS) })
        const work = (async () => {
            try { await runPlan() } catch (e) {
                console.error('  ✗ runPlan 抛出:' + (e?.message ?? e)); process.exitCode = 1
                incompleteNotes.push('runPlan 抛出:' + (e?.message ?? e))
            }
            try { await beforeFinishHook() } catch (e) {
                console.error('  ✗ 收尾清扫抛出:' + (e?.message ?? e)); process.exitCode = 1
                incompleteNotes.push('按名兜底清扫没有跑完(smoke-*@test.local 账号 / ZZ-SMOKE-* 员工 / probe-smoke-all-* 角色 '
                    + '这几个命名空间没有被确认扫干净):' + (e?.message ?? e))
            }
            return 'done'
        })()
        const how = await Promise.race([work, deadline])
        clearTimeout(timer)
        if (how === 'deadline') {
            phaseAbort.abort(new Error(`收尾阶段到了 ${CLEANUP_PHASE_DEADLINE_MS / 1000}s 截止时刻`))
            incompleteNotes.push(`收尾阶段到了 ${CLEANUP_PHASE_DEADLINE_MS / 1000}s 截止时刻,还在飞的往返被中止`)
        }
        const incomplete = incompleteNotes.length > 0
        if (incomplete) {
            // ★ 点名:没确认删掉的每一步。计划是【先于它要清的东西】落盘的,所以它就是那张清单。
            const left = plan ? inDeleteOrder(plan.steps).filter((st) => !confirmed.has(st)) : []
            console.error(`\n✗ 收尾没有完成(${((Date.now() - t0) / 1000).toFixed(1)}s)—— 退 ${EXIT_CLEANUP_INCOMPLETE}。没能确认删掉的:`)
            for (const st of left) console.error(`   · ${st.ctx}  →  ${st.how?.method ?? 'DELETE'} ${st.path}`)
            if (!left.length) console.error('   · (计划里的每一步都确认删掉了)')
            for (const n of incompleteNotes) console.error(`   · ${n}`)
            if (planPath && existsSync(planPath))
                console.error(`  计划留在 ${planPath} —— 下一次开跑会照它补删;也可以手工:npm run reap:ephemeral`)
            const was = code || process.exitCode || 0
            if (was && was !== EXIT_CLEANUP_INCOMPLETE)
                console.error(`  (这一跑本来的退出码是 ${was};收尾没完成优先,退 ${EXIT_CLEANUP_INCOMPLETE} —— 两件事都在上面)`)
        }
        // ★ onFinish 跑在清理【之后】—— 收子进程(chrome / dev server)与放锁都要等
        //   清理的 REST 往返跑完。★ 而它【必须存在】:第一版只放了锁、没收子进程,
        //   实测 SIGTERM 之后 `next dev` 与 chrome 双双 ppid=1 活了下来。
        try { onFinishHook() } catch (e) { console.error('  ✗ onFinish 失败:' + e?.message) }
        process.exit(incomplete ? EXIT_CLEANUP_INCOMPLETE : (code || process.exitCode || 0))
    })()
    return exitingPromise
}

/**
 * ★ 这一支【自己拥有退出】★ —— 它必须是最后一个动手的。
 *
 * 【为什么要接管 liveLock 的退出】见文件抬头:liveLock 的信号处理器是
 * 同步的 `process.exit(130)`,它会把还在 await 的清理【当场掐死】。
 * 所以用了本支的脚本要调 `acquireOrExit(holder, { ownExit: false })`,
 * 把"什么时候退出"交给这里 —— 清理跑完、锁放掉,才退。
 *
 * 覆盖的出口:SIGINT / SIGTERM / SIGHUP / SIGPIPE(UI-1d 的 EPIPE 就是这一条)、
 * uncaughtException、unhandledRejection。**脚本自己的出口(正常跑完、catch 到的失败、
 * 任何一条失败分支)必须自己调 exitAfterCleanup(code)** —— 一句直接的 process.exit
 * 会绕过这里的一切(PAY-REQ-1)。
 * **SIGKILL 不在此列,它捕获不到** —— 那一条交给 reapStalePlans。
 *
 * beforeFinish:可选的异步收尾(在 runPlan 之后、onFinish 之前),给"按名字兜底"的清扫用 ——
 * 计划里还没来得及登记的那一行(造出来 → 登记之间的那一个 await)由它接住。
 */
export function installExitHooks({ onFinish = () => {}, beforeFinish = async () => {} } = {}) {
    onFinishHook = onFinish
    beforeFinishHook = beforeFinish
    for (const [sig, code] of [['SIGINT', 130], ['SIGTERM', 143], ['SIGHUP', 129], ['SIGPIPE', 141]])
        process.on(sig, () => { console.error(`\n!! 收到 ${sig} —— 先清理,再退出`); exitAfterCleanup(code) })
    process.on('uncaughtException', (e) => { console.error('\n!! uncaught:', e?.stack || e); exitAfterCleanup(1) })
    process.on('unhandledRejection', (e) => { console.error('\n!! unhandled rejection:', e?.stack || e); exitAfterCleanup(1) })
}
