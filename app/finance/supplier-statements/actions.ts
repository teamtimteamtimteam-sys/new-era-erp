'use server'

// MES-8a(2026-10-16,MES-0 Q79 · MES-8 Step 0 Q7 · Q8):供应商对账单清单页上的两个动作。
//   【预览与签发读的是【同一支】函数】supplier_statement_data —— issue_supplier_statement 内部调的也是它(AGENTS.md「预览一次过账,就去问数据库」)。
//   这里一行算术都没有。签发之前先过一遍 PDF 字体守卫(供应商名字里有字体画不出的字,签发了也印不出来 —— 号不该为一份印不出的纸铸出去)。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { mustOne } from '@/lib/db-helpers'
import { refuseFromCoded, type ActionOutcome } from '@/lib/action-refusal'
import { findUnrenderableText, coverageErrorMessage } from '@/lib/pdfFontCoverage'
import { localizeSupplierStatementError } from './supplierStatementErrorCodes'

export async function previewSupplierStatement(supplierId: string, from: string, to: string):
    Promise<ActionOutcome & { data?: unknown }> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('supplier_statement_data', {
        p_supplier_id: supplierId, p_from: from || (null as unknown as string), p_to: to || (null as unknown as string),
    })
    if (error) return await refuseFromCoded(error.message, localizeSupplierStatementError)
    return { success: true, data }
}

export async function issueSupplierStatement(supplierId: string, from: string, to: string, supersedeReason: string):
    Promise<ActionOutcome & { statementId?: string }> {
    const supabase = await createClient()
    const sup = mustOne(await supabase.from('supplier_lookup').select('legal_name').eq('id', supplierId).maybeSingle(), 'supplier_lookup') as
        { legal_name: string } | null
    if (sup) {
        const bad = findUnrenderableText([{ where: 'supplier legal_name', text: sup.legal_name }])
        if (bad.length > 0) return { error: coverageErrorMessage(bad) }
    }
    const reason = (supersedeReason ?? '').trim()
    const { data, error } = await supabase.rpc('issue_supplier_statement', {
        p_supplier_id: supplierId, p_from: from || (null as unknown as string), p_to: to || (null as unknown as string),
        ...(reason !== '' ? { p_supersede_reason: reason } : {}),
    })
    if (error) return await refuseFromCoded(error.message, localizeSupplierStatementError)
    revalidatePath('/finance/supplier-statements')
    return { success: true, statementId: (data as { statement_id?: string } | null)?.statement_id }
}
