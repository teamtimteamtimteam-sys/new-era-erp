'use server'

// CN-1:开一张贷项凭证。三条天花板、过账、留痕全在 create_credit_note 与触发器里 ——
// 页面【不自己判断能冲多少】。理由与本仓库其它写入路径同一条:两份判断会在写下的
// 那天一致、此后各自漂移,而屏幕上那两个上限只是【上一次渲染时】的快照。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { localizeCreditNoteError } from '../../creditNoteErrorCodes'
import { getTranslations } from '@/lib/i18n/server'

export type CreditNoteState = { error?: string }

type CnLine = { invoice_line_id: string; kind: string; amount: number; qty?: number | null }

export async function createCreditNote(
    invoiceId: string,
    _prev: CreditNoteState,
    formData: FormData
): Promise<CreditNoteState> {
    // 【单据日不在这里兜底】空的日期由 DB 点名拒(CN_NOTE_DATE_REQUIRED)——
    // 补一个今天会让留空比填对更容易通过(AGENTS.md 的日期规矩)。
    const noteDate = String(formData.get('note_date') ?? '').trim()
    const reason = String(formData.get('reason') ?? '').trim()

    // ★★ DRAFT-5(2026-09-21):四条按下标配对的并列数组 → 一座 JSON 桥
    //   (Tim 的 (b) 裁定)。**变的只有行从哪来** —— 下面整段循环体一个字没改:
    //   整行留空 = 这一行不冲;填了一半的行原样递过去,由 CN_LINE_INVALID
    //   点名是哪一格(在这里悄悄丢掉它,人会以为自己填过了)。
    //   ⚠ **`qty` 那一句的 `...(q === '' ? {} : { qty })` 是【键在不在】,不是值** ——
    //     写成 `null` 或 `undefined` 都不是同一件事。原样留着。
    //   ⚠ **读不懂的桥不当空集**:空集会让下面那个 `lines` 是空的,
    //     而 `create_credit_note` 收到一张没有行的凭证 —— 那是一次
    //     **说不出话的提交**,不是一次「哪一行都不冲」。按名拒。
    let slots: { invoice_line_id: string; kind: string; amount: string; qty: string }[]
    try {
        const parsed: unknown = JSON.parse(String(formData.get('cn_lines_json') ?? '[]'))
        if (!Array.isArray(parsed)) throw new Error('not an array')
        slots = parsed.flatMap((el) => {
            if (el === null || typeof el !== 'object') return []
            const row = el as Record<string, unknown>
            const id = String(row.invoice_line_id ?? '')
            return id === '' ? [] : [{
                invoice_line_id: id,
                kind: String(row.kind ?? ''),
                amount: String(row.amount ?? ''),
                qty: String(row.qty ?? ''),
            }]
        })
    } catch {
        const t = await getTranslations()
        return { error: t('cn.errLinesUnreadable') }
    }

    const lines: CnLine[] = []
    for (const slot of slots) {
        const raw = slot.amount.trim()
        // 【整行留空 = 这一行不冲】而填了一半的行【原样递过去】,由
        // CN_LINE_INVALID 点名是哪一格 —— 在这里悄悄丢掉它,人会以为自己填过了。
        if (raw === '') continue
        const q = slot.qty.trim()
        lines.push({
            invoice_line_id: slot.invoice_line_id,
            kind: slot.kind,
            amount: Number(raw),
            ...(q === '' ? {} : { qty: Number(q) }),
        })
    }

    const supabase = await createClient()
    const { data, error } = await supabase.rpc('create_credit_note', {
        p_invoice_id: invoiceId,
        // 【空串不是日期】空着交上来就让服务端按名拒(CN_NOTE_DATE_REQUIRED)——
        // 不在这里补一个今天。类型上该参数必填,所以空串经 null 断言递入
        // (与 create_order_invoice 的 p_issue_date 逐字同一个写法)。
        p_note_date: (noteDate.trim() === '' ? null : noteDate) as unknown as string,
        p_reason: reason,
        p_lines: lines,
    })

    if (error) return { error: await localizeCreditNoteError(error.message) }
    const cnId = (data as { credit_note_id: string } | null)?.credit_note_id
    // 【失败不是空集】RPC 成功却没带回 id 是一件不该发生的事;把它当成"开成了"
    // 会把人重定向到 /credit-notes/undefined —— IOD-2 那次 [object Object] 的形状。
    if (!cnId) return { error: 'create_credit_note returned no id' }

    revalidatePath(`/finance/invoices/${invoiceId}`)
    revalidatePath('/finance/receivables')
    redirect(`/finance/credit-notes/${cnId}`)
}
