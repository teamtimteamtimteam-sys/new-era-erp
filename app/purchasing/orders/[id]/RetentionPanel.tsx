'use client'

// app/purchasing/orders/[id]/RetentionPanel.tsx
// EQP-PAY-1(R6):一张设备采购单上的质保金。
//
// ★★【这个组件最要紧的一件事:「没有质保金」与「0% 质保金」必须【看起来不一样】】★★
// 它们在库里就已经是两件不同的东西(没有质保金 = 没有那一行;而 percentage 的
// CHECK 是 > 0,所以 0% 那一行【存不进去】)。这里把那个区别画出来:
//   * 有质保金 → 一张带状态、到期日与金额的卡;
//   * 没有质保金 → 一句【明说】的话("这张单没有质保金条款"),
//     **不是一个空白、也不是一个 0**。空白读起来像"还没填",而那是另一件事。
//
// ★【到期【提示】,不【付款】】★ 到期只让状态变成 awaiting_confirmation,
// 屏幕上出现的是一个【要人回答的问题】,不是一笔已经发生的付款。
// 放多少、扣多少都要人填 —— 不给"全额放款"的默认值,因为那等于替人做了
// "这台机器没出过毛病"这个判断,而那正是这次确认要问的唯一问题。
import { useState, useTransition } from 'react'
import { releaseRetention } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import DecimalInput from '@/app/components/forms/DecimalInput'
import { MaskedValue } from '@/app/components/MaskedValue'

export type RetentionRow = {
    retention_id: string
    line_no: number
    asset_code: string | null
    asset_description: string | null
    acceptance_date: string | null
    retention_months: number
    maturity_date: string | null
    retention_state: 'clock_not_started' | 'running' | 'awaiting_confirmation' | 'released'
    percentage: number | null
    retention_amount_ccy: number | null
    released_at: string | null
    released_amount_ccy: number | null
    withheld_amount_ccy: number | null
    withholding_reason: string | null
}

// ★【这四个状态的真源是 purchase_order_retention_status 那张视图里的 CASE】★
// 这个数组是 purchasing.retention.state.* 那族文案的后缀集合(check-i18n 的
// MANIFEST 现读这一行,与 ORDER_KINDS 同一个惯用法)。
// 【它与视图必须一起改】视图里多一档而这里没有,那一档会印出一个裸码;
// 这里多一档而视图没有,那一档永远不出现。两处都要动 —— 写在这里,
// 是因为读到它的人就是正在加那一档的人。
export const RETENTION_STATES = ['clock_not_started', 'running', 'awaiting_confirmation', 'released'] as const

const STATE_STYLE: Record<string, string> = {
    clock_not_started: 'bg-gray-100 text-gray-700 border-gray-300',
    running: 'bg-blue-50 text-blue-800 border-blue-200',
    awaiting_confirmation: 'bg-amber-50 text-amber-900 border-amber-300',
    released: 'bg-green-50 text-green-800 border-green-200',
}

export default function RetentionPanel({
    poId, rows, isEquipmentOrder, canEdit, currency, canSeePrices,
}: {
    poId: string
    rows: RetentionRow[]
    isEquipmentOrder: boolean
    canEdit: boolean
    currency: string
    canSeePrices: boolean
}) {
    const t = useTranslations()

    // 材料单上不谈质保金 —— 连标题都不该出现(一个恒空的区块会让人以为该填点什么)。
    if (!isEquipmentOrder) return null

    return (
        <div className="space-y-2">
            <h2 className="font-bold">{t('purchasing.retention.title')}</h2>
            {rows.length === 0 ? (
                /* ★【明说,不留白】★ 这一句就是"这张单没有质保金"这个【事实】。
                   留一片空白,读起来是"还没填";印一个 0%,更糟 —— 那是另一件事。 */
                <p className="text-sm text-gray-700 border border-gray-200 rounded px-3 py-2 bg-gray-50">
                    {t('purchasing.retention.none')}
                </p>
            ) : (
                <div className="space-y-3">
                    {rows.map((r) => (
                        <RetentionCard
                            key={r.retention_id}
                            poId={poId} r={r} canEdit={canEdit}
                            currency={currency} canSeePrices={canSeePrices}
                        />
                    ))}
                </div>
            )}
        </div>
    )
}

