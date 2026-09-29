'use client'
// app/components/trail/AuditTrailList.tsx
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1a(Tim 的 Q27 · Q29)· 审计记录的【版式】—— 每一页底部的那一段与 /settings/change-history 共用
// ════════════════════════════════════════════════════════════════════════════
// 【桌面】三栏 When · Who · What happened(汇总页多一栏 Record)。一次操作一条:标题一行,下面每个字段一行
//   "Label   old → new";子行各带一个小标题;理由永远在最后。
// 【收起】每条先给 4 行细节,其余"Show N more"就地展开;一段长文字截在 120 个字,后面一个"more"。
// 【390px】每条变成一张卡:标题在前,然后"时刻 · 人",然后每个字段自成一行、"old → new"在它下面。
// 【Restricted 与 (empty)】前者是一枚药丸(<Refusal>,与全站"受限"同一种画法),后者是灰字 —— 两件事永远分得开。
// 【为什么不是 <table>】一条记录的行数不固定(0 到几十行),而且在 390px 上要变成卡片;一张表会在手机上横向拖动
//   (批次审计记录转换前实测 281px)。所以它是一个有序列表,不进组件库的 <table> 棘轮。
// 【机器字】这里只印 lib/trail/render.ts 造好的句子。typed(人自己敲的字)包在 data-trail-typed 里 ——
//   冒烟的机器字断言跳过它们(一个人在备注里敲了什么,是他自己的话,Q8),其余每一个字都被扫。
// ════════════════════════════════════════════════════════════════════════════
import { useState } from 'react'
import Link from 'next/link'
import { Button } from '@/app/components/ui/button'
import { Refusal } from '@/app/components/ui/refusal'
import { TRAIL_TEXT } from '@/lib/trail/text'
import { fill, type Entry, type Line, type Val } from '@/lib/trail/render'

export type ViewEntry = Entry & { recordText?: string | null; recordHref?: string | null }

const DETAIL_LINES = 4

function ValueText({ v }: { v: Val }) {
    const [open, setOpen] = useState(false)
    if (v.restricted) return <Refusal>{TRAIL_TEXT.restricted}</Refusal>
    if (v.empty) return <span className="text-[color:var(--brand-muted-text)]">{v.text}</span>
    const text = open && v.full ? v.full : v.text
    return (
        <span className="break-words" {...(v.typed ? { 'data-trail-typed': '' } : {})}>
            {text}
            {v.full && (
                <>
                    {' '}
                    <Button type="button" variant="link" size="inline" onClick={() => setOpen(!open)}>
                        {open ? TRAIL_TEXT.less : TRAIL_TEXT.more}
                    </Button>
                </>
            )}
        </span>
    )
}

function LineRow({ line }: { line: Line }) {
    switch (line.t) {
        case 'heading':
            // AUDIT-TRAIL-1b-2:小标题后面可以跟一段人敲的字(文件名、联系人名字……)—— 与值里人敲的字同一种画法
            return <li className="mt-1 font-medium break-words">{line.text}{line.part && <> · <ValueText v={line.part} /></>}</li>
        case 'note':
            return <li className="text-[color:var(--brand-muted-text)]">{line.text}</li>
        case 'value':
            return (
                <li className="sm:grid sm:grid-cols-[minmax(8rem,12rem)_1fr] sm:gap-3">
                    <span className="block text-[color:var(--brand-muted-text)]">{line.label}</span>
                    <span className="block"><ValueText v={line.value} /></span>
                </li>
            )
        case 'change':
            return (
                <li className="sm:grid sm:grid-cols-[minmax(8rem,12rem)_1fr] sm:gap-3">
                    <span className="block text-[color:var(--brand-muted-text)]">{line.label}</span>
                    <span className="block">
                        <ValueText v={line.old} /> <span aria-hidden="true">→</span>
                        <span className="sr-only">{TRAIL_TEXT.srChangedTo}</span> <ValueText v={line.new} />
                    </span>
                </li>
            )
    }
}

function EntryTitle({ e }: { e: ViewEntry }) {
    return (
        <p className="font-medium break-words">
            {e.titleRestricted ? <Refusal>{TRAIL_TEXT.restricted}</Refusal> : <>{e.title}{e.titlePart && <> · <ValueText v={e.titlePart} /></>}</>}
        </p>
    )
}

