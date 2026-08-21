'use client'

// EQP-2d(P1/P2):记一次保养或维修,以及那个【资本化判断】。
//
// 【P1 · 干活的日期必须敲进去,永不预填】equipment_maintenance.performed_on 的
// 列注释写着这句:一个悄悄填成"今天"的日期会把整条保养排程往后推,而没有任何
// 东西看得出来。所以【提交钮在日期为空时禁用】+【服务端独立拒空】,两层都是
// 机制(AGENTS.md 那条决定期间的日期永不默认)。表上的 NOT NULL 是第三层。
//
// 【P1 · 谁做的,是【一个选择】,不是三个格子】表上那条 performer_shape 说的是
// "从不两个,而且至少说出一个"。摆三个输入框让人自己悟出这条规矩,是把一条
// 数据库规矩当成用户的功课 —— 所以这里是一个三选一的开关,选中哪个才出现哪个
// 输入框。**于是那条 CHECK 经由这张表单撞不上** —— 那是对的(不要给一个
// 服务端保证会拒的动作画按钮),而它的句子仍然接好,留给直连那条路。
//
// ════════════════════════════════════════════════════════════════════════════
// 【P2 · 资本化是【人】的判断,而系统只答得了它的一半】
// 判据有两半:① 这次修理延长了寿命或提高了产能吗(人的判断,任何查询都做不出来);
// ② 花的钱够不够大(一个数)。**系统只答得了第二半,所以它只【建议】。**
// maintenance_settings 的表注把这件事写死了:可以提醒,不可以拒绝。
//
// 【那个建议【不在这张表单上算】】equipment_maintenance_advice 是那笔算术的
// 唯一实现,而它按【已存在的保养行】算。在表单里用 TS 先算一遍预览,就是本仓库
// 记过四次的那个 bug(化验影响预览、GrantRunner 假期公式、重估预览、
// /finance/payments)——【屏幕不许重新实现一条过账/判定规则】。
// 所以:**表单上摆的是那两个【阈值】与机器的记录成本(那笔算术的输入),
// 判词本身画在存下来之后的那一行上**,由视图算。一份实现,两个读者。
//
// 【P2 · 资本化那条路今天走不到底,而这件事写在表单上,不藏起来】
// capitalised_expense_id 要指着一笔【追加】的资本支出,而 record_expense 的追加支
// 在资产已投用时按名拒(ASSET_ALREADY_IN_SERVICE)。它的判据是
// `in_service_date IS NOT NULL` —— **一个【未来】的投用日照样拦**,
// FA-2026-0001 的 2027-01-01 今天就拦得住。所以这张表单【不画那个选择器】,
// 而是把这句话说出来,并点名那一刀。判断与理由照记 —— 它们是这张表要保存的东西,
// 而"钱走哪条路"是另一件事。
// ════════════════════════════════════════════════════════════════════════════
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { recordMaintenance } from './actions'

export type MaintRow = {
    id: string
    performed_on: string
    kind: string
    description: string
    capitalised: boolean
    capitalisation_reason: string | null
    performer: string
    expense_code: string | null
    // equipment_maintenance_advice 算出来的那三样(视图是唯一实现)
    work_cost_base: number | null
    pct_of_equipment_cost: number | null
    meets_threshold: boolean | null
}

