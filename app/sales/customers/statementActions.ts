'use server'

// app/sales/customers/statementActions.ts
// STATEMENT-1:客户档案页上那一段的服务端动作。
//
// 【预览与签发读的是【同一支】函数】customer_statement_data —— 这不是巧合,
// 是 AGENTS.md 那条规矩:预览一次过账的屏幕【要问数据库它会是什么】,
// 不许在 TypeScript 里重写一遍规则(这个仓库为这个形状付过四次账)。
// 所以这里两个动作都只是转发,一行算术都没有。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { localizeStatementError } from '@/app/finance/statements/statementErrorCodes'

export type StatementState = { error?: string; success?: boolean; statementId?: string }

export async function previewStatement(
    customerId: string, from: string, to: string,
): Promise<StatementState & { data?: unknown }> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('customer_statement_data', {
        p_customer_id: customerId, p_from: from, p_to: to,
    })
    if (error) return { error: await localizeStatementError(error.message) }
    return { success: true, data }
}

export async function issueStatement(
    customerId: string, from: string, to: string, supersedeReason: string | null,
): Promise<StatementState> {
    const supabase = await createClient()
    // 【没有理由时【不传这个参数】,而不是传 null】生成的类型把带默认值的参数
    // 标成可选(string | undefined)—— 传 null 过不了编译。而语义上两者一致:
    // 不传 = 用函数自己的默认值 NULL,也就是"这不是一次重出"。
    const reason = (supersedeReason ?? '').trim()
    const { data, error } = await supabase.rpc('issue_customer_statement', {
        p_customer_id: customerId, p_from: from, p_to: to,
        ...(reason !== '' ? { p_supersede_reason: reason } : {}),
    })
    if (error) return { error: await localizeStatementError(error.message) }
    revalidatePath(`/sales/customers/${customerId}`)
    return { success: true, statementId: (data as { statement_id?: string } | null)?.statement_id }
}
