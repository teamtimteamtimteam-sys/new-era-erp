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
//
// ★ CONV-9(2026-09-04):那张只读的停机记录表转成 DataTable。
//   【这一页不多一个文件】这个面板本来就是 'use client'(它要 useState),
//   所以列描述符就住在这里 —— 与 CONV-1 在 /finance/claims 上的情形同形。
//   【开着的那一段整行发琥珀】走 rowClassName(CONV-4 §⑨-3),与转换前逐字同形。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { openDowntime, closeDowntime } from './actions'
import { Button } from '@/app/components/ui/button'

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
    // FIX-2(F):结束早于开始 —— 这正是 Tim 撞上的那一条,而屏幕此前一个字都没说。
    // (datetime-local 给的是本地时间串;与开始时刻同口径比较即可。)
    const endBeforeStart = !!(openRow && endAt && new Date(endAt) < new Date(openRow.started_at))
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

    // ★【手机上留【开始时刻】与【停了多久】,而这是一个判断】★
    // 这个面板的抬头写着:一段开着的停机必须看起来是"开着",而不是"结束时间忘了填"。
    // 「停了多久」那一格正是承载这句话的地方(它写「还在停」,不是空格也不是 0),
    // 所以它必须留在小屏上。结束时刻与原因进展开区。
    const downtimeColumns: Column<DowntimeRow>[] = [
        {
            key: 'from',
            header: t('equipment.down.colFrom'),
            priority: true,
            className: 'text-sm',
            render: (r) => fmt(r.started_at),
        },
        {
            key: 'to',
            header: t('equipment.down.colTo'),
            className: 'text-sm',
            // 开着的一段在这两栏里也要说人话,不是空格
            render: (r) =>
                r.ended_at ? fmt(r.ended_at) : <span className="text-amber-800">{t('equipment.down.openLabel')}</span>,
        },
        {
            key: 'for',
            header: t('equipment.down.colFor'),
            priority: true,
            className: 'text-sm',
            render: (r) =>
                r.ended_at ? (r.duration ?? '—') : <span className="text-amber-800">{t('equipment.down.stillDown')}</span>,
        },
        {
            key: 'reason',
            header: t('equipment.down.colReason'),
            className: 'text-sm',
            render: (r) => r.reason,
        },
    ]

    return (
        <div className="mb-8">
            <div className="flex items-baseline gap-3 mb-2">
                <h2 className="text-lg font-medium">{t('equipment.down.title')}</h2>
                {canEdit && !openRow && (
                    <Button variant="secondary" size="xs" type="button" onClick={() => setOpen(!open)} disabled={pending}>
                        {t('equipment.down.add')}
                    </Button>
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
                            <Button size="xs" type="button" disabled={pending || !endAt || endBeforeStart}
                                    onClick={() => run(() => closeDowntime({ assetId, downtimeId: openRow.id, endedAt: endAt }))}>
                                {t('equipment.down.close')}
                            </Button>
                            {/* FIX-2(F):【禁用了就说为什么 —— 每一个条件各一句】
                                此前只有"没填"那一句。**填了一个早于开始的时刻时,
                                按钮是【能点】的**,人点下去才换来一次数据库拒绝 ——
                                屏幕全程没说过那件事。现在当场说,并且不让它点。 */}
                            {!endAt && <span className="text-xs text-gray-600">{t('equipment.down.needEnd')}</span>}
                            {endAt && endBeforeStart && (
                                <span className="text-xs text-amber-700">
                                    {t('equipment.down.endBeforeStart', { start: fmt(openRow.started_at) })}
                                </span>
                            )}
                        </div>
                    )}
                    {/* 【为什么这里没有"再开一段"的按钮】说出来,不要让人以为按钮坏了。 */}
                    {canEdit && <p className="text-xs text-gray-600 mt-2">{t('equipment.down.oneOpenOnly')}</p>}
                </div>
            )}

            {/* ★ 空态由表自己说(DataTable 的 empty)—— CONV-8 §⑤ 的推论:
                  详情页上空的只可能是子表,那句话归那张表。 */}
            <div className="mb-2">
                <DataTable
                    rows={rows}
                    columns={downtimeColumns}
                    rowKey={(r) => r.id}
                    phone={{ mode: 'columns' }}
                    // 【开着的那一段整行发琥珀】—— 与转换前逐字同形。
                    rowClassName={(r) => (r.ended_at === null ? 'bg-amber-50' : undefined)}
                    empty={t('equipment.down.none')}
                />
            </div>

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
                        <Button size="xs" type="button" disabled={pending || !f.startedAt || !f.reason.trim()}
                                onClick={() => run(() => openDowntime({ assetId, ...f }))}>
                            {t('common.save')}
                        </Button>
                        {/* FIX-2(F2):这一块的每一个禁用条件也各配一句。 */}
                        {!f.startedAt && <span className="text-xs text-amber-700">{t('equipment.down.needStart')}</span>}
                        {f.startedAt && !f.reason.trim() && (
                            <span className="text-xs text-amber-700">{t('equipment.down.needReason')}</span>
                        )}
                        <Button variant="secondary" size="xs" type="button" disabled={pending} onClick={() => { setOpen(false); setError(null) }}>
                            {t('common.cancel')}
                        </Button>
                    </div>
                </div>
            )}
        </div>
    )
}
