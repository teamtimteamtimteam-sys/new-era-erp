'use client'

// EQP-2d(P3):停机 —— 记一段,以及把开着的那一段关上。
//
// 【一段【开着的】停机必须看起来是"开着",而不是"结束时间忘了填"】
// equipment_downtime.duration 的列注释写着这句:还没结束时它是 NULL,
// **那不是"零",是"还不知道"**。屏幕上两者长得一样就等于把那句话丢了 ——
// 所以开着的那一段有自己的底色、自己的标签(「进行中」),而时长那一栏写的是
// 「还在停」而不是一个空格或一个 0。
//
// 【一台机器同时只能有一段开口 —— 而它是【库】说了算,不是屏幕】
// uq_equipment_downtime_open 是一条部分唯一索引。屏幕这边:开着的时候不画
// "开一段"的表单,只画"关上它" —— 不给一个服务端保证会拒的动作画按钮
// (AGENTS.md 那条"页面与服务端不一致时先问谁错了")。
// **但那条拒绝仍然接了句子,而且它【真的够得着】** —— 两个人(或两个标签页)
// 同时开,第二个就会撞上。W1 正面走这一条:一个只在竞态下出现的拒绝,
// 恰恰最不该是一串机器码。
//
// 【结束时间早于开始时间【不在这里判】】那是表上 equipment_downtime_period_order
// 的活。在 TS 里再比一遍就是第二份实现。让库拒,句子由约束名翻。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { openDowntime, closeDowntime } from './actions'

export type DowntimeRow = {
    id: string
    started_at: string
    ended_at: string | null
    reason: string
    notes: string | null
    duration: string | null
}

export default function DowntimePanel({
    assetId, rows, canEdit, locale,
}: {
    assetId: string; rows: DowntimeRow[]; canEdit: boolean; locale: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [open, setOpen] = useState(false)
    const [f, setF] = useState({ startedAt: '', reason: '', notes: '' })
    const [endAt, setEndAt] = useState('')

    const openRow = rows.find((r) => r.ended_at === null) ?? null
    const fmt = (iso: string) => new Date(iso).toLocaleString(locale === 'zh' ? 'zh-CN' : 'en-GB',
        { year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' })

    function run(fn: () => Promise<{ error?: string }>) {
        setError(null)
        start(async () => {
            const r = await fn()
            if (r.error) { setError(r.error); return }
            setOpen(false); setF({ startedAt: '', reason: '', notes: '' }); setEndAt('')
            router.refresh()
        })
    }

    return (
        <div className="mb-8">
            <div className="flex items-baseline gap-3 mb-2">
                <h2 className="text-lg font-medium">{t('equipment.down.title')}</h2>
                {canEdit && !openRow && (
                    <button type="button" onClick={() => setOpen(!open)} disabled={pending}
                            className="border border-gray-400 px-2 py-1 rounded text-xs hover:bg-gray-50 disabled:opacity-50">
                        {t('equipment.down.add')}
                    </button>
                )}
            </div>
            {!canEdit && <p className="text-xs text-gray-500 mb-2">{t('equipment.needsProcessingEdit')}</p>}
            {error && <p className="text-red-600 text-xs mb-2">{error}</p>}

            {/* ── 开着的那一段:自己一块,不混在流水里 ─────────────────────────── */}
            {openRow && (
                <div className="border-2 border-amber-400 bg-amber-50 rounded p-3 mb-3 text-sm">
                    <p className="font-medium text-amber-900">
                        {t('equipment.down.openNow', { since: fmt(openRow.started_at) })}
                    </p>
                    <p className="text-gray-700 mt-1">{openRow.reason}</p>
                    {/* 【时长这一栏说"还在停",不是空白、不是 0】—— duration 的列注释
                        说的正是这件事:NULL 不是零,是"还不知道"。 */}
                    <p className="text-xs text-gray-600 mt-1">{t('equipment.down.stillDown')}</p>
                    {canEdit && (
                        <div className="flex flex-wrap gap-2 items-end mt-2">
                            <label className="block">
                                <span className="text-xs text-gray-600 block">{t('equipment.down.endedAt')}</span>
                                <input type="datetime-local" value={endAt} onChange={(e) => setEndAt(e.target.value)}
                                       className="border border-gray-400 rounded px-2 py-1 text-sm" />
                            </label>
                            <button type="button" disabled={pending || !endAt}
                                    onClick={() => run(() => closeDowntime({ assetId, downtimeId: openRow.id, endedAt: endAt }))}
                                    className="border border-gray-600 bg-gray-800 text-white px-3 py-1 rounded text-xs disabled:opacity-50">
                                {t('equipment.down.close')}
                            </button>
                            {!endAt && <span className="text-xs text-gray-600">{t('equipment.down.needEnd')}</span>}
                        </div>
                    )}
                    {/* 【为什么这里没有"再开一段"的按钮】说出来,不要让人以为按钮坏了。 */}
                    {canEdit && <p className="text-xs text-gray-600 mt-2">{t('equipment.down.oneOpenOnly')}</p>}
                </div>
            )}

            {rows.length === 0 ? (
                <p className="text-sm text-gray-600 mb-2">{t('equipment.down.none')}</p>
            ) : (
                <table className="border-collapse mb-2">
                    <thead><tr className="bg-gray-50">
                        <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('equipment.down.colFrom')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('equipment.down.colTo')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('equipment.down.colFor')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('equipment.down.colReason')}</th>
                    </tr></thead>
                    <tbody>
                        {rows.map((r) => (
                            <tr key={r.id} className={r.ended_at === null ? 'bg-amber-50' : ''}>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{fmt(r.started_at)}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">
                                    {/* 开着的一段在这两栏里也要说人话,不是空格 */}
                                    {r.ended_at ? fmt(r.ended_at) : <span className="text-amber-800">{t('equipment.down.openLabel')}</span>}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">
                                    {r.ended_at ? (r.duration ?? '—') : <span className="text-amber-800">{t('equipment.down.stillDown')}</span>}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{r.reason}</td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}

            {open && canEdit && !openRow && (
                <div className="border border-gray-400 rounded p-3 text-sm space-y-2 max-w-xl">
                    <label className="block">
                        <span className="text-xs text-gray-600 block">{t('equipment.down.startedAt')}</span>
                        {/* 【不预填"现在"】停机是世界那一侧的事实 —— 谁都可能过后才来补录。 */}
                        <input type="datetime-local" value={f.startedAt}
                               onChange={(e) => setF({ ...f, startedAt: e.target.value })}
                               className="border border-gray-400 rounded px-2 py-1 text-sm" />
                    </label>
                    <label className="block">
                        <span className="text-xs text-gray-600 block">{t('equipment.down.reason')}</span>
                        <input value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })}
                               className="border border-gray-400 rounded px-2 py-1 text-sm w-full" />
                    </label>
                    <p className="text-xs text-gray-600">{t('equipment.down.openHint')}</p>
                    <div className="flex gap-2 items-center">
                        <button type="button" disabled={pending || !f.startedAt || !f.reason.trim()}
                                onClick={() => run(() => openDowntime({ assetId, ...f }))}
                                className="border border-gray-600 bg-gray-800 text-white px-3 py-1 rounded text-xs disabled:opacity-50">
                            {t('common.save')}
                        </button>
                        <button type="button" disabled={pending} onClick={() => { setOpen(false); setError(null) }}
                                className="border border-gray-400 px-3 py-1 rounded text-xs hover:bg-gray-50 disabled:opacity-50">
                            {t('common.cancel')}
                        </button>
                    </div>
                </div>
            )}
        </div>
    )
}
