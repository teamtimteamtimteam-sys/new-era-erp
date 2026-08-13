// app/inventory/reports/reportShared.ts
// RPT-1:四张报表共用的取数与导出零件。
//
// 【为什么共用】页面、CSV、PDF 三处必须回答【同一个问题】。三处各写一份过滤,
// 屏幕上的表与导出的文件迟早不一样,而那种不一样没有任何东西会报错 ——
// 进料导出那一份(app/inbound/export/route.ts)早就是这么做的:导出复用列表页
// 自己的过滤模块,所以"当前视图"只有一个定义。这里照抄那条。


// ── CSV ─────────────────────────────────────────────────────────────────────
// 一律加双引号、内部双引号翻倍:字段里的逗号/换行/引号都不会破坏 CSV。
export function csvCell(value: unknown): string {
    if (value === null || value === undefined) return '""'
    return '"' + String(value).replace(/"/g, '""') + '"'
}

// UTC 输出 —— 服务器时区不该影响导出的字面值(同进料导出)。
export function csvDateTime(value: string | null): string {
    if (!value) return ''
    const d = new Date(value)
    if (Number.isNaN(d.getTime())) return value
    const p = (n: number) => String(n).padStart(2, '0')
    return (
        `${d.getUTCFullYear()}-${p(d.getUTCMonth() + 1)}-${p(d.getUTCDate())}` +
        ` ${p(d.getUTCHours())}:${p(d.getUTCMinutes())}`
    )
}

export function todayStamp(): string {
    const d = new Date()
    const p = (n: number) => String(n).padStart(2, '0')
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`
}

export function csvResponse(name: string, headers: string[], rows: unknown[][]): Response {
    const lines = [headers.map(csvCell).join(',')]
    for (const r of rows) lines.push(r.map(csvCell).join(','))
    // ﻿:Excel 靠 BOM 才认得出 UTF-8,否则中文列名是乱码。
    return new Response('﻿' + lines.join('\n'), {
        headers: {
            'Content-Type': 'text/csv; charset=utf-8',
            'Content-Disposition': `attachment; filename="${name}-${todayStamp()}.csv"`,
        },
    })
}

// 【失败不是空文件】—— 一个 0 行的 CSV 与"确实没有数据"长得一模一样,
// 而前者是错误。同进料导出:500 + 原因。
export function exportFailed(error: { message: string }): Response {
    return new Response(`Export failed: ${error.message}`, { status: 500 })
}


// ── 台账的默认日期窗 ─────────────────────────────────────────────────────────
// 【只有台账需要界】另外三张报表的行数由【当下的库存状态】决定:
// 快照 = 物料 × 库位 × 状态里非零的格子、违规 = 违规的格子、安全库存 = 被监控的
// 物料。它们不随时间增长 —— 今天线上分别是 5 / 0 / 0 行,而一年后仍然只与
// "有多少物料、多少库位"成正比。台账不同:它是 append-only 的流水,只会变长
// (今天 85 行)。所以界加在台账上,另外三张【明写不需要】,与仪表盘那条
// "有界,或写下为什么不需要界"同一条。
export const LEDGER_DEFAULT_DAYS = 90

export function defaultLedgerFrom(): string {
    const d = new Date()
    d.setDate(d.getDate() - LEDGER_DEFAULT_DAYS)
    return d.toISOString().slice(0, 10)
}
