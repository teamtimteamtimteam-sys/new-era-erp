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
//
// ★ U1-B(2026-10-05,UNBLOCK-1 Q15):一段停机可以【更正】、可以【作废】,永远不硬删。
//   · 更正 = 起始时刻、结束时刻(只在那一段已经关了时)、原因 —— 直连 UPDATE,规矩全在库里
//     (period_order · 未来时刻 · 重叠),句子由 localizeEquipmentError 翻。开着的那一段【不】借更正关上:
//     它的结束只走"关上它"那一条路。
//   · 作废 = 这一段【从来没有发生过】,带理由(ConfirmButton 的必填理由框)→ void_equipment_downtime。
//   · 作废过的那一行【留在表里】:发灰、起止划掉、一枚「已作废」加上理由 —— 它不是"开着的那一段"
//     (openRow 跳过它),也不再给"更正 / 作废"(库里那一行已经冻住,DOWNTIME_VOIDED)。
//     ☞ 那两个钮对作废的行是【不画】,不是【画了按不动】:不画的原因是记录状态,不是权限 ——
//       DBLOCK-1 的第二条边界(不许把权限与记录状态混进一个布尔)。
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { openDowntime, closeDowntime, correctDowntime, voidDowntime } from './actions'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { formatAuditStamp } from '@/lib/dates'
import { DatePicker } from '@/app/components/ui/date-picker'

export type DowntimeRow = {
    id: string
    started_at: string
    ended_at: string | null
    reason: string
    notes: string | null
    duration: string | null
    /** U1-B:作废的时刻 —— 有值 = 这一段没有发生过(行留着、标着,不算开着)。 */
    voided_at: string | null
    voided_by: string | null
    void_reason: string | null
}

