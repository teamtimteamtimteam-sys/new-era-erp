'use server'

// app/finance/wht/actions.ts
// WHT-1:汇缴动作。校验【全部】在数据库里 —— 页面不重复判断一遍
// (页面与服务端各写一份同一条规矩,是本仓库付过四次账的形状)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeWhtError } from '../whtErrorCodes'

export async function remitWht(
    periodMonth: string, remittedOn: string, reference: string,
    bankAccount: string, notes: string,
): Promise<{ error?: string; code?: string; amount?: number }> {
    const supabase = await createClient()
    // 【日期不给默认值,空就【干脆不传】】由数据库那条具名拒绝答话
    // (WHT_REMIT_DATE_REQUIRED)。送 '' 会在 cast 成 date 时炸出一个没有名字的
    // 错;在这里先判一次空,又成了同一条规矩的第二处实现 —— 两者都不要。
    // 与 fileGstReturn 逐字同一种处置(那一支的注释写着它是 fu2 才改对的)。
    const { data, error } = await supabase.rpc('remit_wht', {
        p_period_month: periodMonth,
        ...(remittedOn ? { p_remitted_on: remittedOn } : {}),
        ...(reference.trim() ? { p_filed_reference: reference.trim() } : {}),
        ...(bankAccount ? { p_bank_account: bankAccount } : {}),
        ...(notes.trim() ? { p_notes: notes.trim() } : {}),
    })
    if (error) return { error: await localizeWhtError(error.message) }
    revalidatePath('/finance/wht')
    revalidatePath('/')   // 首页那一支 wht_due 的谓词刚刚变了
    const row = data as { code?: string; amount_base?: number } | null
    return { code: row?.code, amount: row?.amount_base }
}
