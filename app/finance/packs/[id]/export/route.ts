// app/finance/packs/[id]/export/route.ts
// GLEXPORT-1:一份已存档的包的 CSV。抬头块的形状端口自 agingCsv.ts / F5 导出:
// **这一份是什么、覆盖哪个月、什么时候产出的、以及它看不见什么** 全写在文件里,
// 因为文件名会被改、会在转发里丢掉。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { csvRow, csvResponse } from '@/lib/csv'
import { getTranslations } from '@/lib/i18n/server'

export async function GET(
    _request: NextRequest,
    { params }: { params: Promise<{ id: string }> },
) {
    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const { data, error } = await supabase.from('management_packs')
        .select('code, period_month, period_start, period_end, produced_at, locked_before_at_production, payload')
        .eq('id', id).single()
    // 一份【空的 CSV】读起来像"这个月没有数",那是一句假话 —— 报错,不返回空表。
    if (error || !data) {
        return new Response(`Export failed: ${error?.message ?? 'pack not found'}`,
            { status: error ? 500 : 404 })
    }
    const p = data.payload as Record<string, never>
    const ccy = String(p.base_currency ?? '')
    const cv = (p.caveats ?? {}) as Record<string, unknown>

    const lines: string[] = []
    lines.push(csvRow(['MONTHLY MANAGEMENT PACK / 月度管理报表包', data.code]))
    lines.push(csvRow(['Month / 月份', String(data.period_month).slice(0, 7)]))
    lines.push(csvRow(['Period / 期间', `${p.period_start} .. ${p.period_end}`]))
    lines.push(csvRow(['Produced at / 产出时间', String(data.produced_at)]))
    // ★ 存档的那句话,写进文件本身 ★
    lines.push(csvRow(['Locked before (at production) / 产出时的关账线',
        String(data.locked_before_at_production)]))
    lines.push(csvRow(['What a stored pack means / 存档的含义', t('pack.storedMeans')]))
    lines.push(csvRow(['Base currency / 本位币', ccy]))
    lines.push('')

    lines.push(csvRow(['STATEMENTS / 报表', `Amount (${ccy})`]))
    lines.push(csvRow([t('pack.netProfit'), (p.pnl as Record<string, never>)?.net_profit ?? '']))
    lines.push(csvRow([t('pack.totalAssets'), (p.balance_sheet as Record<string, never>)?.total_assets ?? '']))
    lines.push(csvRow([t('pack.arHeading'), (p.ar_aging as Record<string, never>)?.total_open_base ?? '']))
    lines.push(csvRow([t('pack.apHeading'), (p.ap_aging as Record<string, never>)?.total_open_base ?? '']))
    lines.push('')

    lines.push(csvRow(['CONTROL ACCOUNT vs SUB-LEDGER / 控制科目 ↔ 明细账']))
    lines.push(csvRow([t('pack.colSide'), t('pack.colControl'), t('pack.colLedger'),
        t('pack.colSubledger'), t('pack.colDifference'), t('pack.colOrigination'),
        t('pack.colSettlement'), t('pack.colRevaluation'), t('pack.colUnexplained')]))
    for (const s of ((p.control_reconciliation as Record<string, never>)?.sides ?? []) as Record<string, never>[]) {
        lines.push(csvRow([s.side, s.control_account, s.ledger_base, s.subledger_base,
            s.difference_base, s.origination_variance_base, s.settlement_variance_base,
            s.revaluation_base, s.unexplained_base]))
    }
    lines.push('')

    // ★【它看不见什么 —— 写在文件里,不是留给读的人猜】★
    lines.push(csvRow(['WHAT THIS PACK CANNOT SEE / 这份包看不见什么']))
    const notes: string[] = []
    if (cv.month_not_locked) notes.push(t('pack.cvMonthNotLocked'))
    if (cv.aging_capped_at_today) notes.push(t('pack.cvAgingCapped', { date: String(p.aging_as_of) }))
    if (cv.fx_missing_mid) notes.push(t('pack.cvFxMissingMid'))
    if (cv.fx_not_revalued) notes.push(t('pack.cvFxNotRevalued'))
    if (Number(cv.split_reversal_pairs_n ?? 0) > 0) notes.push(t('pack.cvSplitPairs', { n: String(cv.split_reversal_pairs_n) }))
    if (cv.no_bank_reconciliation) notes.push(t('pack.cvNoBankRec'))
    if (cv.no_cash_forecast) notes.push(t('pack.cvNoForecast'))
    if (notes.length === 0) lines.push(csvRow([t('pack.cannotSeeNone')]))
    for (const n of notes) lines.push(csvRow(['', n]))

    return csvResponse(lines, `management-pack-${String(data.period_month).slice(0, 7)}.csv`)
}
