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
// 【P2 · 那条路【现在走得通了】—— CAPEX-1,2026-08-29】
// 原文写着"资本化那条路今天走不到底",理由是 record_expense 的追加支在资产已投用时
// 一律按名拒(ASSET_ALREADY_IN_SERVICE)。**那条一律拒已经换成一条窄的**:
// 经一条【标了资本化并写明理由】的维修记录,就加得上去(政策 4.7,Tim 2026-08-24)。
// 于是 capitalised_expense_id 这一列终于有人写了 —— 就是下面那个按钮写的。
// 【判断仍然在前,钱在后】先标资本化 + 写理由(表上那条 CHECK 逼着),
// 才谈得上资本化那笔钱;按钮只对【已标资本化、且还没有资本化过】的行出现。
// ════════════════════════════════════════════════════════════════════════════
//
// ★ CONV-9(2026-09-04):那张只读的保养记录表转成 DataTable。
//   【为什么它仍然是 DataTable,而不是 EditableTable】最后一格挂着
//   `CapitaliseControl` —— 一个【自带状态机】的写库控件,而表的其余部分彻底只读。
//   Tim 在 CONV-8 Q3 的裁定就是这个形状:EditableTable 存在的三件事(行级编辑态、
//   脏值追踪、逐行保存)这个控件自己全都有,再套一层就是两个状态机管同一行。
//   判据是【谁拥有那个状态】,不是【格子里有没有出现一个 <input>】。
//
//   ★【顺带照出一处结构缺陷,本刀修了】★ 转换前这张表的表头是 **5 个 <th>**,
//     而每一行是 **6 个 <td>**(最后那个资本化按钮列没有表头)。
//     也就是说表体比表头宽一列 —— 一张这样的表在读屏器上对不齐。
//     DataTable 的契约里每一列都必须有 header,所以它现在有了(留空字符串,
//     与转换前的视觉一致);这不是本刀引入的改动,是本刀【无法不修】的。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { recordMaintenance, capitaliseMaintenance } from './actions'

export type MaintRow = {
    id: string
    performed_on: string
    kind: string
    description: string
    capitalised: boolean
    capitalisation_reason: string | null
    performer: string
    expense_code: string | null
    // CAPEX-1:这条记录资本化过没有 —— 决定那个按钮出不出现
    capitalised_expense_id: string | null
    // equipment_maintenance_advice 算出来的那三样(视图是唯一实现)
    work_cost_base: number | null
    pct_of_equipment_cost: number | null
    meets_threshold: boolean | null
}

