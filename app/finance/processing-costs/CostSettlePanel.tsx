'use client'

// 两半:实际额勾选汇付;估算勾选 + 发票额 → 【先看到差异再提交】(C3 的要点)。
//
// 【日期为什么一半一个,而且必填】原先是【一个】标着"日期"的字段悬在两半上方,
// 一个字段服务两种操作、两种含义:汇付那半它是【付款日】,冲抵那半它是【发票日】,
// 而后者决定差异落进哪个会计期间。一个字段两种意思,本身就是错的布局 ——
// 于是各半自己带一个日期,挨着自己的按钮,标签直接说这个日期【决定什么】。
// 【不默认成今天】:拿今天的日期去结七月的应计,差异就落在八月,事后毫无迹象。
//
// ★★ CONV-3(Kind-C):这一页是【证明】DataTable 的 selection prop 的地方 ★★
// 两张表(实际额 / 估算)各自是【独立的 DataTable 实例】,各带各的 selection —
// 天然就是两个互不相干的选中集,不需要给 selection 设计"命名分组"这种复杂度。
// 见 data-table.tsx 抬头 CONV-3 那一节:这正是那条设计判断的来源页面。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { formatAmount, formatMoneyBare } from '@/lib/format'
import { remitCosts, relieveAccruals } from '../month-end/actions'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { Button } from '@/app/components/ui/button'

type Entry = { id: string; run_id: string; cost_type: string; amount_base: number; is_estimate: boolean; created_at: string }
type Run = { id: string; code: string }
type Sup = { id: string; legal_name: string }

