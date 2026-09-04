'use client'

import { useState, useTransition } from 'react'
import Link from 'next/link'
import {
    saveContainerHead, attachShipment, detachShipment,
    addMilestone, instantiateDocuments, setDocumentStatus, addDocument,
} from './actions'

type Ship = { id: string; code: string; ship_date: string; order_code: string; customer: string }
type Ms = { id: string; milestone: string; event_date: string; note: string | null; label: string }
type Doc = { id: string; document_type: string; regime: string | null; status: string; na_reason: string | null; from_lane: boolean }

export default function ContainerPanels({
    containerId, head, forwarders, hasLane, laneChecklistState, attached, attachable, operativeIds,
    milestones, documents, milestoneTypes, labels,
}: {
    containerId: string
    head: { container_number: string | null; vessel: string | null; voyage: string | null; bl_number: string | null; notes: string | null; expected_arrival_date: string | null
            forwarder_id: string | null; forwarder_name: string | null }
    forwarders: { id: string; name: string }[]
    /** CTN-OP:每一种里程碑里【算数】的那一条的 id(operativeMilestone.ts 判定) */
    operativeIds: string[]
    hasLane: boolean
    laneChecklistState: string
    attached: Ship[]; attachable: Ship[]
    milestones: Ms[]; documents: Doc[]
    milestoneTypes: { value: string; label: string }[]
    labels: Record<string, string>
}) {
    const [error, setError] = useState<string | null>(null)
    const [pending, start] = useTransition()
    const [detaching, setDetaching] = useState<string | null>(null)
    const field = 'rounded border border-gray-300 px-2 py-1 text-sm'
    const run = (fn: () => Promise<unknown>, after?: () => void) =>
        start(async () => {
            const res = await fn()
            if (res && typeof res === 'object' && 'error' in res) setError((res as { error: string }).error)
            else { setError(null); after?.() }
        })

    return (
        <>
            {error && <div className="mb-4 rounded border border-red-400 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>}

            {/* ── 头 ── */}
            <section className="border-t pt-6">
                <h2 className="mb-3 text-xl font-bold">{labels.headHeading}</h2>
                <form
                    className="flex max-w-4xl flex-wrap items-end gap-3"
                    onSubmit={(e) => { e.preventDefault(); const d = new FormData(e.currentTarget)
                        run(() => saveContainerHead(containerId, {
                            container_number: (d.get('container_number') as string)?.trim() || null,
                            vessel: (d.get('vessel') as string)?.trim() || null,
                            voyage: (d.get('voyage') as string)?.trim() || null,
                            bl_number: (d.get('bl_number') as string)?.trim() || null,
                            notes: (d.get('notes') as string)?.trim() || null,
                            // 【清空 → null】—— 撤回一个估计是"没有 ETA",不是一个错误
                            expected_arrival_date: (d.get('expected_arrival_date') as string)?.trim() || null,
                            // 【清回"不指定" → null】—— 承运方还没定是一个真实的状态
                            forwarder_id: (d.get('forwarder_id') as string)?.trim() || null,
                        })) }}
                >
                    <div><label className="block text-xs font-medium mb-1">{labels.containerNumber}</label>
                        <input name="container_number" defaultValue={head.container_number ?? ''} className={field} /></div>
                    <div><label className="block text-xs font-medium mb-1">{labels.vessel}</label>
                        <input name="vessel" defaultValue={head.vessel ?? ''} className={field} /></div>
                    <div><label className="block text-xs font-medium mb-1">{labels.voyage}</label>
                        <input name="voyage" defaultValue={head.voyage ?? ''} className={`${field} w-24`} /></div>
                    <div><label className="block text-xs font-medium mb-1">{labels.bl}</label>
                        <input name="bl_number" defaultValue={head.bl_number ?? ''} className={field} /></div>
                    {/* 【承运方:免柜期与报价都按它去查】所以它必须在这一页上改得动 ——
                        此前这一页既不显示也不能改它,而免柜期那一行却有一句
                        "箱子没有指定货代" —— 一句指着一个没有门的字段的话。 */}
                    <div><label className="block text-xs font-medium mb-1">{labels.forwarderLabel}</label>
                        <select name="forwarder_id" defaultValue={head.forwarder_id ?? ''} className={field}>
                            <option value="">{labels.forwarderNone}</option>
                            {forwarders.map((f) => (
                                <option key={f.id} value={f.id}>{f.name}</option>
                            ))}
                        </select></div>
                    {/* 【世界那一侧的日期:永不预填】没有 defaultValue 的兜底,
                        没有"默认今天",空着就是空着 —— 与 event_date 那条列注释同一条规矩。 */}
                    <div><label className="block text-xs font-medium mb-1">{labels.etaLabel}</label>
                        <input type="date" name="expected_arrival_date"
                            defaultValue={head.expected_arrival_date ?? ''} className={field} /></div>
                    <div className="min-w-[16rem] flex-1"><label className="block text-xs font-medium mb-1">{labels.notes}</label>
                        <input name="notes" defaultValue={head.notes ?? ''} className={`${field} w-full`} /></div>
                    <button disabled={pending} className="rounded bg-blue-600 px-3 py-1 text-sm text-white disabled:opacity-50">{labels.save}</button>
                </form>
                {/* 【开航日不在这里改】—— 它在 DB 上没有开口子给按列放行,改它要另一条路 */}
                <p className="mt-2 text-xs text-gray-500">{labels.blHint}</p>
                <p className="mt-1 text-xs text-gray-500 max-w-3xl">{labels.etaHint}</p>
                <p className="mt-1 text-xs text-gray-500 max-w-3xl">{labels.forwarderHint}</p>
                {/* 【设了就把它显示成一个门牌】—— 报价与免柜天数编辑在货代那一页,
                    所以这里给出去那一页的路,而不只是一个名字。 */}
                {head.forwarder_id && head.forwarder_name && (
                    <p className="mt-2 text-sm">
                        <span className="text-gray-500">{labels.forwarderLabel}: </span>
                        <Link href={`/logistics/forwarders/${head.forwarder_id}`}
                            className="text-blue-700 hover:underline">{head.forwarder_name}</Link>
                    </p>
                )}
            </section>

            {/* ── 装着的发货单 ── */}
            <section className="mt-8 border-t pt-6">
                <h2 className="mb-3 text-xl font-bold">{labels.shipmentsHeading}</h2>
                {attached.length === 0 ? (
                    <p className="text-sm text-gray-500">{labels.shipmentsEmpty}</p>
                ) : (
                    <table className="mb-4 w-full border-collapse border border-gray-300 text-sm">
                        <tbody>
                            {attached.map((s) => (
                                <tr key={s.id}>
                                    <td className="border border-gray-300 px-3 py-1">
                                        <Link href={`/sales/shipments/${s.id}`} className="font-mono text-xs text-blue-700 hover:underline">{s.code}</Link>
                                    </td>
                                    <td className="border border-gray-300 px-3 py-1 font-mono text-xs">{s.order_code}</td>
                                    <td className="border border-gray-300 px-3 py-1">{s.customer}</td>
                                    <td className="border border-gray-300 px-3 py-1">{s.ship_date}</td>
                                    <td className="border border-gray-300 px-3 py-1">
                                        {detaching === s.id ? (
                                            <form
                                                className="flex items-center gap-2"
                                                onSubmit={(e) => { e.preventDefault(); const d = new FormData(e.currentTarget)
                                                    run(() => detachShipment(containerId, s.id, (d.get('reason') as string) ?? ''),
                                                        () => setDetaching(null)) }}
                                            >
                                                {/* 【理由由服务端说了算】:这里【不加 required】,空白判定与库里的 btrim 一致 ——
                                                    两处各判一次,迟早给出两个答案。 */}
                                                <input name="reason" placeholder={labels.detachReason} className={`${field} w-64`} />
                                                <button disabled={pending} className="text-xs text-red-700 hover:underline">{labels.detach}</button>
                                            </form>
                                        ) : (
                                            <button type="button" disabled={pending} onClick={() => setDetaching(s.id)}
                                                className="text-xs text-red-700 hover:underline">{labels.detach}</button>
                                        )}
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                )}

                {attachable.length === 0 ? (
                    <p className="text-sm text-gray-600">{labels.attachEmpty}</p>
                ) : (
                    /* ★ CONV-10:这一行【转换前不换行】(flex,没有 flex-wrap),而它里面的
                       <select> 按【最宽的那个 option】定宽 —— option 的文本是
                       「单号 · 订单号 · 客户名」三段拼起来的,客户名一长,整页就被
                       这一个 select 顶出去。探针给这一页的判词是 +90px,culprit 是它旁边
                       那个 bg-blue-600 的按钮 —— 按钮是【被挤出去的那个】,不是撑宽的那个。
                       flex-wrap 让按钮换行;max-w-full/min-w-0 让 select 不能超过容器。
                       ☞ 这一页此前【就在那 9 条 404 名单里】(§⑬-1e):它一直是坏的,
                         而旧尺子把它记成「可用」。 */
                    <form
                        className="flex flex-wrap items-end gap-2"
                        onSubmit={(e) => { e.preventDefault(); const d = new FormData(e.currentTarget)
                            run(() => attachShipment(containerId, d.get('shipment_id') as string)) }}
                    >
                        <select name="shipment_id" required className={`${field} max-w-full min-w-0`}>
                            {attachable.map((s) => (
                                <option key={s.id} value={s.id}>{s.code} · {s.order_code} · {s.customer}</option>
                            ))}
                        </select>
                        <button disabled={pending} className="rounded bg-blue-600 px-3 py-1 text-sm text-white disabled:opacity-50">{labels.attach}</button>
                    </form>
                )}
            </section>

            {/* ── 里程碑 ── */}
            <section className="mt-8 border-t pt-6">
                <h2 className="mb-2 text-xl font-bold">{labels.milestonesHeading}</h2>
                <p className="mb-3 max-w-3xl text-sm text-gray-600">{labels.correctionNote}</p>
                <form
                    className="mb-4 flex flex-wrap items-end gap-2"
                    onSubmit={(e) => { e.preventDefault(); const f = e.currentTarget; const d = new FormData(f)
                        run(() => addMilestone(containerId, {
                            milestone: d.get('milestone') as string,
                            event_date: d.get('event_date') as string,
                            note: (d.get('note') as string)?.trim() || null,
                        }), () => f.reset()) }}
                >
                    <div><label className="block text-xs font-medium mb-1">{labels.milestone}</label>
                        <select name="milestone" required className={field}>
                            {milestoneTypes.map((m) => <option key={m.value} value={m.value}>{m.label}</option>)}
                        </select></div>
                    <div><label className="block text-xs font-medium mb-1">{labels.eventDate} <span className="text-red-600">*</span></label>
                        {/* 【没有 defaultValue】—— 世界那一侧的日期,系统不代填 */}
                        <input type="date" name="event_date" required className={field} /></div>
                    <div className="min-w-[16rem] flex-1"><label className="block text-xs font-medium mb-1">{labels.milestoneNote}</label>
                        <input name="note" className={`${field} w-full`} /></div>
                    <button disabled={pending} className="rounded bg-blue-600 px-3 py-1 text-sm text-white disabled:opacity-50">{labels.addMilestone}</button>
                </form>
                <p className="mb-3 text-xs text-gray-500">{labels.eventDateHint}</p>

                {milestones.length === 0 ? (
                    <p className="text-sm text-gray-500">{labels.milestonesEmpty}</p>
                ) : (
                    <ol className="space-y-1 text-sm">
                        {milestones.map((m) => {
                            // ════════════════════════════════════════════════════════
                            // 【此前这里算错了,而且恰好把真相说反】旧写法是
                            //   findIndex(同类型) !== i —— 即"在【当前显示顺序】里
                            //   第一次出现的那条是原始行"。而列表是按 event_date 排的,
                            //   于是【日期最晚】的那条被当成原始行(不打标),
                            //   后录的更正反而被打上 ↺。Tim 正是这么把顶行读成了系统的答案。
                            // 现在:算数的那条由 operativeMilestone.ts 判定
                            //   (recorded_at DESC, id DESC —— 与库里那两支臂同一条规则),
                            //   显示顺序【一个字没动】,仍然按事件日读。
                            // ════════════════════════════════════════════════════════
                            const isOperative = operativeIds.includes(m.id)
                            return (
                                <li key={m.id}
                                    className={'flex gap-3 border-l-2 pl-3 '
                                        + (isOperative ? 'border-gray-400' : 'border-gray-200 text-gray-400')}>
                                    <span className={'font-mono text-xs w-24 ' + (isOperative ? 'text-gray-600' : 'text-gray-400')}>
                                        {m.event_date}
                                    </span>
                                    <span className={isOperative ? 'font-medium' : ''}>{m.label}</span>
                                    {isOperative
                                        ? <span className="rounded bg-emerald-100 px-1.5 text-xs text-emerald-900">{labels.milestoneOperative}</span>
                                        : <span className="rounded bg-gray-100 px-1.5 text-xs text-gray-500">↺ {labels.milestoneSuperseded}</span>}
                                    {m.note && <span>{m.note}</span>}
                                </li>
                            )
                        })}
                    </ol>
                )}
                {milestones.length > 0 && (
                    <p className="mt-3 max-w-3xl text-xs text-gray-600">{labels.milestoneLegend}</p>
                )}
            </section>

            {/* ── 单据 ── */}
            <section className="mt-8 border-t pt-6">
                <h2 className="mb-2 text-xl font-bold">{labels.documentsHeading}</h2>

                {/* 【航段清单的三种状态,三句不同的话】 */}
                {!hasLane && <p className="mb-3 text-sm text-gray-500">{labels.noLane}</p>}
                {hasLane && laneChecklistState === 'not_defined' && (
                    <p className="mb-3 rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">{labels.notDefined}</p>
                )}
                {hasLane && laneChecklistState === 'defined_empty' && (
                    <p className="mb-3 rounded border border-gray-300 bg-gray-50 px-3 py-2 text-sm text-gray-700">{labels.definedEmpty}</p>
                )}
                {/* 【第六种沉默,而且是最容易被读错的那一种】航段【有】清单,
                    却从没被复制到这个箱子上 —— 下面那张表因此是空的。
                    不说出来,它读起来就是"这一票不需要单据",而那正好相反。 */}
                {hasLane && laneChecklistState === 'defined' && documents.length === 0 && (
                    <p className="mb-3 rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">
                        {labels.checklistDefinedNotInstantiated}
                    </p>
                )}
                {hasLane && (
                    <button type="button" disabled={pending} onClick={() => run(() => instantiateDocuments(containerId))}
                        className="mb-4 rounded border px-3 py-1 text-sm">{labels.instantiate}</button>
                )}

                {documents.length > 0 && (
                    <table className="mb-4 w-full border-collapse border border-gray-300 text-sm">
                        <tbody>
                            {documents.map((d) => (
                                <tr key={d.id} className={d.from_lane ? '' : 'bg-gray-50'}>
                                    <td className="border border-gray-300 px-3 py-1">
                                        {d.document_type}
                                        {d.regime && <span className="ml-2 text-xs text-gray-500">({d.regime})</span>}
                                        {/* 清单来的 vs 人后加的,看得出来 */}
                                        <span className="ml-2 text-xs text-gray-400">
                                            {d.from_lane ? labels.fromLane : labels.handAdded}
                                        </span>
                                    </td>
                                    <td className="border border-gray-300 px-3 py-1">
                                        <form
                                            className="flex items-center gap-2"
                                            onSubmit={(e) => { e.preventDefault(); const dd = new FormData(e.currentTarget)
                                                run(() => setDocumentStatus(containerId, d.id,
                                                    dd.get('status') as string,
                                                    ((dd.get('na_reason') as string) ?? '') || null)) }}
                                        >
                                            <select name="status" defaultValue={d.status} className={field}>
                                                <option value="pending">{labels.statusPending}</option>
                                                <option value="received">{labels.statusReceived}</option>
                                                <option value="not_applicable">{labels.statusNa}</option>
                                            </select>
                                            {/* 理由框一直在:n/a 要不要理由由服务端判,与库里那条守卫同一个答案 */}
                                            <input name="na_reason" defaultValue={d.na_reason ?? ''}
                                                placeholder={labels.naReason} className={`${field} w-56`} />
                                            <button disabled={pending} className="text-xs text-blue-700 hover:underline">{labels.save}</button>
                                        </form>
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                )}

                <form
                    className="flex flex-wrap items-end gap-2"
                    onSubmit={(e) => { e.preventDefault(); const f = e.currentTarget; const d = new FormData(f)
                        run(() => addDocument(containerId, d.get('document_type') as string,
                            (d.get('regime') as string)?.trim() || null), () => f.reset()) }}
                >
                    <div><label className="block text-xs font-medium mb-1">{labels.documentType}</label>
                        <input name="document_type" required className={field} /></div>
                    <div><label className="block text-xs font-medium mb-1">{labels.regime}</label>
                        <input name="regime" className={field} /></div>
                    <button disabled={pending} className="rounded bg-blue-600 px-3 py-1 text-sm text-white disabled:opacity-50">{labels.addDocument}</button>
                </form>
            </section>
        </>
    )
}
