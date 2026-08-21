// app/finance/assets/[id]/page.tsx
// EQP-1c-b(P4):一台机器的卡片。它要回答【关于这一台】的五个问题:
//   1. 到目前为止它花了多少,分别来自哪几张单据;
//   2. 是哪一条采购单行买的它;
//   3. 那张单上还有多少定金没冲抵;
//   4. 投用了没有;
//   5. 要投用还差什么。
//
// 【每一处"没有值"都要说清是哪一种没有】——「尚未投用」不是「没有成本」,
// 两者也都不是一个空白。这是 lib/permissions.ts 存在的全部理由的推广:
// null 在这套系统里本来就有含义,所以缺席必须被【命名】。
//
// 【跨模块的读:采购单行】purchase_order_lines 的门是 module.purchasing.view,
// 而本页的门是 module.finance.view。一个只有财务权限的读者查它会得到【零行】——
// 而"没有采购单行"与"你看不到采购单行"是两件完全不同的事(OPS-14 那条
// "跨模块的行会无声消失")。所以这里【先问权限,再解释空结果】。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency } from '@/lib/currency'
import { getTranslations } from '@/lib/i18n/server'
import { formatAmount } from '@/lib/format'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import Subnav from '../../Subnav'
import AssetActions from '../AssetActions'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function AssetPage({ params }: { params: Promise<{ id: string }> }) {
    const denied = await requireModule(MOD.finance)
    if (denied) return denied
    const { id } = await params

    const supabase = await createClient()
    const t = await getTranslations()
    const baseCurrency = await getBaseCurrency()
    const canEdit = await can('module.finance.edit')
    // 【先问,再解释】—— 空结果的含义取决于这一句的答案。
    const canSeePurchasing = await can('module.purchasing.view')

    const assetRes = await supabase.from('fixed_assets')
        .select('id, code, description, category, acquisition_date, in_service_date, cost_ccy, currency, fx_rate, cost_base, useful_life_months, residual_base, status, expense_id, notes')
        .eq('id', id).maybeSingle()
    const asset = assetRes.data
    if (!asset) notFound()

    const [entriesRes, deprRes, lineRes] = await Promise.all([
        // 成本明细 + 它那笔支出。【已冲销的那些行要留着但标出来】——
        // EQP-1b-iii 之后它们不再计入 cost_base,而"它曾经在这里"是审计痕迹。
        supabase.from('fixed_asset_cost_entries')
            .select('id, amount_base, amount_ccy, currency, created_at, expense_id, expenses(code, expense_date, status, notes)')
            .eq('asset_id', id).order('created_at'),
        supabase.from('fixed_asset_depreciation')
            .select('amount_base, period_end').eq('asset_id', id),
        // 【读遮蔽视图,不读表】—— purchase_order_lines 是遮蔽表,而
        // estimated_amount_ccy 【正是被扣住的三列之一】,直接查表 → 42501。
        // 这一处与开支表单那一处是【同一个缺陷的两个实例】:走查报的是那一个,
        // 而它是这一个 —— 记录完开支之后落地的正是本页。
        // 【视图上不做 embed】采购单表头另查一次,在 TS 里拼(本仓库既有做法)。
        canSeePurchasing
            ? supabase.from('purchase_order_lines_masked')
                .select('id, line_no, purchase_order_id, estimated_amount_ccy')
                .eq('asset_id', id).maybeSingle()
            : Promise.resolve({ data: null, error: null }),
    ])

    const entries = mustRows(entriesRes)
    const accum = mustRows(deprRes).reduce((s, d) => s + Number(d.amount_base ?? 0), 0)
    const lineRaw = lineRes.data as {
        id: string; line_no: number; purchase_order_id: string; estimated_amount_ccy: number | null
    } | null
    const headRes = lineRaw
        ? await supabase.from('purchase_orders_masked')
            .select('code, status, approval_status, currency').eq('id', lineRaw.purchase_order_id).maybeSingle()
        : { data: null, error: null }
    const line = lineRaw
        ? { ...lineRaw, purchase_orders: headRes.data as
              { code: string; status: string; approval_status: string; currency: string } | null }
        : null

    // 那张单上还有多少定金没冲抵 —— 【问数据库,不自己算】
    const poStatusRes = line
        ? await supabase.from('purchase_order_status')
            .select('prepaid_base, prepaid_applied_base, prepaid_remaining_base')
            .eq('po_id', line.purchase_order_id).maybeSingle()
        : { data: null, error: null }
    const poStatus = poStatusRes.data

    const live = entries.filter((e) => (e.expenses as { status?: string } | null)?.status !== 'reversed')
    const nbv = Math.round((Number(asset.cost_base) - accum) * 100) / 100

    // 【要投用还差什么】—— 逐条判,逐条说。set_asset_in_service 的三道拒绝是
    // ASSET_HAS_NO_COST / ASSET_ALREADY_IN_SERVICE / ASSET_DISPOSED,这里一一对应。
    const blockers: string[] = []
    if (Number(asset.cost_base) === 0) blockers.push(t('assets.detail.blockerNoCost'))
    if (asset.in_service_date) blockers.push(t('assets.detail.blockerAlreadyInService', { 0: asset.in_service_date }))
    if (asset.status !== 'active') blockers.push(t('assets.detail.blockerDisposed'))

    return (
        <div className="p-6">
            <Subnav />
            <div className="flex items-baseline gap-3 mb-1">
                <h1 className="text-2xl font-semibold font-mono">{asset.code}</h1>
                <span className="text-lg">{asset.description}</span>
            </div>
            <p className="text-sm text-gray-600 mb-6">
                {t('assets.category.' + asset.category)} · {t('assets.detail.acquired')} {asset.acquisition_date}
                {' · '}
                {asset.expense_id
                    ? <Link href={`/finance/expenses/${asset.expense_id}`} className="text-blue-600 underline">{t('assets.detail.bornFromExpense')}</Link>
                    : <span className="text-gray-500">{t('assets.detail.bornAsMasterData')}</span>}
            </p>

            {/* ── 四个数,每一个都带着它缺席时的说法 ─────────────────────────── */}
            <div className="grid grid-cols-4 gap-4 mb-8">
                <Stat label={t('assets.detail.costSoFar')}
                    value={Number(asset.cost_base) === 0
                        ? t('assets.detail.noCostYet')
                        : formatAmount(Number(asset.cost_base), baseCurrency)} />
                <Stat label={t('assets.detail.accumDepr')}
                    value={asset.in_service_date
                        ? formatAmount(accum, baseCurrency)
                        : t('assets.detail.notInServiceYet')} />
                <Stat label={t('assets.detail.nbv')}
                    value={Number(asset.cost_base) === 0
                        ? t('assets.detail.noCostYet')
                        : formatAmount(nbv, baseCurrency)} />
                <Stat label={t('assets.detail.inService')}
                    value={asset.in_service_date ?? t('assets.detail.notInServiceYet')} />
            </div>

            {/* ── 成本从哪几张单据来 ──────────────────────────────────────── */}
            <h2 className="text-lg font-medium mb-2">{t('assets.detail.costEntries')}</h2>
            {entries.length === 0 ? (
                <p className="text-sm text-gray-600 mb-6">{t('assets.detail.noCostEntries')}</p>
            ) : (
                <table className="border-collapse mb-6">
                    <thead><tr className="bg-gray-50">
                        <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('assets.detail.colExpense')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('assets.detail.colDate')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right text-sm">{t('assets.detail.colAmountCcy')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right text-sm">{t('assets.detail.colAmountBase')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('assets.detail.colState')}</th>
                    </tr></thead>
                    <tbody>
                        {entries.map((e) => {
                            const exp = e.expenses as { code: string; expense_date: string; status: string } | null
                            const reversed = exp?.status === 'reversed'
                            return (
                                <tr key={e.id} className={reversed ? 'text-gray-400 line-through' : ''}>
                                    <td className="border border-gray-300 px-3 py-2 font-mono text-sm">
                                        <Link href={`/finance/expenses/${e.expense_id}`} className="text-blue-600 underline">{exp?.code ?? '—'}</Link>
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 text-sm">{exp?.expense_date ?? '—'}</td>
                                    <td className="border border-gray-300 px-3 py-2 text-right text-sm">
                                        {e.amount_ccy !== null ? formatAmount(Number(e.amount_ccy), String(e.currency)) : '—'}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 text-right text-sm">{formatAmount(Number(e.amount_base), baseCurrency)}</td>
                                    <td className="border border-gray-300 px-3 py-2 text-sm">
                                        {/* 【已冲销的行留着但不算数】EQP-1b-iii:它退回了成本,
                                            而这一行是"它曾经在这里"的痕迹。 */}
                                        {reversed ? t('assets.detail.entryReversed') : t('assets.detail.entryLive')}
                                    </td>
                                </tr>
                            )
                        })}
                    </tbody>
                </table>
            )}
            {entries.length > 0 && (
                <p className="text-xs text-gray-600 -mt-4 mb-6">
                    {t('assets.detail.entriesFootnote', { live: live.length, all: entries.length })}
                </p>
            )}

            {/* ── 是哪一条采购单行买的它,以及那张单的定金 ─────────────────── */}
            <h2 className="text-lg font-medium mb-2">{t('assets.detail.boughtBy')}</h2>
            {!canSeePurchasing ? (
                /* 【不是"没有",是"你看不到"】—— 两者的下一步不一样。 */
                <p className="text-sm text-gray-600 mb-6">{t('assets.detail.poRestricted')}</p>
            ) : !line ? (
                <p className="text-sm text-gray-600 mb-6">{t('assets.detail.noPoLine')}</p>
            ) : (
                <div className="mb-6 text-sm space-y-1">
                    <p>
                        <Link href={`/purchasing/orders/${line.purchase_order_id}`} className="text-blue-600 underline font-mono">
                            {line.purchase_orders?.code ?? '—'}
                        </Link>
                        <span className="ml-2 text-gray-600">{t('assets.detail.lineNo', { 0: line.line_no })}</span>
                    </p>
                    {poStatus && (
                        <p className="text-gray-700">
                            {t('assets.detail.depositLine', {
                                paid: formatAmount(Number(poStatus.prepaid_base ?? 0), baseCurrency),
                                applied: formatAmount(Number(poStatus.prepaid_applied_base ?? 0), baseCurrency),
                                remaining: formatAmount(Number(poStatus.prepaid_remaining_base ?? 0), baseCurrency),
                            })}
                        </p>
                    )}
                    {poStatus && Number(poStatus.prepaid_remaining_base ?? 0) > 0 && (
                        <p className="text-gray-600">{t('assets.detail.depositReleaseHint')}</p>
                    )}
                </div>
            )}

            {/* ── 要投用还差什么 ─────────────────────────────────────────── */}
            <h2 className="text-lg font-medium mb-2">{t('assets.detail.commissioning')}</h2>
            {blockers.length === 0 ? (
                <p className="text-sm text-green-700 mb-3">{t('assets.detail.readyToCommission')}</p>
            ) : (
                <ul className="text-sm text-gray-700 mb-3 list-disc pl-5">
                    {blockers.map((b) => <li key={b}>{b}</li>)}
                </ul>
            )}
            <AssetActions assetId={asset.id} code={asset.code} status={asset.status}
                inServiceDate={asset.in_service_date} acquisitionDate={asset.acquisition_date}
                canEdit={canEdit} bankAccounts={['1000', '1010']} />
        </div>
    )
}

function Stat({ label, value }: { label: string; value: string }) {
    return (
        <div className="border border-gray-200 rounded-lg p-3">
            <p className="text-xs text-gray-600">{label}</p>
            <p className="text-lg mt-1">{value}</p>
        </div>
    )
}
