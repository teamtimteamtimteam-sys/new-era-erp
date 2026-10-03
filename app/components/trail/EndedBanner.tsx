// app/components/trail/EndedBanner.tsx
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1b-1(Tim 的 Q21 · Q8)· 一条【已经结束】的记录的横幅 —— 注销了的批次、回滚了的加工单
// ════════════════════════════════════════════════════════════════════════════
// 【为什么有它】这几种记录以前一结束就 404,而那正是它们的审计记录最要紧的时候(AT-0 §1 第 7 条)。
//   现在页面照常打开、一律只读,顶上这一条说它是【什么时候、被谁】结束的,第二行是理由。
// 【措辞】"Written off on DD/MM/YYYY by <name>" / "Reversed on DD/MM/YYYY by <name>";没有记人的只说日期,
//   不猜(Q8)。英文专用,与审计记录同一份目录(lib/trail/text.ts)。
// 【AUDIT-TRAIL-1b-3(Q9 · Q21)多了一种:删掉的记录】"Deleted on DD/MM/YYYY by <name>" —— 删掉的客户、供应商、物料、
//   定价公式,与删掉的销售订单、报价、采购单。前四种从来没有记过谁删的,"谁"取自变更记录(deleted_records 视图),
//   读不到就只说日期,绝不拿 updated_by 去猜。只有持 data.view_deleted 的人走得到这里(页面先问,别人得到一句具名拒绝)。
// 【人名的规矩与别的页面同一条】(折入 1)loadActorNames:不持 module.hr.view 的读者只认得出他自己,
//   别人画成 Restricted —— 与 ActorName、与审计记录里的"谁"逐字同一个答案。
// 【只读】页面把可以改的那一部分包进 <EndedFieldset>:<fieldset disabled> 让里面每一个控件都按不下去,
//   而且在无障碍树里读作"已禁用"(DBLOCK-1 的同一个机制);理由就是这一条横幅(aria-describedby)。
//   链接不受 fieldset 影响 —— 打印、标签、查看别的单据照常可用。
// ════════════════════════════════════════════════════════════════════════════
import type { ReactNode } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { loadActorNames } from '@/app/components/ActorName'
import { Refusal } from '@/app/components/ui/refusal'
import { TRAIL_TEXT } from '@/lib/trail/text'
import { fill } from '@/lib/trail/render'
import { formatTrailStamp } from '@/lib/dates'
import { mustOne } from '@/lib/db-helpers'

export const ENDED_BANNER_ID = 'ended-record-banner'