/** 细节:前 4 行,其余"Show N more";理由永远最后 */
function EntryDetails({ e }: { e: ViewEntry }) {
    const [open, setOpen] = useState(false)
    const shown = open ? e.lines : e.lines.slice(0, DETAIL_LINES)
    const hidden = e.lines.length - shown.length
    if (!e.lines.length && !e.reason) return null
    return (
        <div className="min-w-0">
            {shown.length > 0 && <ul className="mt-1 space-y-0.5 text-sm">{shown.map((l, i) => <LineRow key={i} line={l} />)}</ul>}
            {hidden > 0 && (
                <Button type="button" variant="link" size="inline" className="mt-1 text-sm" onClick={() => setOpen(true)}>
                    {fill(TRAIL_TEXT.showMore, { n: hidden })}
                </Button>
            )}
            {open && e.lines.length > DETAIL_LINES && (
                <Button type="button" variant="link" size="inline" className="mt-1 text-sm" onClick={() => setOpen(false)}>
                    {TRAIL_TEXT.showLess}
                </Button>
            )}
            {e.reason && (
                <p className="mt-1 text-sm">
                    <span className="text-[color:var(--brand-muted-text)]">{TRAIL_TEXT.reason}: </span>
                    <ValueText v={e.reason} />
                </p>
            )}
        </div>
    )
}

function EntryBody({ e }: { e: ViewEntry }) {
    return (
        <div className="min-w-0">
            <EntryTitle e={e} />
            <EntryDetails e={e} />
        </div>
    )
}

function WhoText({ v }: { v: Val }) {
    return v.restricted ? <Refusal>{TRAIL_TEXT.restricted}</Refusal> : <span>{v.text}</span>
}

export default function AuditTrailList({
    entries,
    divider,
    withRecord = false,
}: {
    entries: ViewEntry[]
    /** 分界线上的那一句(变更记录开始之前那一段的上方);没有就不画 */
    divider?: string | null
    /** 汇总页:多一栏"Record" */
    withRecord?: boolean
}) {
    const firstPrelog = entries.findIndex((e) => e.prelog)
    const cols = withRecord
        ? 'sm:grid-cols-[9.5rem_minmax(7rem,10rem)_minmax(7rem,10rem)_1fr]'
        : 'sm:grid-cols-[9.5rem_minmax(7rem,11rem)_1fr]'
    return (
        <div className="text-sm">
            <div className={`hidden sm:grid ${cols} gap-3 border-b pb-1 text-xs font-medium text-[color:var(--brand-muted-text)]`}>
                <span>{TRAIL_TEXT['col.when']}</span>
                <span>{TRAIL_TEXT['col.who']}</span>
                {withRecord && <span>{TRAIL_TEXT['col.record']}</span>}
                <span>{TRAIL_TEXT['col.what']}</span>
            </div>
            <ol className="divide-y">
                {entries.map((e, i) => (
                    <li key={e.key} data-trail-entry="" className="py-2">
                        {i === firstPrelog && divider && (
                            <p data-trail-divider="" className="mb-2 border-y border-dashed py-1 text-xs text-[color:var(--brand-muted-text)]">
                                {divider}
                            </p>
                        )}
                        {/* 桌面:一行几栏 */}
                        <div className={`hidden sm:grid ${cols} gap-3`}>
                            <span className="tabular-nums whitespace-nowrap">{e.atText}</span>
                            <span className="break-words"><WhoText v={e.who} /></span>
                            {withRecord && (
                                <span className="break-words">
                                    {e.recordHref ? <Link className="app-link hover:underline" href={e.recordHref}>{e.recordText}</Link>
                                        : <span className={e.recordText ? '' : 'text-[color:var(--brand-muted-text)]'}>{e.recordText ?? TRAIL_TEXT['summary.noRecord']}</span>}
                                </span>
                            )}
                            <EntryBody e={e} />
                        </div>
                        {/* 390px:一张卡 —— 标题在前,然后"时刻 · 人" */}
                        <div className="sm:hidden space-y-1">
                            <EntryTitle e={e} />
                            <p className="text-xs text-[color:var(--brand-muted-text)]">
                                <span className="tabular-nums">{e.atText}</span> · <WhoText v={e.who} />
                                {withRecord && e.recordText && <> · {e.recordHref ? <Link className="app-link" href={e.recordHref}>{e.recordText}</Link> : e.recordText}</>}
                            </p>
                            <EntryDetails e={e} />
                        </div>
                    </li>
                ))}
            </ol>
        </div>
    )
}

export function OlderEntriesLink({ href }: { href: string }) {
    return (
        <p className="mt-2">
            <Link className="app-link hover:underline text-sm" href={href} scroll={false}>{TRAIL_TEXT.olderEntries}</Link>
        </p>
    )
}
