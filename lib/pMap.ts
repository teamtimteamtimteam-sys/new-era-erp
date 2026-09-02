// lib/pMap.ts — 有上限的并发 map。
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么需要它 —— 一次实测,不是一条通则】(CHART-1 ②,2026-09-03)
// /settings/dictionaries 用 24,905 ms 渲染完(实测,冒烟计时),而它做的事是
// **85 次串行往返**:6 张字典各取一次行,再对【每一行 × 每一张引用表】各发一次
// count。substances 一张就是 7 行 × 8 张引用表 = 56 次。
//
// **那 85 次里,数据库真正干的活是 2.444 ms 一次**(EXPLAIN ANALYZE,
// inbound_batch_metals 上的 count:Seq Scan、1 个 shared hit、最大的引用表 24 行)。
// 也就是说 **每次往返里 99% 以上是【路上的时间】,不是查询的时间** ——
// 所以这里【不是】一个缺索引的问题:在一张只有一页的表上建索引,规划器也不会用它。
// 减少的必须是【往返的串行长度】,不是每次查询的成本。
//
// 【为什么不改成"把行取回来自己数"】那样能把 79 次压成 12 次,但它把
// **传输量从"一个计数"变成"整张引用表的那一列"** —— 今天最大的表 24 行,
// 无所谓;而 inbound_batches 是会长的,那种写法在它长到十万行那天会变成
// 一个更难查的问题。**count 走 HEAD,永远只传一个数。**
//
// 【为什么有上限,而不是 Promise.all 全放出去】79 个并发请求会一次性占满
// 连接池,而这个仓库已经为"把连接池打爆"付过账(check_mirrors 走连接池那一段)。
// 上限让墙上时间从"和"变成"批数 × 一次往返",同时不动池子。
// ════════════════════════════════════════════════════════════════════════════

/**
 * 并发跑 `fn`,同时在飞的不超过 `limit` 个。**结果顺序与输入顺序一致**
 * (不是完成顺序 —— 靠完成顺序对齐下标是这类工具的经典缺陷)。
 *
 * **任何一个 reject 都会向外 reject**,与 `Promise.all` 一致 ——
 * 这是刻意的:调用方靠 throw 把"查询失败"与"计数为零"分开
 * (AGENTS.md 的 `mustRows` / `?? []` 那一条)。吞掉它就是把一次失败
 * 变成一个看起来正常的零。
 */
export async function pMap<T, R>(
    items: readonly T[],
    limit: number,
    fn: (item: T, index: number) => Promise<R>,
): Promise<R[]> {
    if (limit < 1) throw new Error(`pMap: limit 必须 ≥ 1,收到 ${limit}`)
    const out = new Array<R>(items.length)
    let next = 0
    // 工人数取 min(limit, 长度):items 比 limit 短时不该起一堆立刻退出的工人。
    const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
        for (;;) {
            const i = next++
            if (i >= items.length) return
            out[i] = await fn(items[i], i)
        }
    })
    await Promise.all(workers)
    return out
}

/** 默认上限。**不是猜的**:见本文件抬头 —— 够把 79 次压到 7 批,又不至于占满池子。 */
export const DEFAULT_QUERY_CONCURRENCY = 12
