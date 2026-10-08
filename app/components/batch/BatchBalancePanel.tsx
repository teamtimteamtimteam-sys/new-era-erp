// app/components/batch/BatchBalancePanel.tsx
// ════════════════════════════════════════════════════════════════════════════
// MES-5b-1(2026-10-08,规格 §4.2;MES-0 Q59;MES-5b Step 0 Q4 · Q5 · Q6 · Q7,Tim)· 一个批次的质量去了哪里
// ════════════════════════════════════════════════════════════════════════════
// 【这一块是什么】/inbound/[id]/edit 与 /output/[id]/edit 上同一块:收进来的 = 在手 + 卖出 + 注销 + 盘点调整 + 回滚作废 + 加工消耗 + 拆去隔离。
//   "加工消耗"展开成这一批喂进的每一张单 —— 那张单的产出(子批次,接着往下展开)、有名字的损耗与余数,按这一批喂进的质量成比例分;
//   深度放电是一行事件(穿过去,不是消耗),回滚的单另列(连回更正它的那一张),有一条腿单位不是 kg 的单只点名、不合计。
// 【算术一个字都不在这里】读 batch_balance_tree(带门的外壳,门 = module.processing.view 或这一批自己那一页的查看码)。
//   树上的每一层在库里精确相加(share_num / share_den);这里只把 qty 画到 0.001 kg。
// ════════════════════════════════════════════════════════════════════════════
import type React from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { formatDate } from '@/lib/dates'
import { fmtKg, num } from '@/lib/massFormat'
import { labelMaps } from '@/app/operation/balance/labels'

type Node = {
    node_key: string; parent_key: string | null; depth: number; node_type: string; line_key: string | null
    x: number | string; qty: number | string | null; batch_kind: string | null; batch_id: string | null; batch_code: string | null
    unit: string | null; form_code: string | null; run_id: string | null; run_code: string | null; operation_type_code: string | null
    process_date: string | null; flow: string | null; remainder_state: string | null; era_mes4a: boolean | null
    reversed_at: string | null; corrects_run_code: string | null; corrected_by_run_code: string | null
    loss_category_code: string | null; loss_basis: string | null
}

const FATE_ORDER = ['on_hand', 'sold', 'written_off', 'adjusted', 'voided', 'consumed', 'split', 'consumed_not_kg', 'unexplained']