// baseCurrency:'{accrued} {ccy}' 这句文案一直只传了 accrued —— 解析器对认不出的
// 占位符原样保留(lib/i18n/client.tsx),所以屏幕上真的印着"1,234.00 {ccy}。"。
// 币种来自数据(currencies.is_base),由页面传入。
export default function CostSettlePanel({ entries, runs, suppliers, baseCurrency }: { entries: Entry[]; runs: Run[]; suppliers: Sup[]; baseCurrency: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [selA, setSelA] = useState<Record<string, boolean>>({})
    const [selE, setSelE] = useState<Record<string, boolean>>({})
    const [actual, setActual] = useState('')
    const [payDate, setPayDate] = useState('')
    const [invDate, setInvDate] = useState('')
    const [payStatus, setPayStatus] = useState('paid')
    const [supplier, setSupplier] = useState('')
    const runBy = new Map(runs.map((r) => [r.id, r.code]))

    const actuals = entries.filter((e) => !e.is_estimate)
    const estimates = entries.filter((e) => e.is_estimate)
    const chosenA = actuals.filter((e) => selA[e.id])
    const chosenE = estimates.filter((e) => selE[e.id])
    const accrued = Math.round(chosenE.reduce((s, e) => s + Number(e.amount_base), 0) * 100) / 100
    const actualN = Number(actual)
    const variance = actual !== '' && !Number.isNaN(actualN)
        ? Math.round((actualN - accrued) * 100) / 100 : null
    const mixedTypes = new Set(chosenE.map((e) => e.cost_type)).size > 1

    function run(fn: () => Promise<{ error?: string }>) {
        setError(null)
        start(async () => {
            const r = await fn()
            if (r.error) setError(r.error)
            else { setSelA({}); setSelE({}); setActual(''); router.refresh() }
        })
    }

    // 日期输入:必填、缺就标红。onChange 之外【再挂一次 onBlur】—— 浏览器自动填充、
    // 表单状态恢复、某些日期选择器会直接改 DOM 值而不触发 React 的 change,受控输入
    // 于是显示着日期、状态却仍是空串。走查里"字段填着 08/05 却报空串"就是这个形状:
    // React 只比对前后两次的 prop,不会拿 prop 去纠正 DOM,所以一旦失同步就一直错下去。
    const dateField = (id: string, value: string, set: (v: string) => void, labelKey: string, hintKey: string) => (
        <label className="text-xs text-gray-600 block">
            {t(labelKey)} <span className="text-red-600">*</span>
            <input id={id} type="date" value={value} required aria-invalid={value === ''}
                   onChange={(e) => set(e.target.value)} onBlur={(e) => set(e.target.value)}
                   className={'block border rounded px-2 py-1 text-sm '
                       + (value === '' ? 'border-red-400 bg-red-50' : 'border-gray-300')} />
            <span className="mt-1 block max-w-[16rem] text-gray-500">{t(hintKey)}</span>
        </label>
    )

    const columns: Column<Entry>[] = [
        { key: 'run', header: t('finance.costSettle.colRun'), priority: true, className: 'font-mono', render: (e) => runBy.get(e.run_id) },
        { key: 'type', header: t('finance.costSettle.colCostType'), priority: true, render: (e) => t('processing.costTypes.' + e.cost_type) },
        { key: 'amount', header: t('finance.costSettle.colAmount'), priority: true, align: 'right', render: (e) => formatAmount(e.amount_base, baseCurrency) },
        { key: 'date', header: t('finance.costSettle.colEntryDate'), className: 'text-xs text-gray-500', render: (e) => e.created_at.slice(0, 10) },
    ]

    // 【Record<id, boolean> ↔ Set<id>,各自独立】—— selA 与 selE 是两个不同的
    // state,所以造出来的两个 selection 天生互不相干,不需要任何"命名分组"。
    const selectionFor = (
        rows: Entry[], sel: Record<string, boolean>, setSel: (v: Record<string, boolean>) => void,
    ) => ({
        selectedIds: new Set(Object.keys(sel).filter((id) => sel[id])),
        onToggle: (id: string) => setSel({ ...sel, [id]: !sel[id] }),
        onToggleAll: (ids: readonly string[]) => {
            const allSelected = ids.length > 0 && ids.every((id) => sel[id])
            setSel(allSelected ? {} : Object.fromEntries(ids.map((id) => [id, true])))
        },
        selectAllLabel: t('finance.costSettle.selectAll'),
        selectRowLabel: t('finance.costSettle.selectRow'),
    })

    return (
        <div>
            {error && <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>}

            {/* ── 实际额:汇付 ─────────────────────────────────────────────── */}
            <h2 className="text-lg font-bold mb-2">{t('finance.costSettle.actualTitle')}</h2>
            {actuals.length === 0 ? <p className="text-sm text-gray-500 mb-6">{t('finance.costSettle.none')}</p> : (
                <div className="mb-6 rounded border border-gray-200 p-4">
                    <div className="mb-3">
                        <DataTable
                            rows={actuals}
                            columns={columns}
                            rowKey={(e) => e.id}
                            phone={{ mode: 'columns' }}
                            selection={selectionFor(actuals, selA, setSelA)}
                        />
                    </div>
                    <div className="flex gap-4 flex-wrap items-start">
                        {dateField('pay-date', payDate, setPayDate,
                            'finance.costSettle.paymentDate', 'finance.costSettle.paymentDateHint')}
                        <Button size="sm" className="mt-4" type="button" disabled={pending || chosenA.length === 0 || payDate === ''}
                            onClick={() => run(() => remitCosts(chosenA.map((e) => e.id), payDate, ''))}>
                            {t('finance.costSettle.remit', { n: chosenA.length })}
                        </Button>
                    </div>
                </div>
            )}

            {/* ── 估算:按真实发票冲抵 ─────────────────────────────────────── */}
            <h2 className="text-lg font-bold mb-2">{t('finance.costSettle.estimateTitle')}</h2>
            {estimates.length === 0 ? <p className="text-sm text-gray-500">{t('finance.costSettle.none')}</p> : (
                <div className="rounded border border-gray-200 p-4">
                    <div className="mb-3">
                        <DataTable
                            rows={estimates}
                            columns={columns}
                            rowKey={(e) => e.id}
                            phone={{ mode: 'columns' }}
                            selection={selectionFor(estimates, selE, setSelE)}
                        />
                    </div>
                    <div className="flex gap-4 flex-wrap items-start text-xs">
                        {dateField('inv-date', invDate, setInvDate,
                            'finance.costSettle.invoiceDate', 'finance.costSettle.invoiceDateHint')}
                        <label>{t('finance.costSettle.invoiceAmount')}
                            <input type="number" value={actual} onChange={(e) => setActual(e.target.value)}
                                   className="block border border-gray-300 rounded px-2 py-1 text-sm w-32 text-right" />
                        </label>
                        <label>{t('finance.costSettle.payStatus')}
                            <select value={payStatus} onChange={(e) => setPayStatus(e.target.value)}
                                    className="block border border-gray-300 rounded px-2 py-1 text-sm">
                                <option value="paid">{t('finance.costSettle.paid')}</option>
                                <option value="unpaid">{t('finance.costSettle.unpaid')}</option>
                            </select>
                        </label>
                        {payStatus === 'unpaid' && (
                            <label>{t('finance.costSettle.supplier')}
                                {/* LOG-1b:空名单不画空下拉 —— 说出它是哪一种空(货代那一侧另有一句)。 */}
                                {suppliers.length === 0 ? (
                                    <p className="text-sm text-amber-900 bg-amber-50 border border-amber-300 rounded px-3 py-2 max-w-xl">
                                        {t('suppliers.pickerEmptyGoods')}
                                    </p>
                                ) : (
                                    <select value={supplier} onChange={(e) => setSupplier(e.target.value)}
                                            className="block border border-gray-300 rounded px-2 py-1 text-sm">
                                        <option value=""></option>
                                        {suppliers.map((s) => <option key={s.id} value={s.id}>{s.legal_name}</option>)}
                                    </select>
                                )}
                            </label>
                        )}
                        <Button size="sm" className="mt-4" type="button"
                            disabled={pending || chosenE.length === 0 || variance === null || mixedTypes
                                      || invDate === '' || (payStatus === 'unpaid' && !supplier)}
                            onClick={() => run(() => relieveAccruals({ entryIds: chosenE.map((e) => e.id), actual: actualN, date: invDate, paymentStatus: payStatus, bank: '', supplierId: supplier }))}>
                            {t('finance.costSettle.relieve', { n: chosenE.length })}
                        </Button>
                    </div>
                    {/* 差异在提交【之前】就摆出来,并且说清【是哪个方向】——
                        光给一个带正负号的数字,看的人还得自己想"这是估多了还是估少了" */}
                    {chosenE.length > 0 && (
                        <p className="text-sm mt-3">
                            {t('finance.costSettle.preview', { accrued: formatMoneyBare(accrued, '同句 preview 文案里的 {ccy} 占位符'), ccy: baseCurrency })}
                            {variance !== null && (
                                <span className={'ml-2 font-medium ' + (variance > 0 ? 'text-red-700' : variance < 0 ? 'text-green-700' : 'text-gray-600')}>
                                    {variance > 0
                                        ? t('finance.costSettle.varianceUnder', { v: formatAmount(variance, baseCurrency) })
                                        : variance < 0
                                        ? t('finance.costSettle.varianceOver', { v: formatAmount(Math.abs(variance), baseCurrency) })
                                        : t('finance.costSettle.varianceNone')}
                                </span>
                            )}
                            {mixedTypes && <span className="ml-2 text-red-700">{t('finance.costSettle.mixedTypes')}</span>}
                        </p>
                    )}
                </div>
            )}
        </div>
    )
}
