'use client'

import { useState, useTransition } from 'react'
import Link from 'next/link'
import { Button } from '@/app/components/ui/button'
import {
    saveContainerHead, attachShipment, detachShipment,
    addMilestone, instantiateDocuments, setDocumentStatus, addDocument,
} from './actions'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { DatePicker } from '@/app/components/ui/date-picker'
import { formatDate } from '@/lib/dates'
import { useLocale } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xDate, xText } from '@/lib/export/cells'

type Ship = {
    id: string; code: string; ship_date: string; order_code: string; customer: string
    /** TABLE-EXPORT-3c(Tim 2026-10-25):上面三格是画给人看的(日期已格式化、空值已写成「—」);导出读这三个原始值 */
    ship_date_raw: string | null; order_code_raw: string | null; customer_raw: string | null
}
type Ms = { id: string; milestone: string; event_date: string; note: string | null; label: string }
type Doc = { id: string; document_type: string; regime: string | null; status: string; na_reason: string | null; from_lane: boolean }

export default function ContainerPanels({
    containerId, containerCode, head, forwarders, hasLane, laneChecklistState, attached, attachable, operativeIds,
    milestones, documents, milestoneTypes, labels,
canEdit
}: {
    containerId: string
    /** TABLE-EXPORT-3c(Tim 2026-10-25):两张表导出的 About 表写明是哪只箱子 */
    containerCode: string
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

canEdit: boolean
}) {
    const locale = useLocale()
    const [error, setError] = useState<string | null>(null)
    const [pending, start] = useTransition()
    const [detaching, setDetaching] = useState<string | null>(null)
    // 日期框不认 form.reset()(它的字在 React 状态里)—— 加完一条里程碑换一个 key 让它重新挂载、回到空
    const [msKey, setMsKey] = useState(0)
    const field = CONTROL_INPUT
    const fieldSelect = CONTROL_SELECT
    const run = (fn: () => Promise<unknown>, after?: () => void) =>
        start(async () => {
            const res = await fn()
            if (res && typeof res === 'object' && 'error' in res) setError((res as { error: string }).error)
            else { setError(null); after?.() }
        })

    // ════════════════════════════════════════════════════════════════════════
    // TABLE-EXPORT-3c(Tim 2026-10-25):两张手搓表换成 DataTable,各带一对导出(Tim 批准重建)。
    // ════════════════════════════════════════════════════════════════════════
    // 【装着的发货单】手机上留的列一个没改:单号 · 客户 · 拆离钮;订单号与发货日进展开区
    //   (转换前就是这两列 hidden sm:table-cell、叠在单号格里)—— 那段手写的叠放拿掉了,组件自己画展开区。
    //   发货日导出读原始日期(xDate),不读那串格式化过的字。拆离那一列是控件 → exportAs:false。
    const shipColumns: ExportableColumn<Ship>[] = [
        {
            key: 'code', header: labels.colShipmentCode, priority: true,
            render: (s) => <Link href={`/sales/shipments/${s.id}`} className="text-xs hover:underline app-link">{s.code}</Link>,
            exportAs: (s) => xText(s.code),
        },
        {
            key: 'order', header: labels.colOrderCode,
            render: (s) => <span className="text-xs text-[color:var(--brand-muted-text)]">{s.order_code}</span>,
            exportAs: (s) => xText(s.order_code_raw),
        },
        { key: 'customer', header: labels.colCustomer, priority: true, render: (s) => s.customer, exportAs: (s) => xText(s.customer_raw) },
        {
            key: 'shipDate', header: labels.colShipDate, singleValue: true,
            render: (s) => (s.ship_date_raw ? formatDate(s.ship_date_raw, locale) : '—'),
            exportAs: (s) => xDate(s.ship_date_raw),
        },
        {
            // 第五列是拆离钮,它自己带着字 —— 按 /finance/close 那一条先例不另造表头文案(TABLE-PHONE-5)。
            // R1:画的是要按的控件 → priority。
            key: 'detach', header: '', priority: true,
            exportAs: false,
            render: (s) => detaching === s.id ? (
                <PermissionGate code="module.purchasing.edit" allowed={canEdit}>
                <form
                    className="flex items-center gap-2"
                    onSubmit={(e) => { e.preventDefault(); const d = new FormData(e.currentTarget)
                        run(() => detachShipment(containerId, s.id, (d.get('reason') as string) ?? ''),
                            () => setDetaching(null)) }}
                >
                    {/* 【理由由服务端说了算】:这里【不加 required】,空白判定与库里的 btrim 一致 ——
                        两处各判一次,迟早给出两个答案。 */}
                    <input name="reason" placeholder={labels.detachReason} className={`${field} w-64`} />
                    <Button variant="destructive" size="inline" disabled={pending} className="text-xs">{labels.detach}</Button>
                </form>
                </PermissionGate>
            ) : (
                <Button variant="destructive" size="inline" type="button" disabled={pending}
                    onClick={() => setDetaching(s.id)} className="text-xs">{labels.detach}</Button>
            ),
        },
    ]

    // 【单据清单】转换前没有表头:一格叠着 单据类型 (制度) 来源,一格是改状态的表单。
    //   ★ 导出要的是【存下来的】状态(与 na_reason),不是下拉框里此刻选着的那个(Tim 2026-10-25)——
    //     所以状态与不适用理由各成一列,画的是存下来的值;下拉 + 理由框 + 保存留在它自己那一列,是控件(exportAs:false)。
    //   制度与来源也拆成各自一列(一格只能装一个值;叠在一起导出只能留主值,会丢掉这两件事)。
    //   【手机】留 单据类型 · 状态 · 改状态的控件(R1);制度 · 来源 · 理由进展开区。
    const statusLabel = (st: string) =>
        st === 'pending' ? labels.statusPending
            : st === 'received' ? labels.statusReceived
            : st === 'not_applicable' ? labels.statusNa
            : st
    const docColumns: ExportableColumn<Doc>[] = [
        { key: 'type', header: labels.documentType, priority: true, render: (d) => d.document_type, exportAs: (d) => xText(d.document_type) },
        {
            key: 'regime', header: labels.regime,
            render: (d) => d.regime ? <span className="text-xs text-gray-500">{d.regime}</span> : '—',
            exportAs: (d) => xText(d.regime),
        },
        {
            key: 'source', header: labels.colDocSource, singleValue: true,
            render: (d) => <span className="text-xs text-gray-400">{d.from_lane ? labels.fromLane : labels.handAdded}</span>,
            exportAs: (d) => xText(d.from_lane ? labels.fromLane : labels.handAdded),
        },
        { key: 'status', header: labels.colDocStatus, priority: true, singleValue: true, render: (d) => statusLabel(d.status), exportAs: (d) => xText(statusLabel(d.status)) },
        { key: 'naReason', header: labels.naReason, render: (d) => d.na_reason ?? '—', exportAs: (d) => xText(d.na_reason) },
        {
            key: 'setStatus', header: '', priority: true,
            // 改状态的表单 —— 控件,不是数据;存下来的值在上面两列
            exportAs: false,
            render: (d) => (
                <PermissionGate code="module.purchasing.edit" allowed={canEdit}>
                <form
                    className="flex items-center gap-2"
                    onSubmit={(e) => { e.preventDefault(); const dd = new FormData(e.currentTarget)
                        run(() => setDocumentStatus(containerId, d.id,
                            dd.get('status') as string,
                            ((dd.get('na_reason') as string) ?? '') || null)) }}
                >
                    <select name="status" defaultValue={d.status} className={fieldSelect}>
                        <option value="pending">{labels.statusPending}</option>
                        <option value="received">{labels.statusReceived}</option>
                        <option value="not_applicable">{labels.statusNa}</option>
                    </select>
                    {/* 理由框一直在:n/a 要不要理由由服务端判,与库里那条守卫同一个答案 */}
                    <input name="na_reason" defaultValue={d.na_reason ?? ''}
                        placeholder={labels.naReason} className={`${field} w-56`} />
                    <Button variant="link" size="inline" disabled={pending} className="text-xs">{labels.save}</Button>
                </form>
                </PermissionGate>
            ),
        },
    ]

    return (
        <>
            {error && <div className="mb-4 rounded border border-red-400 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>}

            {/* ── 头 ── */}
            <section className="border-t pt-6">
                <h2 className="mb-3">{labels.headHeading}</h2>
                <PermissionGate code="module.purchasing.edit" allowed={canEdit}>
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
                    <div><label className="block mb-1">{labels.containerNumber}</label>
                        <input name="container_number" defaultValue={head.container_number ?? ''} className={field} /></div>
                    <div><label className="block mb-1">{labels.vessel}</label>
                        <input name="vessel" defaultValue={head.vessel ?? ''} className={field} /></div>
                    <div><label className="block mb-1">{labels.voyage}</label>
                        <input name="voyage" defaultValue={head.voyage ?? ''} className={`${field} w-24`} /></div>
                    <div><label className="block mb-1">{labels.bl}</label>
                        <input name="bl_number" defaultValue={head.bl_number ?? ''} className={field} /></div>
                    {/* 【承运方:免柜期与报价都按它去查】所以它必须在这一页上改得动 ——
                        此前这一页既不显示也不能改它,而免柜期那一行却有一句
                        "箱子没有指定货代" —— 一句指着一个没有门的字段的话。 */}
                    <div><label className="block mb-1">{labels.forwarderLabel}</label>
                        <select name="forwarder_id" defaultValue={head.forwarder_id ?? ''} className={fieldSelect}>
                            <option value="">{labels.forwarderNone}</option>
                            {forwarders.map((f) => (
                                <option key={f.id} value={f.id}>{f.name}</option>
                            ))}
                        </select></div>
                    {/* 【世界那一侧的日期:永不预填】没有 defaultValue 的兜底,
                        没有"默认今天",空着就是空着 —— 与 event_date 那条列注释同一条规矩。 */}
                    <div><label className="block mb-1">{labels.etaLabel}</label>
                        <DatePicker name="expected_arrival_date"
                            defaultValue={head.expected_arrival_date ?? ''} /></div>
                    <div className="min-w-[16rem] flex-1"><label className="block mb-1">{labels.notes}</label>
                        <input name="notes" defaultValue={head.notes ?? ''} className={`${field} w-full`} /></div>
                    <Button variant="default" className="text-sm" disabled={pending}>{labels.save}</Button>
                </form>
                </PermissionGate>
                {/* 【开航日不在这里改】—— 它在 DB 上没有开口子给按列放行,改它要另一条路 */}
                <p className="mt-2 text-xs text-[color:var(--brand-muted-text)]">{labels.blHint}</p>
                <p className="mt-1 text-xs text-[color:var(--brand-muted-text)] max-w-3xl">{labels.etaHint}</p>
                <p className="mt-1 text-xs text-[color:var(--brand-muted-text)] max-w-3xl">{labels.forwarderHint}</p>
                {/* 【设了就把它显示成一个门牌】—— 报价与免柜天数编辑在货代那一页,
                    所以这里给出去那一页的路,而不只是一个名字。 */}
                {head.forwarder_id && head.forwarder_name && (
                    <p className="mt-2 text-sm">
                        <span className="text-[color:var(--brand-muted-text)]">{labels.forwarderLabel}: </span>
                        <Link href={`/logistics/forwarders/${head.forwarder_id}`}
                            className="hover:underline app-link app-link-inline">{head.forwarder_name}</Link>
                    </p>
                )}
            </section>

            {/* ── 装着的发货单 ── */}
            <section className="mt-8 border-t pt-6">
                <h2 className="mb-3">{labels.shipmentsHeading}</h2>
                {attached.length === 0 ? (
                    <p className="text-sm text-[color:var(--brand-muted-text)]">{labels.shipmentsEmpty}</p>
                ) : (
                    <DataTable
                        rows={attached}
                        columns={shipColumns}
                        rowKey={(s) => s.id}
                        phone={{ mode: 'columns' }}
                        className="mb-4"
                        exportSpec={{ name: 'logistics-container-shipments', title: labels.shipmentsHeading,
                                      aboutExtra: [[labels.colContainerCode, containerCode]] }}
                    />
                )}

                {attachable.length === 0 ? (
                    <p className="text-sm text-[color:var(--brand-muted-text)]">{labels.attachEmpty}</p>
                ) : (
                    /* ★ CONV-10:这一行【转换前不换行】(flex,没有 flex-wrap),而它里面的
                       <select> 按【最宽的那个 option】定宽 —— option 的文本是
                       「单号 · 订单号 · 客户名」三段拼起来的,客户名一长,整页就被
                       这一个 select 顶出去。探针给这一页的判词是 +90px,culprit 是它旁边
                       那个 bg-blue-600 的按钮 —— 按钮是【被挤出去的那个】,不是撑宽的那个。
                       flex-wrap 让按钮换行;max-w-full/min-w-0 让 select 不能超过容器。
                       ☞ 这一页此前【就在那 9 条 404 名单里】(§⑬-1e):它一直是坏的,
                         而旧尺子把它记成「可用」。 */
                    <PermissionGate code="module.purchasing.edit" allowed={canEdit}>
                    <form
                        className="flex flex-wrap items-end gap-2"
                        onSubmit={(e) => { e.preventDefault(); const d = new FormData(e.currentTarget)
                            run(() => attachShipment(containerId, d.get('shipment_id') as string)) }}
                    >
                        <select name="shipment_id" required className={`${fieldSelect} max-w-full min-w-0`}>
                            {attachable.map((s) => (
                                <option key={s.id} value={s.id}>{s.code} · {s.order_code} · {s.customer}</option>
                            ))}
                        </select>
                        <Button variant="default" className="text-sm" disabled={pending}>{labels.attach}</Button>
                    </form>
                    </PermissionGate>
                )}
            </section>

            {/* ── 里程碑 ── */}
            <section className="mt-8 border-t pt-6">
                <h2 className="mb-2">{labels.milestonesHeading}</h2>
                <p className="mb-3 max-w-3xl text-sm text-[color:var(--brand-muted-text)]">{labels.correctionNote}</p>
                <form
                    className="mb-4 flex flex-wrap items-end gap-2"
                    onSubmit={(e) => { e.preventDefault(); const f = e.currentTarget; const d = new FormData(f)
                        run(() => addMilestone(containerId, {
                            milestone: d.get('milestone') as string,
                            event_date: d.get('event_date') as string,
                            note: (d.get('note') as string)?.trim() || null,
                        }), () => { f.reset(); setMsKey((k) => k + 1) }) }}
                >
                    <div><label className="block mb-1">{labels.milestone}</label>
                        <select name="milestone" required className={fieldSelect}>
                            {milestoneTypes.map((m) => <option key={m.value} value={m.value}>{m.label}</option>)}
                        </select></div>
                    <div><label className="block mb-1">{labels.eventDate} <span className="text-red-600">*</span></label>
                        {/* 【没有 defaultValue】—— 世界那一侧的日期,系统不代填 */}
                        <DatePicker key={msKey} name="event_date" required /></div>
                    <div className="min-w-[16rem] flex-1"><label className="block mb-1">{labels.milestoneNote}</label>
                        <input name="note" className={`${field} w-full`} /></div>
                    <Button variant="default" className="text-sm" disabled={pending}>{labels.addMilestone}</Button>
                </form>
                <p className="mb-3 text-xs text-[color:var(--brand-muted-text)]">{labels.eventDateHint}</p>

                {milestones.length === 0 ? (
                    <p className="text-sm text-[color:var(--brand-muted-text)]">{labels.milestonesEmpty}</p>
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
                                    <span className={'text-xs w-24 ' + (isOperative ? 'text-gray-600' : 'text-gray-400')}>
                                        {formatDate(m.event_date, locale)}
                                    </span>
                                    <span className={isOperative ? 'font-medium' : ''}>{m.label}</span>
                                    {isOperative
                                        ? <span className="rounded bg-emerald-100 px-1.5 text-xs text-emerald-900">{labels.milestoneOperative}</span>
                                        : <span className="rounded bg-gray-100 px-1.5 text-xs text-[color:var(--brand-muted-text)]">↺ {labels.milestoneSuperseded}</span>}
                                    {m.note && <span>{m.note}</span>}
                                </li>
                            )
                        })}
                    </ol>
                )}
                {milestones.length > 0 && (
                    <p className="mt-3 max-w-3xl text-xs text-[color:var(--brand-muted-text)]">{labels.milestoneLegend}</p>
                )}
            </section>

            {/* ── 单据 ── */}
            <section className="mt-8 border-t pt-6">
                <h2 className="mb-2">{labels.documentsHeading}</h2>

                {/* 【航段清单的三种状态,三句不同的话】 */}
                {!hasLane && <p className="mb-3 text-sm text-[color:var(--brand-muted-text)]">{labels.noLane}</p>}
                {hasLane && laneChecklistState === 'not_defined' && (
                    <p className="mb-3 rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">{labels.notDefined}</p>
                )}
                {hasLane && laneChecklistState === 'defined_empty' && (
                    <p className="mb-3 rounded border border-gray-300 bg-gray-50 px-3 py-2 text-sm text-[color:var(--brand-text)]">{labels.definedEmpty}</p>
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
                    <PermissionGate code="module.purchasing.edit" allowed={canEdit}>
                    <Button variant="secondary" className="mb-4 text-sm" type="button" disabled={pending} onClick={() => run(() => instantiateDocuments(containerId))}>{labels.instantiate}</Button>
                    </PermissionGate>
                )}

                {documents.length > 0 && (
                    <DataTable
                        rows={documents}
                        columns={docColumns}
                        rowKey={(d) => d.id}
                        phone={{ mode: 'columns' }}
                        className="mb-4"
                        // 清单来的 vs 人后加的,看得出来 —— 人后加的那几行仍然发灰,与转换前同
                        rowClassName={(d) => (d.from_lane ? undefined : 'bg-gray-50')}
                        exportSpec={{ name: 'logistics-container-documents', title: labels.documentsHeading,
                                      aboutExtra: [[labels.colContainerCode, containerCode]] }}
                    />
                )}

                <PermissionGate code="module.purchasing.edit" allowed={canEdit}>
                <form
                    className="flex flex-wrap items-end gap-2"
                    onSubmit={(e) => { e.preventDefault(); const f = e.currentTarget; const d = new FormData(f)
                        run(() => addDocument(containerId, d.get('document_type') as string,
                            (d.get('regime') as string)?.trim() || null), () => f.reset()) }}
                >
                    <div><label className="block mb-1">{labels.documentType}</label>
                        <input name="document_type" required className={field} /></div>
                    <div><label className="block mb-1">{labels.regime}</label>
                        <input name="regime" className={field} /></div>
                    <Button variant="default" className="text-sm" disabled={pending}>{labels.addDocument}</Button>
                </form>
                </PermissionGate>
            </section>
        </>
    )
}