export default function MaintenancePanel({
    assetId, rows, employees, suppliers, expenses, canEdit,
    inServiceDate, capitalisePct, capitaliseFloor, equipmentCostBase, baseCurrency, currencies,
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
    currencies: string[]
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

    // ★【手机上留【日期】与【做了什么】,而这是一个判断】★
    // 一本保养台账被打开的理由是「这台机器什么时候做过什么」。资本化那一格
    // 是【会计后果】,读者要它的时候是逐行读的,所以它进展开区。
    // ☞ 一个必须说出口的代价:**资本化按钮那一列在 390px 上落进展开区。**
    //   它仍然点得到,但不再与判词并排。列进人工走查清单。
    const maintColumns: Column<MaintRow>[] = [
        {
            key: 'date',
            header: t('equipment.maint.colDate'),
            priority: true,
            className: 'text-sm',
            render: (r) => r.performed_on,
        },
        {
            key: 'kind',
            header: t('equipment.maint.colKind'),
            className: 'text-sm',
            render: (r) => t('equipment.kind.' + r.kind),
        },
        {
            key: 'what',
            header: t('equipment.maint.colWhat'),
            priority: true,
            className: 'text-sm',
            render: (r) => r.description,
        },
        {
            key: 'who',
            header: t('equipment.maint.colWho'),
            className: 'text-sm',
            render: (r) => r.performer,
        },
        {
            key: 'capital',
            header: t('equipment.maint.colCapital'),
            className: 'text-sm',
            /* 【人的判断在前,系统的建议在后】—— 两者是两件事,
               而把建议画得像判决,正是 maintenance_settings 表注要拦的那个误读。 */
            render: (r) => (
                <>
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
                </>
            ),
        },
        {
            // ★ 转换前这一列【没有表头】(5 个 <th> 对 6 个 <td>)。见文件抬头。
            key: 'capitaliseAction',
            header: '',
            /* ★【CAPEX-1 的入口】★ 只对【已标资本化、还没资本化过、且机器已投用】
               的行出现 —— 三个条件缺一个,这个按钮对应的服务端调用都会被按名拒,
               而一个点下去只会得到错误的按钮是本仓库记过的那条
               "不要 offer 服务端一定会拒的动作"。未投用的机器不走这条路。 */
            render: (r) =>
                r.capitalised && !r.capitalised_expense_id && inServiceDate && canEdit ? (
                    <CapitaliseControl assetId={assetId} maintenanceId={r.id}
                                       performedOn={r.performed_on}
                                       suppliers={suppliers} baseCurrency={baseCurrency}
                                       currencies={currencies} />
                ) : r.capitalised_expense_id ? (
                    <span className="text-xs text-green-800">{t('equipment.maint.capitalised')}</span>
                ) : (
                    /* 【具名的缺席,不是空白】为什么这里没有按钮,说出来 */
                    <span className="text-xs text-gray-500">
                        {!inServiceDate ? t('equipment.maint.capNotInService')
                         : !r.capitalised ? t('equipment.maint.capNeedsFlag') : ''}
                    </span>
                ),
        },
    ]

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

            {/* ★ 空态由表自己说(DataTable 的 empty)—— CONV-8 §⑤ 的推论。 */}
            <div className="mb-2">
                <DataTable
                    rows={rows}
                    columns={maintColumns}
                    rowKey={(r) => r.id}
                    phone={{ mode: 'columns' }}
                    empty={t('equipment.maint.none')}
                />
            </div>

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
                            /* 【钱是第二步,说出来,不藏起来】见本文件抬头 ——
                               CAPEX-1 之后这条路走得通了,而它仍然是【两步】:
                               先存判断与理由,再在上面那张表的这一行上资本化。
                               两句文案按【投没投用】分,因为两种情形下钱的走法
                               确实不同(投用前直接进成本,投用后落一个折旧锚点)。 */
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

// ── CAPEX-1:把一条【已标资本化】的维修记录变成一笔加在机器上的成本 ──────────
// 【为什么它长在这张表上,而不是长在支出表单里】(Tim 2026-08-24,A4)
//   一笔"给在跑的机器花的钱"要不要进成本,是一个【关于这台机器的判断】,
//   而那个判断连同它的理由只住在 equipment_maintenance 上。让支出表单也能
//   独立地做这件事,就是【两个源头配一条优先级规则】—— 一份第二定义披着
//   破平局的外衣。所以支出那条路对已投用的资产【按名拒】,并指到这里来。
//
// 【汇率不在这张表单上】record_expense 自己去 fx_rates 取(它对递进来的汇率
//   直接 FX_RATE_NOT_ACCEPTED)。牌价属于 fx_rates,不属于表单 —— 这是全库同一条。
// 【税码也不在】留空 = 走供应商的默认进项税码(resolve_tax_code),
//   与普通支出表单同一份实现,不在这里另开一套。
function CapitaliseControl({ assetId, maintenanceId, performedOn, suppliers, baseCurrency, currencies }: {
    assetId: string
    maintenanceId: string
    performedOn: string
    suppliers: { id: string; label: string }[]
    baseCurrency: string
    currencies: string[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [open, setOpen] = useState(false)
    const [error, setError] = useState<string | null>(null)
    // 【日期默认取这次活干的那天,而它【不是】一个服务端默认值】
    //   FIN-10 禁的是【服务端】拿 CURRENT_DATE 顶上来 —— 那会让空着比填对更好走。
    //   这里预填的是一个【已经存在的业务事实】(这条维修记录自己的 performed_on),
    //   人看得见、改得动,而且空掉照样被服务端按名拒。两者不是同一件事。
    const [f, setF] = useState({ expenseDate: performedOn, amount: '', currency: baseCurrency, supplierId: '' })

    // 【按不下去的时候把理由摆在旁边】—— AssetActions 立的规矩。
    const why = !f.expenseDate ? t('equipment.maint.capNeedDate')
              : !f.amount || !(Number(f.amount) > 0) ? t('equipment.maint.capNeedAmount')
              : ''

    function submit() {
        setError(null)
        start(async () => {
            const r = await capitaliseMaintenance({
                assetId, maintenanceId, expenseDate: f.expenseDate,
                amount: f.amount, currency: f.currency, supplierId: f.supplierId, taxCode: '',
            })
            if (r.error) { setError(r.error); return }
            setOpen(false)
            router.refresh()
        })
    }

    if (!open) {
        return (
            <button type="button" onClick={() => { setOpen(true); setError(null) }}
                    className="border border-gray-600 px-2 py-1 rounded text-xs hover:bg-gray-50">
                {t('equipment.maint.capitaliseAction')}
            </button>
        )
    }

    return (
        <div className="border border-gray-400 rounded p-2 bg-amber-50 min-w-[18rem]">
            {/* ★【它会做什么,写在按下去【之前】】★ 这一步会动折旧的摊法,
                而一个改了算术却不预告的按钮,正是本仓库付过 56,532.48 的那一族。 */}
            <p className="text-xs text-gray-800 mb-2">{t('equipment.maint.capitaliseWhatHappens')}</p>
            {error && <p className="text-xs text-red-700 mb-2">{error}</p>}
            <div className="grid grid-cols-2 gap-2">
                <label className="text-xs">
                    {t('equipment.maint.capDate')}
                    <input type="date" value={f.expenseDate} onChange={(e) => setF({ ...f, expenseDate: e.target.value })}
                           className="block w-full border border-gray-300 rounded px-2 py-1 text-xs" />
                </label>
                <label className="text-xs">
                    {t('equipment.maint.capAmount')}
                    <input type="number" step="0.01" min="0" value={f.amount}
                           onChange={(e) => setF({ ...f, amount: e.target.value })}
                           className="block w-full border border-gray-300 rounded px-2 py-1 text-xs" />
                </label>
                <label className="text-xs">
                    {t('equipment.maint.capCurrency')}
                    <select value={f.currency} onChange={(e) => setF({ ...f, currency: e.target.value })}
                            className="block w-full border border-gray-300 rounded px-2 py-1 text-xs">
                        {currencies.map((c) => <option key={c} value={c}>{c}</option>)}
                    </select>
                </label>
                <label className="text-xs">
                    {t('equipment.maint.capSupplier')}
                    <select value={f.supplierId} onChange={(e) => setF({ ...f, supplierId: e.target.value })}
                            className="block w-full border border-gray-300 rounded px-2 py-1 text-xs">
                        <option value="">{t('equipment.maint.capNoSupplier')}</option>
                        {suppliers.map((s) => <option key={s.id} value={s.id}>{s.label}</option>)}
                    </select>
                </label>
            </div>
            <div className="flex gap-2 items-center mt-2">
                <button type="button" disabled={pending || why !== ''} onClick={submit}
                        className="border border-gray-600 bg-gray-800 text-white px-2 py-1 rounded text-xs disabled:opacity-50">
                    {t('equipment.maint.capitaliseAction')}
                </button>
                <button type="button" disabled={pending} onClick={() => { setOpen(false); setError(null) }}
                        className="border border-gray-400 px-2 py-1 rounded text-xs hover:bg-gray-50 disabled:opacity-50">
                    {t('common.cancel')}
                </button>
                {why && <span className="text-xs text-gray-600">{why}</span>}
            </div>
        </div>
    )
}
