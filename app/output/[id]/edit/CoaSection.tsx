// app/output/[id]/edit/CoaSection.tsx
// MES-6b-2(2026-10-15,MES-0 Q67 · Q68;MES-6b Step 0 Q10–Q14 · Q29–Q32,Tim):产出批页上的【分析证书】一块 —— 自己取数(与 QualityPanel 同形)。
//   ① 来料化学确定度(N38):output_batch_chemistry_certainty —— 最弱的那一张进料叶子,与各档几张;
//   ② 这一批的证书(coa_rows):号(点进证书页)、给谁(点了单就是客户名与单号)、状态、签发人与时刻、下载存下的那一份(?coa=)、
//      作废的理由与替代它的那一张、在等的作废申请;
//   ③ 签发:选"不点名"或一张预留过 / 发过这一批的销售单 → 那一项此刻的拒绝清单(coa_certificate_data 的 blockers,一句句说成人话)、
//      预览(照此刻的数据,带水印,不是证书)、签发钮(action.issue_coa —— 缺码看得见、按不动、说出码;有拒绝时按不动、说出为什么)。
//   ④ 作废:一张给 CFO 的申请(warehouse_requests 的 coa_void),每一张已签发的证书一颗 —— 批准之前什么都不发生(Q32)。
//   【门】这一页的门是 module.output.view;证书表与读面同一个码,所以读得到这一页的人读得到这一块。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows, mustOne } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { formatAuditStamp } from '@/lib/dates'
import { localizeCoaError } from '@/app/output/coa/coaErrorCodes'
import { COA_ROW_COLUMNS, type CoaRow, type CoaSnapshot } from '@/app/output/coa/coaTypes'
import CoaTable, { type CoaListRow } from '@/app/quality/coa/CoaTable'
import CoaIssueForm, { type CoaChoice } from './CoaIssueForm'
import { coaUnrenderable } from '@/app/output/coa/renderCoa'