function RetentionCard({
    poId, r, canEdit, currency, canSeePrices,
}: {
    poId: string; r: RetentionRow; canEdit: boolean; currency: string; canSeePrices: boolean
}) {
    const t = useTranslations()
    const [released, setReleased] = useState('')
    const [withheld, setWithheld] = useState('')
    const [reason, setReason] = useState('')
    const [error, setError] = useState<string | null>(null)
    const [pending, startTransition] = useTransition()

    // 【受限 ≠ 0,也 ≠ 空白】没有 data.view_prices 的人看到的是「受限」,
    // 而不是一个 0 或一片空白 —— 那正是 MaskedValue 存在的全部理由。
    const money = (n: number | null) => (
        <MaskedValue
            value={n}
            canView={canSeePrices}
            fallback="—"
            format={(v) => `${Number(v).toLocaleString()} ${currency}`}
        />
    )

    return (
        <div className={`border rounded px-3 py-2 text-sm ${STATE_STYLE[r.retention_state] ?? ''}`}>
            <div className="flex flex-wrap items-center gap-x-4 gap-y-1">
                <span className="font-medium">
                    #{r.line_no} {r.asset_code ?? ''} {r.asset_description ?? ''}
                </span>
                <span className="px-2 py-0.5 rounded border text-xs">
                    {t('purchasing.retention.state.' + r.retention_state)}
                </span>
                <span>
                    {r.percentage !== null ? `${r.percentage}%` : ''} {money(r.retention_amount_ccy)}
                </span>
                <span>{t('purchasing.retention.monthsLabel', { 0: r.retention_months })}</span>
            </div>

            <div className="mt-1 text-xs">
                {/* ★【没有验收日 = 时钟还没起算】★ 这不是缺数据,也不是零 ——
                    今天线上两台机器都是这个状态(厂子没开工)。 */}
                {r.acceptance_date === null ? (
                    <span>{t('purchasing.retention.clockNotStarted')}</span>
                ) : (
                    <span>
                        {t('purchasing.retention.derivedFrom', {
                            0: r.acceptance_date,
                            1: r.maturity_date ?? '—',
                        })}
                    </span>
                )}
            </div>

            {r.retention_state === 'released' && (
                <div className="mt-1 text-xs flex flex-wrap items-center gap-1">
                    {/* 【不要把一个 React 节点塞进 t() 的参数里】那会变成 "[object Object]"。
                        受限渲染是一个节点,所以这里把句子拆开排,而不是拼字符串。 */}
                    <span>{t('purchasing.retention.releaseAmount')}:</span>
                    {money(r.released_amount_ccy)}
                    <span className="ml-2">{t('purchasing.retention.withheldAmount')}:</span>
                    {money(r.withheld_amount_ccy)}
                    {r.withholding_reason ? <span className="ml-2">— {r.withholding_reason}</span> : null}
                </div>
            )}

            {/* ★ 到期了:出现的是一个【问题】,不是一笔付款 ★ */}
            {r.retention_state === 'awaiting_confirmation' && canEdit && (
                <div className="mt-2 border-t border-amber-200 pt-2">
                    <p className="text-xs mb-2">{t('purchasing.retention.confirmPrompt')}</p>
                    <div className="flex flex-wrap items-center gap-2">
                        <label className="text-xs">{t('purchasing.retention.releaseAmount')}</label>
                        <DecimalInput value={released} onChange={setReleased}
                            className="w-28 border border-gray-300 px-2 py-1 rounded" />
                        <label className="text-xs">{t('purchasing.retention.withheldAmount')}</label>
                        <DecimalInput value={withheld} onChange={setWithheld}
                            className="w-28 border border-gray-300 px-2 py-1 rounded" />
                    </div>
                    <input
                        type="text" value={reason} onChange={(e) => setReason(e.target.value)}
                        placeholder={t('purchasing.retention.reasonPlaceholder')}
                        className="mt-2 w-full border border-gray-300 px-2 py-1 rounded text-xs"
                    />
                    <button
                        type="button"
                        disabled={pending}
                        onClick={() => {
                            setError(null)
                            startTransition(async () => {
                                const res = await releaseRetention(poId, r.retention_id, released, withheld, reason)
                                if (res.error) setError(res.error)
                            })
                        }}
                        className="mt-2 px-3 py-1 bg-amber-700 text-white rounded text-xs disabled:opacity-50"
                    >
                        {t('purchasing.retention.confirmButton')}
                    </button>
                    {error && <p className="mt-1 text-xs text-red-700">{error}</p>}
                </div>
            )}
        </div>
    )
}