// AUDIT-TRAIL-1c-1(Tim 的 Q8,2026-10-03):账上的单据 —— 作废的发票 "Voided on DD/MM/YYYY by <name>";冲销了的分录、
//   收付款、费用 "Reversed on DD/MM/YYYY by <name>"(谁、何时取自冲销那一张新单的建立 —— 原单上没有冲销戳);
//   多一行链到那张冲销单("Reversed by PMT-…",link)。注销了的批次在应付页上也是这一条(Q5)。
// AUDIT-TRAIL-1c-2(Tim 的 Q7 · Q6 · Q8,2026-10-03):撤回了的汇率 "Withdrawn on DD/MM/YYYY by <name>"(谁、为什么取自那一行
//   'withdrawn' 修改史 —— 汇率表上没有撤回人);删掉的对账单走 DeletedBanner(种类 bank_statement);冲销了的运费单
//   "Reversed on … by …"(它自己的 reversed_at / reversed_by)+ 链到冲销分录的那一行。
export default async function EndedBanner({ kind, at, by, reason, link }: {
    kind: 'writtenOff' | 'reversed' | 'deleted' | 'voided' | 'withdrawn'
    /** 第三行:链到冲销那一张单据(可选)—— "Reversed by PMT-…" */
    link?: { code: string; href: string } | null
    /** 结束的时刻(deleted_at) */
    at: string
    /** 结束它的登录账号(deleted_by);没有记人就是 null */
    by: string | null
    reason: string | null
}) {
    const supabase = await createClient()
    const names = await loadActorNames(supabase, [by])
    const name = by ? names.names.get(by) ?? null : null
    const date = formatTrailStamp(at).slice(0, 10)
    // 认得出 → 名字;认不出而读者看不了人事 → Restricted(别的页面上也是受限);没有记人、或那个账号已经不属于任何人 → 只说日期
    const who: ReactNode | null = name ? name : by && names.restricted ? <Refusal>{TRAIL_TEXT.restricted}</Refusal> : null
    const withWho = { writtenOff: 'banner.writtenOff', reversed: 'banner.reversed', deleted: 'banner.deleted', voided: 'banner.voided',
        withdrawn: 'banner.withdrawn' } as const
    const dateOnly = { writtenOff: 'banner.writtenOffDate', reversed: 'banner.reversedDate', deleted: 'banner.deletedDate', voided: 'banner.voidedDate',
        withdrawn: 'banner.withdrawnDate' } as const
    const [before, after] = (who === null
        ? fill(TRAIL_TEXT[dateOnly[kind]], { date })
        : fill(TRAIL_TEXT[withWho[kind]], { date, who: '\u0000' })).split('\u0000')
    const [reversedByBefore, reversedByAfter] = fill(TRAIL_TEXT['banner.reversedBy'], { code: '\u0000' }).split('\u0000')
    return (
        <div id={ENDED_BANNER_ID} role="status" data-ended-banner={kind}
             className="mb-4 max-w-3xl rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-[color:var(--brand-text)]">
            <p className="font-medium">
                {before}
                {who !== null && <>{who}{after}</>}
            </p>
            {reason && reason.trim() && (
                <p className="mt-0.5 break-words">
                    <span className="text-[color:var(--brand-muted-text)]">{TRAIL_TEXT.reason}: </span>
                    <span data-trail-typed="">{reason}</span>
                </p>
            )}
            {link && (
                <p className="mt-0.5">
                    {reversedByBefore}<Link href={link.href} className="app-link hover:underline">{link.code}</Link>{reversedByAfter}
                </p>
            )}
        </div>
    )
}

/** AUDIT-TRAIL-1c-1(Q8):一张冲销单(镜像)—— 它冲的是哪一张。不是一条"结束了"的记录,所以是灰的,不是琥珀色的 */
export function ReversalOfBanner({ code, href }: { code: string; href: string }) {
    const [before, after] = fill(TRAIL_TEXT['banner.reversalOf'], { code: '\u0000' }).split('\u0000')
    return (
        <div data-reversal-of="" className="mb-4 max-w-3xl rounded border border-gray-300 bg-gray-50 px-3 py-2 text-sm text-[color:var(--brand-text)]">
            {before}<Link href={href} className="app-link hover:underline">{code}</Link>{after}
        </div>
    )
}

/** 一条结束了的记录:里面每一个控件都按不下去,理由是上面那条横幅 */
export function EndedFieldset({ ended, children }: { ended: boolean; children: ReactNode }) {
    if (!ended) return <>{children}</>
    return (
        <fieldset disabled aria-describedby={ENDED_BANNER_ID} data-ended-readonly="" className="m-0 min-w-0 border-0 p-0">
            {children}
        </fieldset>
    )
}

/** deleted_records 里的种类(db/views/deleted_records.sql 的 record_kind)—— 1b-3 打开的那七种 + 1c-2 的对账单(Q6) */
export type DeletedKind = 'customer' | 'supplier' | 'material' | 'pricing_formula' | 'sales_order' | 'quote' | 'purchase_order' | 'bank_statement'

/** 删掉的记录的横幅:时刻、谁、理由都从 deleted_records 读 —— 与 /settings/deleted 同一份答案。
 *  那四类从来没有记过谁删的,视图从变更记录里读;读不到(早于变更记录)就只说日期。
 *  视图那一行读不到时(不该发生:能进这一页的人都持那一类的模块码)退回页面手里的 deleted_at,仍然只说日期,不猜人。 */
export async function DeletedBanner({ kind, id, at }: { kind: DeletedKind; id: string; at: string }) {
    const supabase = await createClient()
    const row = mustOne(
        await supabase.from('deleted_records').select('deleted_at, deleted_by, delete_reason')
            .eq('record_kind', kind).eq('record_id', id).maybeSingle(),
        'deleted_records') as { deleted_at: string; deleted_by: string | null; delete_reason: string | null } | null
    return <EndedBanner kind="deleted" at={row?.deleted_at ?? at} by={row?.deleted_by ?? null} reason={row?.delete_reason ?? null} />
}

