// app/inbound/[id]/edit/InboundMarginPanel.tsx
// MES-8b-1(2026-10-17,MES-0 Q80;MES-8 Step 0 Q10 · Q11 · Q13,Tim):这一批进料到今天为止赚了多少 —— 经由用它做出来、卖出去的每一样。
//   【算术一个字都不在这里】读 inbound_batch_margin(份额 = MES-5b 按投入质量的份额;毛利 = Σ 份额 × (收入 − 单位成本 × 已售);
//   没卖的按成本在库;路径上任何一条腿没价就是「Not computable」,原因逐条点名 —— 永远不是 0)。
//   【门】AGENTS.md 常设决定 2:data.view_prices AND (module.finance.view OR module.processing.view)—— 与 /margin 同一份判据(FN.margin.permission);
//   不满足的读者看到「Restricted」与要的码,不调用那支函数(它会按名拒,而一次拒绝不是一个空答案)。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustOne } from '@/lib/db-helpers'
import { getMyPermissions } from '@/lib/permissions'
import { allows, FN } from '@/lib/modules'
import { formatAmount } from '@/lib/format'
import { fmtKg } from '@/lib/massFormat'
import InboundMarginTable, { type MarginLine } from './InboundMarginTable'

type Margin = {
    code: string; unit: string; base_currency: string; computable: boolean; margin_state: 'computed' | 'nothing_sold' | 'not_computable'
    reasons: { code: string; batch_code: string }[]; qty_sold: number; revenue_base: number | null; cost_of_sold_base: number | null
    margin_base: number | null; on_hand_downstream: number; on_hand_own: number; on_hand_at_cost_base: number | null; lines: MarginLine[]
}

export default async function InboundMarginPanel({ batchId }: { batchId: string }) {
    const t = await getTranslations()
    const allowed = allows(FN.margin.permission, await getMyPermissions())
    if (!allowed) {
        return (
            <section className="mt-8" data-section="inbound-margin">
                <h2 className="mb-1">{t('inboundMargin.title')}</h2>
                <p className="text-sm text-[color:var(--brand-muted-text)]" data-access-restricted="inbound-margin">
                    {t('common.restricted')} · <code className="text-[0.95em]">data.view_prices</code> + <code className="text-[0.95em]">module.finance.view</code> / <code className="text-[0.95em]">module.processing.view</code>
                </p>
            </section>
        )
    }
    const supabase = await createClient()
    const m = mustOne(await supabase.rpc('inbound_batch_margin', { p_inbound_batch_id: batchId }) as never, 'inbound_batch_margin') as Margin
    const amt = (n: number | null) => (n === null ? t('inboundMargin.notComputable') : formatAmount(Number(n), m.base_currency))
    const reason = (c: string) => ({
        inbound_unpriced: t('inboundMargin.reason.inboundUnpriced'), output_no_unit_cost: t('inboundMargin.reason.outputNoUnitCost'),
        output_cost_incomplete: t('inboundMargin.reason.outputCostIncomplete'), output_not_from_a_run: t('inboundMargin.reason.outputNotFromARun'),
    } as Record<string, string>)[c] ?? c
    return (
        <section className="mt-8" data-section="inbound-margin">
            <h2 className="mb-1">{t('inboundMargin.title')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-3 max-w-3xl">{t('inboundMargin.intro')}</p>
            <div className="max-w-md text-sm mb-3" data-value={`margin-${m.margin_state}`}>
                <div className="flex justify-between gap-4 py-0.5"><span className="text-[color:var(--brand-muted-text)]">{t('inboundMargin.revenue')}</span><span>{amt(m.revenue_base)}</span></div>
                <div className="flex justify-between gap-4 py-0.5"><span className="text-[color:var(--brand-muted-text)]">{t('inboundMargin.costOfSold')}</span><span>{amt(m.cost_of_sold_base)}</span></div>
                <div className="flex justify-between gap-4 border-t border-gray-400 mt-1 pt-1 font-medium">
                    <span>{t('inboundMargin.margin')}</span>
                    <span data-value="inbound-margin">{m.margin_state === 'nothing_sold' ? t('inboundMargin.nothingSold') : amt(m.margin_base)}</span>
                </div>
                <div className="flex justify-between gap-4 py-0.5 mt-2"><span className="text-[color:var(--brand-muted-text)]">{t('inboundMargin.sold', { unit: m.unit })}</span><span>{fmtKg(m.qty_sold)}</span></div>
                <div className="flex justify-between gap-4 py-0.5">
                    <span className="text-[color:var(--brand-muted-text)]">{t('inboundMargin.onHand', { unit: m.unit })}</span>
                    <span>{fmtKg(Number(m.on_hand_own) + Number(m.on_hand_downstream))}</span>
                </div>
                <div className="flex justify-between gap-4 py-0.5">
                    <span className="text-[color:var(--brand-muted-text)]">{t('inboundMargin.onHandAtCost')}</span><span data-value="on-hand-at-cost">{amt(m.on_hand_at_cost_base)}</span>
                </div>
            </div>
            {!m.computable && (
                <ul className="text-sm text-amber-900 bg-amber-50 border border-amber-300 rounded px-3 py-2 mb-3 max-w-3xl list-disc pl-6" data-notice="margin-not-computable">
                    {m.reasons.map((r, i) => <li key={i}>{reason(r.code)} — {r.batch_code}</li>)}
                </ul>
            )}
            <InboundMarginTable lines={m.lines} baseCurrency={m.base_currency} batchCode={m.code} />
        </section>
    )
}
