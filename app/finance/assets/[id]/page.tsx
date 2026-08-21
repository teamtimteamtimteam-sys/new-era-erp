// app/finance/assets/[id]/page.tsx
// EQP-1c-b(P4):一台机器的卡片。它要回答【关于这一台】的五个问题:
//   1. 到目前为止它花了多少,分别来自哪几张单据;
//   2. 是哪一条采购单行买的它;
//   3. 那张单上还有多少定金没冲抵;
//   4. 投用了没有;
//   5. 要投用还差什么。
//
// 【EQP-2d 在这一页【末尾】接上了设备的一生 —— 保养、停机、保养间隔三节。】
// 位置是刻意的:上面五节是 Tim 已经走过的,新的三节全部落在 AssetActions
// 【之后】,所以那五节的顺序、措辞、渲染一个字节都没动。
// 读法顺着这台机器的生命走:主数据 → 成本 → 从哪买的 → 投用 → 投用之后。
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
import { mustRows, mustCount } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import Subnav from '../../Subnav'
import AssetActions from '../AssetActions'
import MaintenancePanel from './MaintenancePanel'
import DowntimePanel, { type DowntimeRow } from './DowntimePanel'
import ServiceIntervalPanel, { type IntervalRow } from './ServiceIntervalPanel'
import { getLocale } from '@/lib/i18n/server'
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
    // EQP-2d:保养/停机/间隔【写】在加工侧(三张表的 insert 策略都是
    // module.processing.edit)。本页的门是 module.finance.view —— 也就是说
    // 一个只有财务的人【看得见这台机器,却记不了保养】。那不是 bug,是那三张
    // 表刻意的分工(机器卡在财务,干活的人在加工)。所以这里【问一次,并在
    // 三块面板上各说一句】,而不是让按钮无声地消失。
    const canRecordEquipment = await can('module.processing.edit')
    // 员工选择器读 employees_masked,而它的谓词是
    // has_permission('module.hr.view') OR id = current_user_employee() ——
    // 一个没有 HR 权限的读者查它【至多只看得见自己那一行】。
    // 「没有员工」与「你看不到员工」是两件事(OPS-14 那条),所以先问权限:
    // 没有就【不提供员工这个选项】,并说出理由,而不是给一个空下拉。
    const canSeeEmployees = await can('module.hr.view')
    const locale = await getLocale()

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

    // ══════════════════════════════════════════════════════════════════════
    // EQP-2d:投用【之后】的三节 —— 保养、停机、保养间隔。
    //
    // 【每一张表在写查询【之前】都对过遮蔽清单,不是之后】(两刀之前那次 42 分钟的
    // 生产故障就是"先写、跑通了、才发现读的是遮蔽表"):
    //   * equipment_maintenance / equipment_downtime / equipment_service_intervals
    //     —— 都【不是】遮蔽表(没有 _masked 伴生视图,表级 SELECT 授权),直读;
    //   * equipment_service_status / equipment_maintenance_advice —— 属主权限视图,
    //     GRANT SELECT TO authenticated,直读;
    //   * maintenance_settings —— 非遮蔽,读的门是 finance.view OR processing.view;
    //   * **processing_runs 是遮蔽表** → 读 processing_runs_masked;
    //   * **employees 是遮蔽表** → 读 employees_masked,而它自带 HR 的门(见上);
    //   * suppliers / expenses —— 实测都没有 _masked 伴生视图,直读。
    // ══════════════════════════════════════════════════════════════════════
    const [statusRes, maintRes, adviceRes, downRes, settingsRes] = await Promise.all([
        supabase.from('equipment_service_status')
            .select('interval_id, monitored, service_kind, disposition, interval_kg, lead_kg, interval_days, lead_days, last_service_date, never_serviced, baseline_date, kg_since, days_since, unattributed_runs_in_window, is_due, due_reason, is_approaching, approaching_reason')
            .eq('equipment_id', id),
        supabase.from('equipment_maintenance')
            .select('id, performed_on, kind, description, capitalised, capitalisation_reason, performed_by_employee_id, performed_by_supplier_id, performed_by_name, expense_id')
            .eq('equipment_id', id).order('performed_on', { ascending: false }),
        supabase.from('equipment_maintenance_advice')
            .select('maintenance_id, work_cost_base, pct_of_equipment_cost, meets_threshold')
            .eq('equipment_id', id),
        supabase.from('equipment_downtime')
            .select('id, started_at, ended_at, reason, notes, duration')
            .eq('equipment_id', id).order('started_at', { ascending: false }),
        supabase.from('maintenance_settings')
            .select('capitalise_pct_of_cost, capitalise_floor_base').maybeSingle(),
    ])
    const statusRows = mustRows(statusRes, 'equipment_service_status')
    const maintRaw = mustRows(maintRes, 'equipment_maintenance')
    const downRows = mustRows(downRes, 'equipment_downtime')
    const adviceById = new Map<string, { work_cost_base: number | null; pct_of_equipment_cost: number | null; meets_threshold: boolean | null }>()
    for (const a of mustRows(adviceRes, 'equipment_maintenance_advice') as {
            maintenance_id: string; work_cost_base: number | null
            pct_of_equipment_cost: number | null; meets_threshold: boolean | null }[]) {
        adviceById.set(a.maintenance_id, a)
    }

    // 【窗口【左边】那个洞有多大】—— equipment_service_status 的
    // unattributed_runs_in_window 只量【窗口之内】没人归属的炉数;它量不到
    // 取得日【之前】的历史,而 EQP-2c 的视图注释把这件事写得很清楚。
    // FA-2026-0001 恰恰全部落在左边(取得日 8-21,十三炉全在 6-10…8-16),
    // 于是那一列读 0 而盲区最大 —— **只看那一列,这台机器会一句诚实提示都没有。**
    // 所以这里另查一次:取得日之前、谁都没归属的在册加工有几炉。
    // 【只在有间隔行时才查】没有间隔行的机器根本不显示读数,这个数也就没有用处。
    const anyMonitored = statusRows.some((r) => r.monitored)
    let runsBeforeAcquisition = 0
    if (anyMonitored) {
        const priorRes = await supabase.from('processing_runs_masked')
            .select('id', { count: 'exact', head: true })
            .is('equipment_id', null).is('deleted_at', null)
            .eq('status', 'committed').lt('process_date', asset.acquisition_date)
        // 【失败不是空集】—— 查不到与"没有"在屏幕上一模一样,而这个数正是用来
        // 说"这个读数不完整"的;它自己静默失败会让那句话消失(mustCount 的理由)。
        runsBeforeAcquisition = mustCount(priorRes, 'processing_runs_masked prior runs')
    }

    // 三个选择器。【员工那一支挂在 HR 的门上】—— 见上面 canSeeEmployees 的注释。
    const [empRes, supRes, expRes] = await Promise.all([
        canSeeEmployees
            ? supabase.from('employees_masked').select('id, code, legal_name')
                .is('deleted_at', null).order('code').limit(200)
            : Promise.resolve({ data: [], error: null }),
        supabase.from('suppliers').select('id, code, legal_name')
            .is('deleted_at', null).order('code').limit(200),
        // 【这次活花了多少钱,是资本化建议那笔算术的【输入】】——
        // equipment_maintenance_advice 从 expense_id 指着的那张【已过账】支出上读
        // amount_base;没有它,meets_threshold 永远是 NULL,建议永远说不出话。
        supabase.from('expenses').select('id, code, expense_date, amount_base, status')
            .eq('status', 'posted').order('expense_date', { ascending: false }).limit(100),
    ])
    const employees = (mustRows(empRes, 'employees_masked') as { id: string; code: string; legal_name: string }[])
        .map((e) => ({ id: e.id, label: `${e.code} · ${e.legal_name}` }))
    const suppliers = (mustRows(supRes, 'suppliers') as { id: string; code: string; legal_name: string }[])
        .map((x) => ({ id: x.id, label: `${x.code} · ${x.legal_name}` }))
    const expenseOpts = (mustRows(expRes, 'expenses') as
            { id: string; code: string; expense_date: string; amount_base: number }[])
        .map((e) => ({ id: e.id, label: `${e.code} · ${e.expense_date} · ${formatAmount(Number(e.amount_base), baseCurrency)}` }))
    const empName = new Map(employees.map((e) => [e.id, e.label]))
    const supName = new Map(suppliers.map((x) => [x.id, x.label]))

    const maintRows = (maintRaw as {
        id: string; performed_on: string; kind: string; description: string
        capitalised: boolean; capitalisation_reason: string | null
        performed_by_employee_id: string | null; performed_by_supplier_id: string | null
        performed_by_name: string | null; expense_id: string | null }[]).map((m) => {
        const adv = adviceById.get(m.id)
        return {
            id: m.id, performed_on: m.performed_on, kind: m.kind, description: m.description,
            capitalised: m.capitalised, capitalisation_reason: m.capitalisation_reason,
            // 【谁做的:三种来源,认不出的那一种要说出来,不要留白】
            // 员工那一支在没有 HR 权限时解析不到 —— 那是「受限」,不是「没填」。
            performer: m.performed_by_employee_id
                ? (empName.get(m.performed_by_employee_id) ?? t('common.restricted'))
                : m.performed_by_supplier_id
                ? (supName.get(m.performed_by_supplier_id) ?? t('common.restricted'))
                : (m.performed_by_name ?? '—'),
            expense_code: null,
            work_cost_base: adv?.work_cost_base ?? null,
            pct_of_equipment_cost: adv?.pct_of_equipment_cost ?? null,
            meets_threshold: adv?.meets_threshold ?? null,
        }
    })

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

            {/* ══ EQP-2d:投用【之后】的一生 ═══════════════════════════════════
                三节全部落在这里 —— AssetActions 之后 —— 所以上面 Tim 已经走过的
                五节一个字节都没动。顺序跟着人的问题走:
                「这台机器该保养了吗」→「它停过没有」→「我们是怎么盯它的」。 */}
            <div className="border-t border-gray-200 mt-8 pt-6">
                <ServiceIntervalPanel
                    assetId={asset.id}
                    rows={statusRows as unknown as IntervalRow[]}
                    acquisitionDate={asset.acquisition_date}
                    runsBeforeAcquisition={runsBeforeAcquisition}
                    canEdit={canRecordEquipment} />
                <MaintenancePanel
                    assetId={asset.id}
                    rows={maintRows}
                    employees={employees}
                    suppliers={suppliers}
                    expenses={expenseOpts}
                    canEdit={canRecordEquipment}
                    inServiceDate={asset.in_service_date}
                    capitalisePct={Number(settingsRes.data?.capitalise_pct_of_cost ?? 0)}
                    capitaliseFloor={Number(settingsRes.data?.capitalise_floor_base ?? 0)}
                    equipmentCostBase={Number(asset.cost_base)}
                    baseCurrency={baseCurrency} />
                <DowntimePanel
                    assetId={asset.id}
                    rows={downRows as unknown as DowntimeRow[]}
                    canEdit={canRecordEquipment}
                    locale={locale} />
                {/* 【员工那个选项为什么可能不在】—— 说出来,不要让人以为下拉坏了。 */}
                {!canSeeEmployees && (
                    <p className="text-xs text-gray-500">{t('equipment.maint.employeesRestricted')}</p>
                )}
            </div>
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
