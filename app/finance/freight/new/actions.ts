'use server'

// 运费单据的写入(FRT-1)。判据与过账全在 record_freight_document 里 ——
// 页面【不自己算分摊】,与 preview_revalue_foreign_balances / reprice_split 同一条:
// 两份算术会在写下的那天一致,此后各自漂移,而屏幕上那份是人相信的那份。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { localizeFreightError } from '../../freightErrorCodes'
import { getTranslations } from '@/lib/i18n/server'

export type FreightState = { error?: string }

export async function createFreightDocument(
    _prev: FreightState,
    formData: FormData
): Promise<FreightState> {
    const docDate = String(formData.get('doc_date') ?? '').trim()
    const supplierId = String(formData.get('supplier_id') ?? '').trim()
    const amount = String(formData.get('amount') ?? '').trim()
    const currency = String(formData.get('currency') ?? '').trim()
    const basis = String(formData.get('allocation_basis') ?? '').trim()
    const direction = String(formData.get('direction') ?? '').trim()
    // ★ PAY-REQ-1(Tim 2026-09-23):运费单恒为 unpaid —— 付款走付款申请(函数对 'paid' 按名拒)。
    const notes = String(formData.get('notes') ?? '').trim() || null

    // 并列数组:勾选的批次 + (stated 口径时)逐批金额
    // ★★ DRAFT-5(2026-09-21):两条按下标配对的并列数组 → 一座 JSON 桥
    //   (Tim 的 (b) 裁定)。**变的只有行从哪来** —— 下面那句映射一个字没改。
    //   ⚠ **`amount_base` 是【键在不在】,不是值**:只有 'stated' 那一支送它。
    //     原样保留 —— 另外两个口径由服务端自己按重量/价值算,
    //     送一个 null 过去会让「没填」和「不按这个口径」长得一模一样。
    //   ⚠ **读不懂的桥不当空集**:空集 = 一张一个批次都没摊到的运费单,
    //     而那是一次说不出话的提交,不是一次「谁都不摊」。按名拒。
    let allocations: { inbound_batch_id: string; amount_base?: string | null }[]
    try {
        const parsed: unknown = JSON.parse(String(formData.get('alloc_json') ?? '[]'))
        if (!Array.isArray(parsed)) throw new Error('not an array')
        allocations = parsed.flatMap((el) => {
            if (el === null || typeof el !== 'object') return []
            const row = el as Record<string, unknown>
            const id = String(row.inbound_batch_id ?? '')
            if (id === '') return []
            return [{
                inbound_batch_id: id,
                ...(basis === 'stated'
                    ? { amount_base: String(row.stated_amount ?? '').trim() || null }
                    : {}),
            }]
        })
    } catch {
        const tt = await getTranslations()
        return { error: tt('finance.freight.errAllocUnreadable') }
    }

    const supabase = await createClient()

    // ════════════════════════════════════════════════════════════════════════
    // LOG-4b:【两个方向,两个函数,没有共用的分支】。
    // 出口运费借 6300,进货运费借 1200/5000 —— 那不是同一件事的两种参数,
    // 是两件事。库里就是两个函数(record_export_freight_document 与
    // record_freight_document),这里照着分,不在页面上重新发明一个开关。
    // 【认不出的方向不猜】:直接送下去,让 direction 的 CHECK 按名拒。
    // ════════════════════════════════════════════════════════════════════════
    if (direction === 'outbound') {
        const containerId = String(formData.get('container_id') ?? '').trim()
        const { error } = await supabase.rpc('record_export_freight_document', {
            p_doc_date: docDate,
            p_supplier_id: supplierId,
            p_amount: amount ? Number(amount) : 0,
            p_currency: currency,
            p_payment_status: 'unpaid',
            // 【空字符串不是"没选"的合法表达】—— 空串送下去会被当成一个 uuid 解析失败;
            // 不选就是不送(docs/empty-string-to-rpc-audit.md 那一族)。
            p_container_id: containerId || undefined,
            p_notes: notes ?? undefined,
        })
        if (error) return { error: await localizeFreightError(error.message) }
        revalidatePath('/finance/freight')
        revalidatePath('/finance/payables')
        if (containerId) revalidatePath(`/logistics/containers/${containerId}`)
        redirect('/finance/freight')
    }

    const { error } = await supabase.rpc('record_freight_document', {
        // 必填项【不在这里兜底】:空值原样送下去,由 record_freight_document
        // 点名拒绝(FIN-10 的规矩 —— 决定期间与汇率的字段绝不给默认值)
        p_doc_date: docDate,
        p_supplier_id: supplierId,
        p_amount: amount ? Number(amount) : 0,
        p_currency: currency,
        p_allocation_basis: basis,
        p_payment_status: 'unpaid',
        p_allocations: allocations,
        p_notes: notes ?? undefined,
    })

    if (error) return { error: await localizeFreightError(error.message) }

    revalidatePath('/finance/freight')
    revalidatePath('/finance/payables')
    redirect('/finance/freight')
}
