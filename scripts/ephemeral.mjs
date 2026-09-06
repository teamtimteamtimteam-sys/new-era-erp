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

const del = (path) => fetch(URL_ + path, {
    method: 'DELETE',
    headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}` },
})

// ★ BTN-4:一步不一定是 DELETE —— 软删的表(tasks)硬删不掉,见 planDelete 的 how。
const req = (path, how) => fetch(URL_ + path, {
    method: how.method || 'DELETE',
    headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json' },
    ...(how.body ? { body: how.body } : {}),
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
export const ORDER = { REVIEW: 10, EMPLOYEE: 20, GRANT: 30, ACCOUNT: 40, OTHER: 25 }

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

async function runSteps(steps, label) {
    for (const s of steps) {
        try {
            // 默认 DELETE;带 how 的走它自己那一句(见 planDelete 的 how)。
            const r = s.how ? await req(s.path, s.how) : await del(s.path)
            // 404/406 = 已经没有了,那正是我们要的终局,不算失败
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
        await runSteps(inDeleteOrder(plan.steps), '清理')
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
export function installExitHooks({ onFinish = () => {} } = {}) {
    let exiting = false
    const finish = async (code) => {
        if (exiting) return
        exiting = true
        await runPlan()
        // ★ onFinish 跑在 runPlan【之后】—— 这个顺序就是 LEAK-1 的修法本身:
        //   收子进程(chrome / dev server)与放锁都要等清理的 REST 往返跑完。
        //   ★ 而它【必须存在】:第一版只放了锁、没收子进程,实测 SIGTERM 之后
        //     `next dev` 与 chrome 双双 ppid=1 活了下来 —— 在上限处消灭一个孤儿、
        //     同时在信号处造出两个,与 AGENTS.md 记的 run_detached 那一课同形。
        try { onFinish() } catch (e) { console.error('  ✗ onFinish 失败:' + e?.message) }
        process.exit(process.exitCode || code)
    }
    for (const [sig, code] of [['SIGINT', 130], ['SIGTERM', 143], ['SIGHUP', 129], ['SIGPIPE', 141]])
        process.on(sig, () => { finish(code) })
    process.on('uncaughtException', (e) => { console.error('\n!! uncaught:', e?.stack || e); finish(1) })
    process.on('unhandledRejection', (e) => { console.error('\n!! unhandled rejection:', e?.stack || e); finish(1) })
}
