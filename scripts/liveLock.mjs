// scripts/liveLock.mjs —— 冒烟这一侧的 live-lock(FIX-3)
//
// **锁文件的格式与判据在 `db/live_lock.py` 里定义,那是唯一的一份。**
// 这里是 Node 的实现,因为 gate 是 Python 而冒烟是 Node —— 两份实现是不得已的,
// 所以字段名、陈旧判据(pid 还在 **且** 进程名一致,防 pid 复用)、以及
// "只释放自己那一把"这三条,必须与那边逐字一致。改了那边,这里跟着改。
import { readFileSync, writeFileSync, existsSync, unlinkSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { hostname } from 'node:os'

const LOCK = join(dirname(dirname(fileURLToPath(import.meta.url))), '.live-lock')

function procName(pid) {
    try {
        return execFileSync('ps', ['-p', String(pid), '-o', 'comm='], { encoding: 'utf8' }).trim() || null
    } catch { return null }
}

/** 还活着的持有者;没有就 null。**陈旧锁在这里被清除,而不是被尊重。** */
export function heldBy() {
    if (!existsSync(LOCK)) return null
    let info
    try { info = JSON.parse(readFileSync(LOCK, 'utf8')) } catch {
        unlinkSync(LOCK); return null      // 读不出来的锁不能当成"被持有"
    }
    const now = procName(info.pid)
    if (now === null || now !== info.proc_name) {
        console.error(`· live-lock:清掉一把陈旧的锁(holder=${info.holder} pid=${info.pid} 记录的进程名=${info.proc_name} 现在那个 pid 是=${now})`)
        unlinkSync(LOCK)
        return null
    }
    return info
}

/** 拿锁。**被别人持有就返回 false,不等待。** */
export function acquire(holder) {
    if (heldBy() !== null) return false
    writeFileSync(LOCK, JSON.stringify({
        holder,
        pid: process.pid,
        proc_name: procName(process.pid),
        started_at: new Date().toISOString(),
        started_epoch: Math.floor(Date.now() / 1000),
        host: hostname(),
    }))
    return true
}

/** 释放 —— 只释放自己那一把。 */
export function release() {
    if (!existsSync(LOCK)) return
    try {
        const info = JSON.parse(readFileSync(LOCK, 'utf8'))
        if (info.pid === process.pid) unlinkSync(LOCK)
    } catch { unlinkSync(LOCK) }
}

/**
 * 拿锁并把释放接到每一条出口上:正常退出、异常、SIGINT/SIGTERM。
 * **一把能在崩溃后活下来的锁比没有锁更坏** —— 下一个人会用手删它,然后学会每次都删。
 */
export function acquireOrExit(holder) {
    const other = heldBy()
    if (other !== null) {
        const ago = Math.floor(Date.now() / 1000) - (other.started_epoch ?? 0)
        console.error(`\n✗ 路由冒烟拒绝开跑 —— 线上库此刻被【${other.holder}】占着。`)
        console.error(`   持有者 pid ${other.pid},自 ${other.started_at} 起,已经 ${Math.floor(ago / 60)} 分 ${ago % 60} 秒。`)
        console.error(`   等它跑完再来;它退出时会自己把锁放掉(失败与中断也放)。\n`)
        process.exit(5)
    }
    acquire(holder)
    process.on('exit', release)
    for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
        process.on(sig, () => { release(); process.exit(130) })
    }
    process.on('uncaughtException', (e) => { release(); throw e })
}
