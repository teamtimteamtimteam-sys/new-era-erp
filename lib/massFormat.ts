// lib/massFormat.ts
// MES-5b-1(2026-10-08):物料平衡与得率页上的数 —— 公斤到 0.001(称重的分辨率),百分数到 0.01。
//   只给屏幕用:平衡与归属在库里是精确的(batch_balance_tree_all 的 share_num / share_den),四舍五入只在这里(Step 0 Q4)。
//   数据库给的是 numeric,PostgREST 以 number 或 string 递过来,两种都收;读不出数的原样印出来,不印 0(一个假的 0 是一句谎)。
const KG = new Intl.NumberFormat('en-US', { maximumFractionDigits: 3 })
const PCT = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

export function num(v: number | string | null | undefined): number | null {
    if (v === null || v === undefined || v === '') return null
    const n = typeof v === 'number' ? v : Number(v)
    return Number.isFinite(n) ? n : null
}

export function fmtKg(v: number | string | null | undefined): string {
    const n = num(v)
    return n === null ? '—' : KG.format(n)
}

export function fmtPct(v: number | string | null | undefined): string {
    const n = num(v)
    return n === null ? '—' : `${PCT.format(n)}%`
}
