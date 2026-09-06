'use client'

// app/finance/cash-forecast/ForecastGrid.tsx
// CASHFLOW-1:13 周的格子。
//
// ★【这一屏最值钱的东西不是数字,是"哪个数字能靠"】★
// 所以三档 confidence 【不是同一个样子换个字】:有约是实心深色的,估计是虚线
// 加保管人名字,手工是灰的。4.2 那一条要的就是这个 —— 一份把三者印成一样的
// 预测,把它唯一的价值扔掉了。
//
// ★【按币种分开,而且不假装有个合计】★ 实测今天 USD 折不出 SGD
// (FX_RATE_MISSING)。所以每个币种一张表;跨币种合计那一格是【一句说明】,
// 不是一个 0 —— 一个编出来的合计比没有合计坏得多。
import { useState, useTransition } from 'react'
import { freezeForecast } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { Button } from '@/app/components/ui/button'

type Bucket = { currency: string; week_no: number; week_start: string; week_end: string
                inflow: number; outflow: number; net: number; closing: number }
type Line = { source: string; confidence: string; direction: string; currency: string
              amount: number; due: string; week_no: number; label: string
              ref: string | null; owner_name: string | null }
type Undated = { source: string; direction: string; currency: string
                 row_count: number; amount: number; why: string; owner_name: string | null }
type Promise_ = { promise_id: string; chase_code: string; customer_name: string
                  currency: string; amount: number; promised_date: string
                  week_no: number; is_overdue: boolean }
type Buffer = { currency: string; monthly_fixed_opex: number; opening: number
                projected_min: number; months_cover_today: number | null
                months_cover_min: number | null }

export type ForecastData = {
    week_start: string; week_end: string; as_of: string; base_currency: string
    currencies: string[]
    opening: { account_code: string; account_name: string; currency: string; amount: number }[]
    lines: Line[]; buckets: Bucket[]; undated: Undated[]
    promises_memo: Promise_[]; buffer: Buffer[]
    base_total_available: boolean; base_total_missing_fx: string[]
}

const money = (n: number) =>
    n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

// 三档的样子【必须不一样】—— 不是三个不同的词,是三种不同的重量
const CONF_CLASS: Record<string, string> = {
    committed: 'text-gray-900 font-medium',
    estimated: 'text-amber-800 border-b border-dashed border-amber-500',
    manual:    'text-gray-500 italic',
}