export default function MaintenancePanel({
    assetId, rows, employees, suppliers, expenses, canEdit,
    inServiceDate, capitalisePct, capitaliseFloor, equipmentCostBase, baseCurrency,
}: {
    assetId: string
    rows: MaintRow[]
    employees: { id: string; label: string }[]
    suppliers: { id: string; label: string }[]
    expenses: { id: string; label: string }[]
    canEdit: boolean
    inServiceDate: string | null
    capitalisePct: number
    capitaliseFloor: number
    equipmentCostBase: number
    baseCurrency: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [open, setOpen] = useState(false)
    const [f, setF] = useState({
        performedOn: '', kind: 'service', description: '',
        performerKind: 'name' as 'employee' | 'supplier' | 'name',
        employeeId: '', supplierId: '', performerName: '',
        expenseId: '', capitalised: false, capitalisationReason: '', notes: '',
    })

    // 【提交钮的禁用条件,以及【为什么】—— 一起算,免得有分支只画了禁用】
    // 只挡表单【自己确定】的那几件:日期空、描述空、没选人。
    // 跨字段的库侧规矩(理由、约束)不在这里判 —— 让库拒,句子由约束名翻。
    const performerEmpty =
        (f.performerKind === 'employee' && !f.employeeId) ||
        (f.performerKind === 'supplier' && !f.supplierId) ||
        (f.performerKind === 'name' && !f.performerName.trim())
    const why = !f.performedOn ? t('equipment.maint.needDate')
        : !f.description.trim() ? t('equipment.maint.needDescription')
        : performerEmpty ? t('equipment.maint.needPerformer')
        : ''

    function submit() {
        setError(null)
        start(async () => {
            const r = await recordMaintenance({ assetId, ...f })
            if (r.error) { setError(r.error); return }
            setOpen(false)
            setF({ performedOn: '', kind: 'service', description: '', performerKind: 'name',
                   employeeId: '', supplierId: '', performerName: '', expenseId: '',
                   capitalised: false, capitalisationReason: '', notes: '' })
            router.refresh()
        })
    }

    return (
        <div className="mb-8">
            <div className="flex items-baseline gap-3 mb-2">
                <h2 className="text-lg font-medium">{t('equipment.maint.title')}</h2>
                {canEdit && (
                    <button type="button" onClick={() => setOpen(!open)} disabled={pending}
                            className="border border-gray-400 px-2 py-1 rounded text-xs hover:bg-gray-50 disabled:opacity-50">
                        {t('equipment.maint.add')}
                    </button>
                )}
            </div>
            {!canEdit && <p className="text-xs text-gray-500 mb-2">{t('equipment.needsProcessingEdit')}</p>}
            {error && <p className="text-red-600 text-xs mb-2">{error}</p>}

            {rows.length === 0 ? (
                <p className="text-sm text-gray-600 mb-2">{t('equipment.maint.none')}</p>
            ) : (
                <table className="border-collapse mb-2">
                    <thead><tr className="bg-gray-50">
                        <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('equipment.maint.colDate')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('equipment.maint.colKind')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('equipment.maint.colWhat')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('equipment.maint.colWho')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('equipment.maint.colCapital')}</th>
                    </tr></thead>
                    <tbody>
                        {rows.map((r) => (
                            <tr key={r.id}>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{r.performed_on}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{t('equipment.kind.' + r.kind)}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{r.description}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{r.performer}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">
                                    {/* 【人的判断在前,系统的建议在后】—— 两者是两件事,
                                        而把建议画得像判决,正是 maintenance_settings 表注
                                        要拦的那个误读。 */}
                                    <p>{r.capitalised ? t('equipment.maint.capYes') : t('equipment.maint.capNo')}</p>
                                    {r.capitalised && r.capitalisation_reason && (
                                        <p className="text-xs text-gray-600">{r.capitalisation_reason}</p>
                                    )}
                                    <p className="text-xs text-gray-500">
                                        {r.meets_threshold === null
                                            /* 【空不是"不达标"】没挂支出单(没花钱,或钱还没记),
                                               或者机器记录成本为 0 —— 视图注释里写着这两种。 */
                                            ? t('equipment.maint.adviceUnknown')
                                            : t(r.meets_threshold ? 'equipment.maint.adviceMet' : 'equipment.maint.adviceNotMet', {
                                                pct: String(r.pct_of_equipment_cost ?? '—'),
                                                need: String(capitalisePct),
                                                amount: String(r.work_cost_base ?? '—'),
                                                floor: String(capitaliseFloor),
                                              })}
                                    </p>
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}

            {open && canEdit && (
                <div className="border border-gray-400 rounded p-3 text-sm space-y-3 max-w-2xl">
                    <div className="flex flex-wrap gap-3 items-end">
                        <label className="block">
                            <span className="text-xs text-gray-600 block">{t('equipment.maint.date')}</span>
                            {/* 【没有 defaultValue,而且不许有】见本文件抬头。 */}
                            <input type="date" value={f.performedOn}
                                   onChange={(e) => setF({ ...f, performedOn: e.target.value })}
                                   className="border border-gray-400 rounded px-2 py-1 text-sm" />
                        </label>
                        <label className="block">
                            <span className="text-xs text-gray-600 block">{t('equipment.maint.kind')}</span>
                            <select value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value })}
                                    className="border border-gray-400 rounded px-2 py-1 text-sm">
                                <option value="service">{t('equipment.kind.service')}</option>
                                <option value="repair">{t('equipment.kind.repair')}</option>
                            </select>
                        </label>
                    </div>
                    <label className="block">
                        <span className="text-xs text-gray-600 block">{t('equipment.maint.what')}</span>
                        <input value={f.description} onChange={(e) => setF({ ...f, description: e.target.value })}
                               className="border border-gray-400 rounded px-2 py-1 text-sm w-full" />
                    </label>

                    {/* ── 谁做的:【一个选择】,不是三个格子 ─────────────────────── */}
                    <div>
                        <span className="text-xs text-gray-600 block mb-1">{t('equipment.maint.who')}</span>
                        <div className="flex gap-3 mb-1">
                            {/* 【三个标签写成静态键】拼出来的键漏一个,屏幕上会印出
                                键名本身而没有任何东西报错 —— check-i18n 存在的理由。
                                这里只有三个,静态写出来就不需要一条动态前缀规则。 */}
                            {([
                                ['name', t('equipment.maint.performerName')],
                                ['employee', t('equipment.maint.performerEmployee')],
                                ['supplier', t('equipment.maint.performerSupplier')],
                            ] as const).map(([k, label]) => (
                                <label key={k} className="flex items-center gap-1 text-sm">
                                    <input type="radio" name="performerKind" checked={f.performerKind === k}
                                           onChange={() => setF({ ...f, performerKind: k as 'employee' | 'supplier' | 'name' })} />
                                    {label}
                                </label>
                            ))}
                        </div>
                        {f.performerKind === 'name' && (
                            <input value={f.performerName} onChange={(e) => setF({ ...f, performerName: e.target.value })}
                                   placeholder={t('equipment.maint.performerNamePlaceholder')}
                                   className="border border-gray-400 rounded px-2 py-1 text-sm w-full" />
                        )}
                        {f.performerKind === 'employee' && (
                            <select value={f.employeeId} onChange={(e) => setF({ ...f, employeeId: e.target.value })}
                                    className="border border-gray-400 rounded px-2 py-1 text-sm w-full">
                                <option value="">{t('common.select')}</option>
                                {employees.map((e) => <option key={e.id} value={e.id}>{e.label}</option>)}
                            </select>
                        )}
                        {f.performerKind === 'supplier' && (
                            <select value={f.supplierId} onChange={(e) => setF({ ...f, supplierId: e.target.value })}
                                    className="border border-gray-400 rounded px-2 py-1 text-sm w-full">
                                <option value="">{t('common.select')}</option>
                                {suppliers.map((s) => <option key={s.id} value={s.id}>{s.label}</option>)}
                            </select>
                        )}
                    </div>

                    {/* ── 这次活的花费(可选)—— 它是资本化建议那笔算术的输入 ────── */}
                    <label className="block">
                        <span className="text-xs text-gray-600 block">{t('equipment.maint.expense')}</span>
                        <select value={f.expenseId} onChange={(e) => setF({ ...f, expenseId: e.target.value })}
                                className="border border-gray-400 rounded px-2 py-1 text-sm w-full">
                            <option value="">{t('equipment.maint.expenseNone')}</option>
                            {expenses.map((e) => <option key={e.id} value={e.id}>{e.label}</option>)}
                        </select>
                        <span className="text-xs text-gray-500 block mt-1">{t('equipment.maint.expenseHint')}</span>
                    </label>

                    {/* ── 资本化判断 ─────────────────────────────────────────── */}
                    <div className="border-t border-gray-200 pt-2">
                        <label className="flex items-start gap-2">
                            <input type="checkbox" checked={f.capitalised} className="mt-1"
                                   onChange={(e) => setF({ ...f, capitalised: e.target.checked })} />
                            <span>
                                <span className="block">{t('equipment.maint.capitalise')}</span>
                                <span className="block text-xs text-gray-600">{t('equipment.maint.capitaliseWhat')}</span>
                            </span>
                        </label>
                        {/* 【建议:两个阈值 + 这台机器的记录成本】—— 判词本身由
                            equipment_maintenance_advice 在存下来之后算(一份实现)。 */}
                        <p className="text-xs text-gray-600 mt-1">
                            {t('equipment.maint.thresholdHint', {
                                pct: String(capitalisePct),
                                floor: String(capitaliseFloor),
                                cost: String(equipmentCostBase),
                                ccy: baseCurrency,
                            })}
                        </p>
                        {f.capitalised && (
                            <label className="block mt-2">
                                <span className="text-xs text-gray-600 block">{t('equipment.maint.reason')}</span>
                                <input value={f.capitalisationReason}
                                       onChange={(e) => setF({ ...f, capitalisationReason: e.target.value })}
                                       className="border border-gray-400 rounded px-2 py-1 text-sm w-full" />
                                {/* 【说清为什么要理由,而不只是拒绝】—— P2 的原话。 */}
                                <span className="text-xs text-gray-600 block mt-1">{t('equipment.maint.reasonWhy')}</span>
                            </label>
                        )}
                        {f.capitalised && (
                            /* 【今天走不到底,说出来,不藏起来】见本文件抬头。 */
                            <p className="text-xs text-amber-700 mt-2">
                                {inServiceDate
                                    ? t('equipment.maint.capitalInServiceBlocked', { date: inServiceDate })
                                    : t('equipment.maint.capitalNotWiredYet')}
                            </p>
                        )}
                    </div>

                    <div className="flex gap-2 items-center">
                        <button type="button" disabled={pending || why !== ''} onClick={submit}
                                className="border border-gray-600 bg-gray-800 text-white px-3 py-1 rounded text-xs disabled:opacity-50">
                            {t('common.save')}
                        </button>
                        <button type="button" disabled={pending} onClick={() => { setOpen(false); setError(null) }}
                                className="border border-gray-400 px-3 py-1 rounded text-xs hover:bg-gray-50 disabled:opacity-50">
                            {t('common.cancel')}
                        </button>
                        {/* 【禁用了就把理由摆在旁边】—— 一个按不下去又不说为什么的
                            按钮读起来像是坏了(AssetActions 立的规矩)。 */}
                        {why && <span className="text-xs text-gray-600">{why}</span>}
                    </div>
                </div>
            )}
        </div>
    )
}