export default async function CoaSection({ batchId }: { batchId: string }) {
    const t = await getTranslations()
    const supabase = await createClient()
    const [rowsRes, chemRes, resvRes, shipRes, canIssue] = await Promise.all([
        supabase.from('coa_rows').select(COA_ROW_COLUMNS).eq('output_batch_id', batchId).order('issued_at', { ascending: false }),
        supabase.from('output_batch_chemistry_certainty')
            .select('certainty, inbound_leaves, leaves_single_known, leaves_mixed, leaves_not_recorded, leaves_unknown_pending')
            .eq('output_batch_id', batchId).maybeSingle(),
        supabase.from('sales_order_reservations').select('sales_order_lines ( sales_order_id, sales_orders ( code ) )').eq('output_batch_id', batchId),
        supabase.from('shipment_lines').select('sales_order_lines ( sales_order_id, sales_orders ( code ) )').eq('output_batch_id', batchId),
        can('action.issue_coa'),
    ])
    const rows = mustRows(rowsRes, 'coa_rows') as unknown as CoaRow[]
    const chem = mustOne(chemRes, 'output_batch_chemistry_certainty') as {
        certainty: string; inbound_leaves: number; leaves_single_known: number; leaves_mixed: number; leaves_not_recorded: number; leaves_unknown_pending: number
    } | null
    // 一张单经它的明细行连到这一批 —— 读不到销售单(没有 module.sales.view)的读者只剩"不点名"那一项
    type Link_ = { sales_order_lines: { sales_order_id: string; sales_orders: { code: string } | null } | null }
    const orders = new Map<string, string>()
    for (const r of [...mustRows(resvRes, 'sales_order_reservations'), ...mustRows(shipRes, 'shipment_lines')] as unknown as Link_[]) {
        const l = r.sales_order_lines
        if (l?.sales_order_id && l.sales_orders?.code) orders.set(l.sales_order_id, l.sales_orders.code)
    }
    const candidates: { id: string | null; label: string }[] = [
        { id: null, label: t('coa.panel.noOrder') },
        ...[...orders.entries()].sort((a, b) => a[1].localeCompare(b[1])).map(([id, code]) => ({ id, label: code })),
    ]
    // 每一项此刻的拒绝清单(与签发时问的是同一支判据)
    // ★ MES-7a-1(F9,MES-7a Step 0 Q8):签发人 —— 与 issue_coa 冻进快照、路由在铸号之前问到的是【同一支】coa_issuer()。
    //   持码的人在按下之前就读到"You will be named as <名字>, <职位>";解析不出来(不是员工 / 没有职位)就是那一句拒绝,签发钮按不动。
    //   不持码的人不问(那支函数按码拒;签发钮本来就由 PermissionGate 点名 action.issue_coa)。
    let issuer: { name: string; position: string } | null = null
    let issuerProblem: string | null = null
    if (canIssue) {
        const { data, error } = await supabase.rpc('coa_issuer')
        if (error) issuerProblem = await localizeCoaError(error.message)
        else issuer = { name: String((data as { name: string }).name), position: String((data as { position: string }).position) }
    }
    const choices: CoaChoice[] = await Promise.all(candidates.map(async (c) => {
        const { data, error } = await supabase.rpc('coa_certificate_data', { p_output_batch_id: batchId, p_sales_order_id: c.id ?? undefined })
        if (error) return { id: c.id, label: c.label, blockers: [await localizeCoaError(error.message)] }
        const snap = data as unknown as CoaSnapshot
        const blockers = await Promise.all((snap.blockers ?? []).map((b) => localizeCoaError(b)))
        // ★ F9:纸上会印的每一个字 —— 连同签发人的名字与职位 —— 先过字体覆盖守卫(路由在铸号之前问的是同一句)。
        //   画不出来的那一句在按下之前就摆出来,不是号铸了之后才渲染失败。
        if (issuer) {
            const font = coaUnrenderable({ ...snap, issuer })
            if (font) blockers.push(font)
        }
        return { id: c.id, label: c.label, blockers }
    }))

    const listRows: CoaListRow[] = rows.map((r) => ({
        id: r.id, code: r.code, status: r.status, statusLabel: t('coa.status.' + r.status), batchId: r.output_batch_id, batchCode: r.batch_code,
        issuedTo: r.sales_order_code ? `${r.customer_name ?? '—'} · ${r.sales_order_code}` : t('coa.panel.noOrder'),
        issued: formatAuditStamp(r.issued_at) ?? '—',
        issuedBy: r.issued_by_name ? `${r.issued_by_name}${r.issued_by_position ? `, ${r.issued_by_position}` : ''}` : '',
        replacedBy: r.replaced_by_code, hasBytes: r.has_bytes, openRequestLabel: r.open_request_label,
    }))
    const certaintyKey = chem ? `coa.certainty.${chem.certainty}` : 'coa.certainty.not_recorded'
    const knownCertainty = chem && ['single_known', 'mixed', 'unknown_pending', 'not_recorded'].includes(chem.certainty)

    return (
        <section className="mt-8" data-section="coa">
            <h2 className="mb-1">{t('coa.panel.title')}</h2>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-3">{t('coa.panel.intro')}</p>

            <p className="text-sm mb-3" data-field="feed-chemistry">
                <span className="text-[color:var(--brand-muted-text)]">{t('coa.panel.feedChemistry')}: </span>
                <span className="font-medium">{knownCertainty ? t(certaintyKey) : chem?.certainty}</span>
                {chem && chem.inbound_leaves > 0 ? (
                    <span className="text-[color:var(--brand-muted-text)]">{' '}{t('coa.panel.feedBreakdown', {
                        n: chem.inbound_leaves, single: chem.leaves_single_known, mixed: chem.leaves_mixed,
                        none: chem.leaves_not_recorded, unknown: chem.leaves_unknown_pending,
                    })}</span>
                ) : (
                    <span className="text-[color:var(--brand-muted-text)]">{' '}{t('coa.panel.noFeed')}</span>
                )}
            </p>

            <div className="mb-4">
                <CoaTable rows={listRows} empty={t('coa.panel.none')} canIssue={canIssue} hideBatch />
            </div>

            <CoaIssueForm batchId={batchId} choices={choices} canIssue={canIssue} issuer={issuer} issuerProblem={issuerProblem} />
        </section>
    )
}