export default function ForecastGrid({
    data, canFreeze,
}: { data: ForecastData; canFreeze: boolean }) {
    const t = useTranslations()
    const [reason, setReason] = useState('')
    const [error, setError] = useState<string | null>(null)
    const [pending, startTransition] = useTransition()

    const weeks = Array.from({ length: 13 }, (_, i) => i + 1)
    const bucketOf = (ccy: string, w: number) =>
        data.buckets.find((b) => b.currency === ccy && b.week_no === w)
    const openingOf = (ccy: string) =>
        data.opening.filter((o) => o.currency === ccy).reduce((s, o) => s + Number(o.amount), 0)

    // 【Line/Undated 都没有天然的行标识 —— 按下标造一个】
    // 两张表都是只读快照,不会重排、不会被增删,下标在这里是稳定的。
    const lineRows = data.lines.map((l, i) => ({ ...l, _key: String(i) }))
    const undatedRows = data.undated.map((u, i) => ({ ...u, _key: String(i) }))

    const lineColumns: Column<typeof lineRows[number]>[] = [
        { key: 'due', header: t('cashForecast.weekOf'), priority: true, className: 'font-mono text-xs', render: (r) => r.due },
        {
            key: 'label', header: t('cashForecast.label'), priority: true, className: 'break-words',
            render: (r) => (
                <>
                    <span className="mr-1 text-xs text-[color:var(--brand-muted-text)]">{t('cashForecast.source_' + r.source)}</span>
                    {r.label}
                    {r.ref && <span className="ml-1 font-mono text-xs text-[color:var(--brand-muted-text)]">{r.ref}</span>}
                </>
            ),
        },
        {
            key: 'confidence', header: t('cashForecast.confidence'),
            render: (r) => (
                <>
                    <span className={CONF_CLASS[r.confidence]}>{t('cashForecast.conf_' + r.confidence)}</span>
                    {r.owner_name && (
                        <span className="block text-[11px] text-[color:var(--brand-muted-text)]">
                            {t('cashForecast.owner')}: {r.owner_name}
                        </span>
                    )}
                </>
            ),
        },
        {
            key: 'amount', header: t('cashForecast.amount'), align: 'right',
            render: (r) => `${r.direction === 'out' ? `(${money(r.amount)})` : money(r.amount)} ${r.currency}`,
        },
    ]

    const undatedColumns: Column<typeof undatedRows[number]>[] = [
        {
            key: 'source', header: '', priority: true, className: 'bg-amber-50',
            render: (r) => (
                <>
                    {t('cashForecast.source_' + r.source)} × {r.row_count}
                    <span className="block text-[11px] text-amber-900">
                        {t('cashForecast.undated_' + r.why)}
                        {r.owner_name && ` · ${t('cashForecast.owner')}: ${r.owner_name}`}
                    </span>
                </>
            ),
        },
        {
            key: 'amount', header: t('cashForecast.amount'), priority: true, align: 'right', className: 'bg-amber-50',
            render: (r) => `${r.direction === 'out' ? `(${money(r.amount)})` : money(r.amount)} ${r.currency}`,
        },
    ]

    const bufferColumns: Column<Buffer>[] = [
        { key: 'currency', header: t('cashForecast.currency'), priority: true, className: 'font-mono', render: (r) => r.currency },
        { key: 'opex', header: t('cashForecast.monthlyOpex'), align: 'right', render: (r) => money(r.monthly_fixed_opex) },
        {
            key: 'coverToday', header: t('cashForecast.coverToday'), priority: true, align: 'right',
            render: (r) => r.months_cover_today ?? <span className="text-[color:var(--brand-muted-text)]">{t('cashForecast.noOpex')}</span>,
        },
        { key: 'coverMin', header: t('cashForecast.coverMin'), align: 'right', render: (r) => r.months_cover_min ?? '—' },
    ]

    return (
        <div>
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}

            {/* ── 跨币种合计:有就说有,没有就【说清楚为什么没有】 ────────── */}
            {!data.base_total_available && (
                <p className="mb-4 rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">
                    {t('cashForecast.noBaseTotal', {
                        ccy: data.base_currency,
                        missing: data.base_total_missing_fx.join(', '),
                        date: data.as_of,
                    })}
                </p>
            )}

            {/* ── 每个币种一张表 ─────────────────────────────────────────── */}
            {/* ★★【CONV-3:这一张【没有】换成 DataTable —— 写下理由,不是漏转】★★
                DataTable 的契约是【逐行记录】:一行是一条数据,列是这条记录的字段。
                这张表是一个【透视表】:行是"流入/流出/净额/期末"这四个固定的量,
                列是 13 周 —— 它的两根轴都不是"记录",硬套 rowKey/Column 模型
                要么把周当"记录"(于是四个量变成四列,与既有读法整个倒过来),
                要么放弃"顺列扫"这个 DataTable 存在的理由。CONV-1 §⑥ 第 6 条
                与 CONV-2 §⑧ 都拒绝过同一类"没有例子就不设计"的诱惑,这里是
                它的第三次:一张透视表不该被推进一个为逐行账簿设计的组件。
                手机适配靠外层已有的 overflow-x-auto(:84)—— 横向滚动是它
                【本来就在用】的答案,不是转换漏掉的一步。 */}
            {data.currencies.map((ccy) => (
                <div key={ccy} className="mb-8 overflow-x-auto">
                    <h3 className="text-sm font-semibold mb-1">{ccy}</h3>
                    <p className="text-xs text-gray-500 mb-2">
                        {t('cashForecast.opening')}: <span className="font-mono">{money(openingOf(ccy))}</span>
                        {' · '}{t('cashForecast.openingHint')}
                    </p>
                    <table className="border-collapse border border-gray-300 text-xs min-w-max">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-2 py-1 text-left sticky left-0 bg-gray-100">
                                    {t('cashForecast.weekOf')}
                                </th>
                                {weeks.map((w) => (
                                    <th key={w} className="border border-gray-300 px-2 py-1 text-right whitespace-nowrap">
                                        {bucketOf(ccy, w)?.week_start ?? ''}
                                    </th>
                                ))}
                            </tr>
                        </thead>
                        <tbody>
                            {([['inflow', 'cashForecast.inflow'], ['outflow', 'cashForecast.outflow'],
                               ['net', 'cashForecast.net'], ['closing', 'cashForecast.closing']] as const).map(([k, key]) => (
                                <tr key={k} className={k === 'closing' ? 'font-medium bg-gray-50' : ''}>
                                    <td className="border border-gray-300 px-2 py-1 sticky left-0 bg-inherit">{t(key)}</td>
                                    {weeks.map((w) => (
                                        <td key={w} className="border border-gray-300 px-2 py-1 text-right font-mono">
                                            {money(Number(bucketOf(ccy, w)?.[k] ?? 0))}
                                        </td>
                                    ))}
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </div>
            ))}

            {/* ── 明细:每一行说得出【它是哪一种】 ───────────────────────── */}
            <h3 className="text-sm font-semibold mb-1">{t('cashForecast.confidence')}</h3>
            <ul className="text-xs text-gray-600 mb-2 space-y-0.5">
                <li>
                    <span className={CONF_CLASS.committed}>{t('cashForecast.conf_committed')}</span>
                    {' — '}{t('cashForecast.conf_committed_hint')}
                </li>
                <li>
                    <span className={CONF_CLASS.estimated}>{t('cashForecast.conf_estimated')}</span>
                    {' — '}{t('cashForecast.conf_estimated_hint')}
                </li>
                <li>
                    <span className={CONF_CLASS.manual}>{t('cashForecast.conf_manual')}</span>
                    {' — '}{t('cashForecast.conf_manual_hint')}
                </li>
            </ul>
            <div className="mb-8">
                <DataTable
                    rows={lineRows}
                    columns={lineColumns}
                    rowKey={(r) => r._key}
                    phone={{ mode: 'columns' }}
                />
            </div>

            {/* ── ★【预测【看不见】的那部分,印在预测上】★ ───────────────── */}
            <h3 className="text-sm font-semibold mb-1">{t('cashForecast.undatedTitle')}</h3>
            <p className="text-xs text-gray-500 mb-2">{t('cashForecast.undatedHint')}</p>
            {data.undated.length === 0 ? (
                <p className="text-sm text-gray-500 mb-8">—</p>
            ) : (
                <div className="mb-8">
                    {/* ★【原表整行是琥珀底,DataTable 没有整行样式的口子】★
                        与下面 RecurringLines 的"停用行变灰"是同一处模板缺口
                        (见 docs/list-page-template.md「模板做不到的事」一节)。
                        这里改成两格各自带琥珀底 —— 手机展开区里那一格因此不带底色,
                        是逐字还原做不到的一处,记下,不是没看见。 */}
                    <DataTable
                        rows={undatedRows}
                        columns={undatedColumns}
                        rowKey={(r) => r._key}
                        phone={{ mode: 'columns' }}
                    />
                </div>
            )}

            {/* ── 客户承诺:备查,不计入 ─────────────────────────────────── */}
            {data.promises_memo.length > 0 && (
                <>
                    <h3 className="text-sm font-semibold mb-1">{t('cashForecast.promisesTitle')}</h3>
                    <p className="text-xs text-gray-500 mb-2">{t('cashForecast.promisesHint')}</p>
                    <ul className="text-sm mb-8 space-y-1">
                        {data.promises_memo.map((p) => (
                            <li key={p.promise_id} className="text-gray-600">
                                <span className="font-mono">{money(p.amount)} {p.currency}</span>
                                {' → '}{p.promised_date}{' · '}{p.customer_name}
                                <span className="ml-1 font-mono text-xs text-gray-400">{p.chase_code}</span>
                            </li>
                        ))}
                    </ul>
                </>
            )}

            {/* ── 固定 OPEX 覆盖(KPI T2)────────────────────────────────── */}
            <h3 className="text-sm font-semibold mb-1">{t('cashForecast.bufferTitle')}</h3>
            <p className="text-xs text-gray-500 mb-2">{t('cashForecast.coverHint')}</p>
            <div className="mb-8 max-w-2xl">
                <DataTable
                    rows={data.buffer}
                    columns={bufferColumns}
                    rowKey={(r) => r.currency}
                    phone={{ mode: 'columns' }}
                />
            </div>

            {/* ── 冻结 ───────────────────────────────────────────────────── */}
            {canFreeze && (
                <div className="flex flex-wrap items-end gap-3">
                    <label className="text-sm text-gray-600">
                        {t('cashForecast.supersedeReason')}
                        <input value={reason} onChange={(e) => setReason(e.target.value)}
                            className="block rounded border border-gray-300 bg-white px-3 py-2 w-80" />
                    </label>
                    <Button type="button" disabled={pending}
                        onClick={() => {
                            setError(null)
                            startTransition(async () => {
                                const r = await freezeForecast(data.week_start, reason)
                                if (r.error) setError(r.error)
                            })
                        }}
                        variant="default" size="default">
                        {t('cashForecast.freeze')}
                    </Button>
                    <span className="text-xs text-gray-500">{t('cashForecast.freezeHint')}</span>
                </div>
            )}
        </div>
    )
}
