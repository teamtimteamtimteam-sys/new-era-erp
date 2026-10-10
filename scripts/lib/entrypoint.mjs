// scripts/lib/entrypoint.mjs —— 一支对着线上动手的脚本【只在被直接执行时】才跑;被 import 时什么都不开始。
// ════════════════════════════════════════════════════════════════════════════
// MES-6a-2(2026-10-10,Tim 的并入):`scripts/smoke-routes.mjs`(以及每一支对着线上动手的脚本)只在被直接执行时跑,从不在被 import 时跑;
//   一道检查证明 import 它什么都不开始(scripts/check-import-inert.mjs,进构建)。
//
// 【为什么】这台机器上【两次】为了"看一眼"而 import 了冒烟脚本,两次它都当场开跑(MES-5b-3 hand-back §8 第 5 条:没做事;
//   MES-6a-1 hand-back §8:它真的对着线上起了 dev server、建了一个持全码的一次性账号,被 SIGTERM 掉)。
//   一支模块被 import 时就开始对线上动手,是一个【读一眼就会出事】的接口 —— 同一个形状撞了第二次,就不再写注解,换成机制(AGENTS.md)。
//
// 【用法】每一支对着线上动手的脚本,在 import 之后的【第一句】:
//     import { onlyWhenRunDirectly } from './lib/entrypoint.mjs'
//     onlyWhenRunDirectly(import.meta.url)
//   被 `node <它>` 直接执行 → 什么都不做,往下跑;被 import → 抛 NOT_RUN_ON_IMPORT|<文件>,模块的其余部分一句都不执行。
//   ☞ 抛,而不是悄悄 return:ES 模块的顶层没有 return,而一个"被 import 时安静地少跑一半"的模块比一个响亮拒绝的更难读懂。
//
// 【判据】比的是【真实路径】:node 把主模块的路径按 realpath 解析(--preserve-symlinks-main 默认关),于是 import.meta.url 是真实路径;
//   process.argv[1] 可能是相对路径、可能经过符号链接(/tmp → /private/tmp),所以两边都 realpath 一次再比。
import { realpathSync } from 'node:fs'
import { fileURLToPath, pathToFileURL } from 'node:url'

/** 这一支模块是不是被 `node <它>` 直接执行的那一个。 */
export function isEntrypoint(importMetaUrl) {
    const argv1 = process.argv[1]
    if (!argv1) return false
    let main
    try { main = realpathSync(argv1) } catch { return false }
    let self
    try { self = realpathSync(fileURLToPath(importMetaUrl)) } catch { return false }
    return pathToFileURL(main).href === pathToFileURL(self).href
}

/** 被 import 时抛;被直接执行时什么都不做。必须是脚本 import 之后的第一句(scripts/check-import-inert.mjs 按 AST 核对)。 */
export function onlyWhenRunDirectly(importMetaUrl) {
    if (!isEntrypoint(importMetaUrl)) {
        const e = new Error(`NOT_RUN_ON_IMPORT|${fileURLToPath(importMetaUrl)} —— 这支脚本对着线上动手,只在被直接执行(node <它>)时才跑;被 import 时什么都不开始`)
        e.code = 'NOT_RUN_ON_IMPORT'
        throw e
    }
}