export default async function BatchBalancePanel({ kind, batchId }: { kind: 'inbound' | 'output'; batchId: string }) {
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const [res, labels] = await Promise.all([
        supabase.from('batch_balance_tree')
            .select('node_key, parent_key, depth, node_type, line_key, x, qty, batch_kind, batch_id, batch_code, unit, form_code, run_id, run_code, operation_type_code, process_date, flow, remainder_state, era_mes4a, reversed_at, corrects_run_code, corrected_by_run_code, loss_category_code, loss_basis')
            .eq('root_kind', kind).eq('root_id', batchId).order('depth').order('node_key'),
        labelMaps(supabase, locale, t),
    ])
    const nodes = mustRows(res, 'batch_balance_tree') as unknown as Node[]
    const root = nodes.find((n) => n.node_type === 'batch')

    const fateText: Record<string, string> = {
        on_hand: t('massBalance.panel.fateOnHand'), sold: t('massBalance.panel.fateSold'), written_off: t('massBalance.panel.fateWrittenOff'),
        adjusted: t('massBalance.panel.fateAdjusted'), voided: t('massBalance.panel.fateVoided'), consumed: t('massBalance.panel.fateConsumed'),
        split: t('massBalance.panel.fateSplit'), consumed_not_kg: t('massBalance.panel.fateConsumedNotKg'), unexplained: t('massBalance.panel.fateUnexplained'),
    }
    const kids = new Map<string, Node[]>()
    for (const n of nodes) if (n.parent_key) kids.set(n.parent_key, [...(kids.get(n.parent_key) ?? []), n])
    const unit = root?.unit ?? 'kg'
    const date = (d: string | null) => (d ? formatDate(d, locale) : '')
    const batchHref = (n: Node) => (n.batch_kind === 'inbound' ? `/inbound/${n.batch_id}/edit` : `/output/${n.batch_id}/edit`)

    // 一个批次结点(根,或一条产出腿)下面:去向 → 喂进的单 → 事件
    function batchBody(at: Node): React.ReactNode {
        const children = kids.get(at.node_key) ?? []
        const fates = children.filter((c) => c.node_type === 'fate')
            .filter((c) => c.line_key === 'on_hand' || (num(c.x) ?? 0) !== 0)
            .sort((a, b) => FATE_ORDER.indexOf(a.line_key ?? '') - FATE_ORDER.indexOf(b.line_key ?? ''))
        const runs = children.filter((c) => c.node_type === 'run')
        const events = children.filter((c) => c.node_type === 'event')
        return (
            <ul className="ml-4 list-disc space-y-1" data-batch-body={at.batch_code ?? ''}>
                {fates.map((f) => (
                    <li key={f.node_key} data-fate={f.line_key}
                        className={f.line_key === 'unexplained' ? 'text-red-700 font-medium' : f.line_key === 'consumed_not_kg' ? 'text-amber-700' : ''}>
                        {fateText[f.line_key ?? ''] ?? f.line_key}: {fmtKg(f.qty)} {at.unit ?? unit}
                    </li>
                ))}
                {runs.map((r) => runItem(r))}
                {events.map((e) => (
                    <li key={e.node_key} data-event={e.line_key} className="text-[color:var(--brand-muted-text)]">
                        {e.line_key === 'pass_through' && t('massBalance.panel.eventPass', { code: e.run_code ?? '', qty: fmtKg(e.qty) })}
                        {e.line_key === 'reversed' && (
                            <>
                                {t('massBalance.panel.eventReversed', { code: e.run_code ?? '', qty: fmtKg(e.qty), date: date(e.reversed_at) })}
                                {e.corrected_by_run_code && <> · {t('massBalance.panel.correctedBy', { code: e.corrected_by_run_code })}</>}
                            </>
                        )}
                        {e.line_key === 'not_kg' && t('massBalance.panel.eventNotKg', { code: e.run_code ?? '' })}
                        {' '}{e.run_id && <Link href={`/operation/processing/${e.run_id}`} className="hover:underline app-link">→</Link>}
                    </li>
                ))}
            </ul>
        )
    }

    function runItem(r: Node): React.ReactNode {
        const children = kids.get(r.node_key) ?? []
        const outs = children.filter((c) => c.node_type === 'run_output')
        const losses = children.filter((c) => c.node_type === 'run_loss')
        const rem = children.filter((c) => c.node_type === 'run_remainder')
        const head = r.line_key === 'transfer'
            ? t('massBalance.panel.runTransfer', { code: r.run_code ?? '', date: date(r.process_date) })
            : t('massBalance.panel.run', { code: r.run_code ?? '', op: labels.op(r.operation_type_code), date: date(r.process_date) })
        return (
            <li key={r.node_key} data-run={r.run_code}>
                <span className="font-medium">{head}</span>{' '}
                {r.run_id && <Link href={`/operation/processing/${r.run_id}`} className="hover:underline app-link">→</Link>}
                {' · '}{t('massBalance.panel.share', { qty: fmtKg(r.qty) })}
                {r.corrects_run_code && <> · {t('massBalance.panel.corrects', { code: r.corrects_run_code })}</>}
                <ul className="ml-4 list-[circle] space-y-1 mt-1">
                    {outs.map((o) => (
                        <li key={o.node_key} data-output={o.batch_code}>
                            {t('massBalance.panel.output', { batch: o.batch_code ?? '', form: labels.form(o.form_code) })}{': '}{fmtKg(o.qty)} kg{' '}
                            <Link href={batchHref(o)} className="hover:underline app-link">→</Link>
                            {batchBody(o)}
                        </li>
                    ))}
                    {losses.map((l) => (
                        <li key={l.node_key} data-loss={l.loss_category_code}>
                            {t('massBalance.panel.loss', { category: labels.loss(l.loss_category_code), basis: labels.basis(l.loss_basis) })}: {fmtKg(l.qty)} kg
                        </li>
                    ))}
                    {rem.map((m) => (
                        <li key={m.node_key} data-remainder={m.line_key} className={m.line_key === 'open' ? 'text-amber-700' : ''}>
                            {t('massBalance.panel.remainder', { state: labels.remainder(m.line_key) })}: {fmtKg(m.qty)} kg
                        </li>
                    ))}
                </ul>
            </li>
        )
    }

    return (
        <section className="mt-8" data-panel="batch-balance">
            <h2 className="mb-1">{t('massBalance.panel.title')}</h2>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-2">{t('massBalance.panel.intro')}</p>
            {!root || (nodes.length <= 2 && (num(root.x) ?? 0) === 0)
                ? <p className="text-sm">{t('massBalance.panel.empty')}</p>
                : (
                    <div className="text-sm">
                        <p className="font-medium" data-received>{t('massBalance.panel.received')}: {fmtKg(root.x)} {unit}</p>
                        {batchBody(root)}
                    </div>
                )}
        </section>
    )
}