export default function DowntimePanel({
    assetId, rows, canEdit, locale,
}: {
    assetId: string; rows: DowntimeRow[]; canEdit: boolean; locale: string
}) {
    // ★ DATE-1:停机的起止时刻走【审计戳】那一族,而审计戳**不随界面语言变**(D2)。
    //   于是这个 prop 不再被用到 —— 但它【留着】:调用点一直在传,
    //   而把它从签名里拿掉是一次与本刀无关的接口改动。
    //   ☞ 写成 `void locale` 而不是删掉,是为了让这句话留在下一个读者眼前
    //     (与 lib/format.ts 的 formatTimestamp、formatMoneyBare 同一个手法)。
    void locale
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [open, setOpen] = useState(false)
    const [f, setF] = useState({ startedAt: '', reason: '', notes: '' })
    const [endAt, setEndAt] = useState('')
    // DATE-PICK-1:两块都靠按钮 onClick 提交(不走原生表单)—— 框里敲了一个不存在的时刻时把按钮关掉
    const [startBad, setStartBad] = useState(false)
    const [endBad, setEndBad] = useState(false)
    // U1-B:正在更正的那一段(一次只开一块)。endedAt 为 null = 那一段开着,结束时刻不在这一块里改。
    const [editing, setEditing] = useState<{ id: string; startedAt: string; endedAt: string | null; reason: string } | null>(null)
    const [editStartBad, setEditStartBad] = useState(false)
    const [editEndBad, setEditEndBad] = useState(false)

    // ★ U1-B:作废过的那一段【不是】开着的那一段 —— 库里的部分唯一索引与重叠判据也都跳过它。
    const openRow = rows.find((r) => r.ended_at === null && r.voided_at === null) ?? null
    // FIX-2(F):结束早于开始 —— 这正是 Tim 撞上的那一条,而屏幕此前一个字都没说。
    // (DATE-PICK-1:日期时间框交出的是带 +08:00 偏移的新加坡时刻,started_at 是 timestamptz ——
    //  两边都是绝对时刻,直接比。)
    const endBeforeStart = !!(openRow && endAt && new Date(endAt) < new Date(openRow.started_at))
    // DATE-1:停机的起止时刻是【系统记下的那一刻】—— 走审计戳那一族,
    // 于是它可排序、可复制、也不随界面语言变。
    const fmt = (iso: string) => formatAuditStamp(iso)

    function run(fn: () => Promise<{ error?: string }>) {
        setError(null)
        start(async () => {
            const r = await fn()
            if (r.error) { setError(r.error); return }
            setOpen(false); setF({ startedAt: '', reason: '', notes: '' }); setEndAt('')
            setEditing(null)
            router.refresh()
        })
    }

    // U1-B:更正那一块的禁用条件 —— 每一条各配一句(FIX-2(F) 的规矩)。
    const editEndBeforeStart = !!(editing && editing.endedAt && editing.startedAt
        && new Date(editing.endedAt) < new Date(editing.startedAt))
    const editingRow = editing ? rows.find((r) => r.id === editing.id) ?? null : null

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
            render: (r) => (r.voided_at ? <span className="line-through">{fmt(r.started_at)}</span> : fmt(r.started_at)),
        },
        {
            key: 'to',
            header: t('equipment.down.colTo'),
            className: 'text-sm',
            // 开着的一段在这两栏里也要说人话,不是空格
            // U1-B:作废了的一段【不说】"还开着" —— 它没有发生过,也就无所谓开着。
            render: (r) =>
                r.voided_at ? (r.ended_at ? <span className="line-through">{fmt(r.ended_at)}</span> : '—')
                : r.ended_at ? fmt(r.ended_at) : <span className="text-amber-800">{t('equipment.down.openLabel')}</span>,
        },
        {
            key: 'for',
            header: t('equipment.down.colFor'),
            priority: true,
            className: 'text-sm',
            // U1-B:这一格是【状态】那一格(手机上留着)—— 作废的行在这里亮出「已作废」,不是一个空格。
            render: (r) =>
                r.voided_at ? (
                    <span className="inline-flex flex-wrap items-center gap-1.5">
                        {r.ended_at && <span className="line-through">{r.duration ?? '—'}</span>}
                        <span className="inline-block rounded bg-gray-100 px-2 py-0.5 text-xs text-gray-600" data-downtime-voided="1">
                            {t('equipment.down.voidedBadge')}
                        </span>
                    </span>
                )
                : r.ended_at ? (r.duration ?? '—') : <span className="text-amber-800">{t('equipment.down.stillDown')}</span>,
        },
        {
            key: 'reason',
            header: t('equipment.down.colReason'),
            className: 'text-sm',
            // U1-B:作废的那一行 —— 原因划掉,下面一行是作废的理由(理由【不】划掉:那是现在仍然成立的话)。
            render: (r) => r.voided_at ? (
                <span className="block">
                    <span className="line-through">{r.reason}</span>
                    <span className="block text-xs text-[color:var(--brand-muted-text)]">
                        {t('equipment.down.voidedBecause', { reason: r.void_reason ?? '—', when: fmt(r.voided_at) })}
                    </span>
                </span>
            ) : r.reason,
        },
        {
            // ★ 动作列 —— priority: true(TABLE-STYLE-1 / R1:够不着的动作等于不存在)。
            // 【权限】看得见、按不动、带理由(PermissionGate)。【作废的行】一个钮都不画 —— 那是记录状态,不是权限。
            key: 'actions',
            header: '',
            priority: true,
            render: (r) => r.voided_at ? null : (
                <PermissionGate code="module.processing.edit" allowed={canEdit} inline>
                    <span className="inline-flex flex-wrap gap-1.5">
                        <Button variant="secondary" size="xs" type="button" disabled={pending}
                                onClick={() => {
                                    setError(null)
                                    setEditStartBad(false); setEditEndBad(false)
                                    setEditing({ id: r.id, startedAt: r.started_at, endedAt: r.ended_at, reason: r.reason })
                                }}>
                            {t('equipment.down.correct')}
                        </Button>
                        <ConfirmButton
                            subject={fmt(r.started_at)}
                            title={t('equipment.down.voidConfirm')}
                            body={t('equipment.down.voidConsequence')}
                            confirmLabel={t('equipment.down.void')}
                            tier="destructive"
                            reason={{ placeholder: t('equipment.down.voidReasonPlaceholder') }}
                            onConfirm={(reason) => run(() => voidDowntime({ assetId, downtimeId: r.id, reason }))}
                            disabled={pending}
                            triggerVariant="destructive"
                            triggerSize="xs"
                        >
                            {t('equipment.down.void')}
                        </ConfirmButton>
                    </span>
                </PermissionGate>
            ),
        },
    ]

    return (
        <div className="mb-8">
            <div className="flex items-baseline gap-3 mb-2">
                <h2 className="">{t('equipment.down.title')}</h2>
                {/* ★★ ALERT-2d ①:`canEdit && !openRow` 是【权限 × 记录状态】。
                       为假有两个完全不同的原因,而此前两个原因都只换来"钮不见了":
                         · 缺 module.processing.edit  → 去找管理员;
                         · 这台设备【已经有一段没结束的停机】 → 去把那一段结掉。
                       第二句今天写在琥珀块里(oneOpenOnly),可它被一层
                       PermissionGate 罩着 —— 于是没有权限的人两句都读不到。 */}
                {!openRow ? (
                    <PermissionGate code="module.processing.edit" allowed={canEdit} inline>
                        <Button variant="secondary" size="xs" type="button" onClick={() => setOpen(!open)} disabled={pending}>
                            {t('equipment.down.add')}
                        </Button>
                    </PermissionGate>
                ) : (
                    <span className="text-xs text-[color:var(--brand-muted-text)]" data-state-note="downtime-open">
                        {t('equipment.down.oneOpenOnly')}
                    </span>
                )}
            </div>
            {!canEdit && <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('equipment.needsProcessingEdit')}</p>}
            {error && <p className="text-red-600 text-xs mb-2">{error}</p>}

            {/* ── 开着的那一段:自己一块,不混在流水里 ─────────────────────────── */}
            {openRow && (
                <div className="border-2 border-amber-400 bg-amber-50 rounded p-3 mb-3 text-sm">
                    <p className="font-medium text-amber-900">
                        {t('equipment.down.openNow', { since: fmt(formatAuditStamp(openRow.started_at)) })}
                    </p>
                    <p className="text-[color:var(--brand-text)] mt-1">{openRow.reason}</p>
                    {/* 【时长这一栏说"还在停",不是空白、不是 0】—— duration 的列注释
                        说的正是这件事:NULL 不是零,是"还不知道"。 */}
                    <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('equipment.down.stillDown')}</p>
                    <PermissionGate code="module.processing.edit" allowed={canEdit}>
                        <div className="flex flex-wrap gap-2 items-end mt-2">
                            <label className="block">
                                <span className="text-xs text-[color:var(--brand-muted-text)] block">{t('equipment.down.endedAt')}</span>
                                <DatePicker kind="datetime" value={endAt} onChange={setEndAt} onInvalidChange={setEndBad} />
                            </label>
                            <Button size="xs" type="button" disabled={pending || !endAt || endBeforeStart || endBad}
                                    onClick={() => run(() => closeDowntime({ assetId, downtimeId: openRow.id, endedAt: endAt }))}>
                                {t('equipment.down.close')}
                            </Button>
                            {/* FIX-2(F):【禁用了就说为什么 —— 每一个条件各一句】
                                此前只有"没填"那一句。**填了一个早于开始的时刻时,
                                按钮是【能点】的**,人点下去才换来一次数据库拒绝 ——
                                屏幕全程没说过那件事。现在当场说,并且不让它点。 */}
                            {!endAt && <span className="text-xs text-[color:var(--brand-muted-text)]">{t('equipment.down.needEnd')}</span>}
                            {endAt && endBeforeStart && (
                                <span className="text-xs text-amber-700">
                                    {t('equipment.down.endBeforeStart', { start: fmt(formatAuditStamp(openRow.started_at)) })}
                                </span>
                            )}
                        </div>
                    </PermissionGate>
                    {/* 【为什么这里没有"再开一段"的按钮】说出来,不要让人以为按钮坏了。 */}
                    <PermissionGate code="module.processing.edit" allowed={canEdit}>
                        <p className="text-xs text-[color:var(--brand-muted-text)] mt-2">{t('equipment.down.oneOpenOnly')}</p>
                    </PermissionGate>
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
                    // U1-B:作废的那一行发灰(与 CostEntriesTable 冲销行同一个灰),不发琥珀 —— 它不是开着的。
                    rowClassName={(r) => (r.voided_at ? 'text-gray-400' : r.ended_at === null ? 'bg-amber-50' : undefined)}
                    empty={t('equipment.down.none')}
                />
            </div>

            {/* ★ U1-B:更正那一块。与"开一段"那一块同一条理由【不再套一层 PermissionGate】——
                   它里面有【取消】,而 editing 只能由上面那个已经上了闸的「更正」钮翻成非空。 */}
            {editing && editingRow && !editingRow.voided_at && (
                <div className="border border-gray-400 rounded p-3 text-sm space-y-2 max-w-xl mb-3" data-downtime-correct={editing.id}>
                    <p className="font-medium">{t('equipment.down.correctTitle', { since: fmt(editingRow.started_at) })}</p>
                    <label className="block">
                        <span className="text-xs text-[color:var(--brand-muted-text)] block">{t('equipment.down.startedAt')}</span>
                        <DatePicker kind="datetime" value={editing.startedAt}
                                    onChange={(v) => setEditing({ ...editing, startedAt: v })} onInvalidChange={setEditStartBad} />
                    </label>
                    {editing.endedAt !== null ? (
                        <label className="block">
                            <span className="text-xs text-[color:var(--brand-muted-text)] block">{t('equipment.down.endedAt')}</span>
                            <DatePicker kind="datetime" value={editing.endedAt}
                                        onChange={(v) => setEditing({ ...editing, endedAt: v })} onInvalidChange={setEditEndBad} />
                        </label>
                    ) : (
                        // 开着的那一段:结束时刻不在这里填 —— 说出来,不要让人以为框丢了。
                        <p className="text-xs text-[color:var(--brand-muted-text)]">{t('equipment.down.correctOpenHint')}</p>
                    )}
                    <label className="block">
                        <span className="text-xs text-[color:var(--brand-muted-text)] block">{t('equipment.down.reason')}</span>
                        <input value={editing.reason} onChange={(e) => setEditing({ ...editing, reason: e.target.value })}
                               className={`${CONTROL_INPUT} w-full`} />
                    </label>
                    <div className="flex flex-wrap gap-2 items-center">
                        <Button size="xs" type="button"
                                disabled={pending || !editing.startedAt || editStartBad || !editing.reason.trim()
                                    || (editing.endedAt !== null && (!editing.endedAt || editEndBad || editEndBeforeStart))}
                                onClick={() => run(() => correctDowntime({
                                    assetId, downtimeId: editing.id, startedAt: editing.startedAt,
                                    endedAt: editing.endedAt, reason: editing.reason,
                                }))}>
                            {t('common.save')}
                        </Button>
                        {/* FIX-2(F):每一个禁用条件各一句。 */}
                        {!editing.startedAt && <span className="text-xs text-amber-700">{t('equipment.down.needStart')}</span>}
                        {editing.endedAt !== null && !editing.endedAt && (
                            <span className="text-xs text-amber-700">{t('equipment.down.needEnd')}</span>
                        )}
                        {editEndBeforeStart && (
                            <span className="text-xs text-amber-700">
                                {t('equipment.down.endBeforeStart', { start: fmt(editing.startedAt) })}
                            </span>
                        )}
                        {!editing.reason.trim() && <span className="text-xs text-amber-700">{t('equipment.down.needReason')}</span>}
                        <Button variant="secondary" size="xs" type="button" disabled={pending}
                                onClick={() => { setEditing(null); setError(null) }}>
                            {t('common.cancel')}
                        </Button>
                    </div>
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('equipment.down.correctHint')}</p>
                </div>
            )}

            {/* ★ ALERT-2d ④(a):`open` 是【这一次会话的开合位】,不是一句拒绝 ——
                   它和权限挤在一个 && 里,于是"没权限"只能表现成整块不见。
                   改法是**闸归闸、开合归开合**:权限的闸装在【打开它的那个钮】上
                   (上面那处),`open` / `!openRow` 照旧管这一块开不开。

                   ★【为什么这一块自己【不】再套一层 PermissionGate】★
                     它里面有一个【取消】钮,而 DBLOCK-1 量出来的第一条边界正是
                     「**永远不要闸住一个用来关掉东西的控件**」—— `fieldset disabled`
                     会把取消一起禁掉,人于是被关在一个既提交不了、也关不掉的表单里。
                     (DBLOCK-1 当场在 CloseReopenControls / MaintenancePanel /
                      VoidInvoiceControl 三处踩到过。)
                     而这里也【不需要】那一层:`open` 只能由上面那个已经上了闸的钮
                     翻成 true,没有权限的人根本走不到这一块。 */}
            {open && !openRow && (
                <div className="border border-gray-400 rounded p-3 text-sm space-y-2 max-w-xl">
                    <label className="block">
                        <span className="text-xs text-[color:var(--brand-muted-text)] block">{t('equipment.down.startedAt')}</span>
                        {/* 【不预填"现在"】停机是世界那一侧的事实 —— 谁都可能过后才来补录。 */}
                        <DatePicker kind="datetime" value={f.startedAt}
                                    onChange={(v) => setF({ ...f, startedAt: v })} onInvalidChange={setStartBad} />
                    </label>
                    <label className="block">
                        <span className="text-xs text-[color:var(--brand-muted-text)] block">{t('equipment.down.reason')}</span>
                        <input value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })}
                               className={`${CONTROL_INPUT} w-full`} />
                    </label>
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('equipment.down.openHint')}</p>
                    <div className="flex gap-2 items-center">
                        <Button size="xs" type="button" disabled={pending || !f.startedAt || !f.reason.trim() || startBad}
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
