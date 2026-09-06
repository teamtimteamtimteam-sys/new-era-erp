#!/usr/bin/env node
// scripts/reap-ephemeral.mjs —— 把上一次没跑完的清理【补删】掉
//
// ════════════════════════════════════════════════════════════════════════════
// 【它是 LEAK-1 三层里的第③层 —— 不依赖留下残骸的那个进程做任何事】
//
//   ① 清理计划先于它要清的东西落盘        (scripts/ephemeral.mjs: planDelete)
//   ② 正常退出与可捕获的信号照计划清理      (scripts/ephemeral.mjs: installExitHooks)
//   ③ **SIGKILL / 断电 —— ②跑不到,而①还在盘上。这一支照它补删。**
//
// 每一支会造一次性账号的脚本开跑时都会先跑一遍 reapStalePlans();
// 这一支是同一件事的【手工入口】,给"上一次被 kill -9 了,现在就想清干净"的人。
//
// 【它【不】做的事:它不碰存量的 28 条幽灵授权。】那些是 granted_by 为 NULL、
//   没有任何计划文件的历史残骸,归 scripts/sweep-ghost-grants.mjs 管,
//   而那一支有它自己的判据与引用检查。两件事分开,是因为判据不同:
//   这里的判据是"有一份写在盘上的计划",那里的判据是"auth.users 里没有这个人"。
//
// 用法:node scripts/reap-ephemeral.mjs
// 退出码:0 = 没有要收的,或全部收干净;1 = 有收不掉的(已逐条印出)
import { reapStalePlans, PLAN_DIR } from './ephemeral.mjs'
import { existsSync, readdirSync } from 'node:fs'

const before = existsSync(PLAN_DIR)
    ? readdirSync(PLAN_DIR).filter((f) => f.endsWith('.json')).length : 0
if (!before) { console.log('✓ 没有滞留的清理计划(.ephemeral/ 是空的)'); process.exit(0) }

console.log(`发现 ${before} 份清理计划,逐份检查持有者是否还活着…`)
const { reaped, failed, skippedAlive } = await reapStalePlans()

console.log(`\n收割 ${reaped} 份 · 补删失败 ${failed} 份 · 持有者还活着跳过 ${skippedAlive} 份`)
if (skippedAlive)
    console.log('  跳过的那些是【正在跑的那一次】,不该动 —— 判据与 liveLock 一致:' +
        'pid 还在【且】进程名一致。')
if (failed)
    console.log('  ✗ 补删失败的请人看一眼上面的原因再重跑;计划文件留着,不会丢。')
// 【只有"补删失败"才算红】"持有者还活着"是正常状态,把它算红等于每次有活在跑
// 就报一次警,而那样的红灯很快就没人看了。
process.exit(failed ? 1 : 0)
