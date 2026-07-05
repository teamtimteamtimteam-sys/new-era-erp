'use server'

// 手工分录:并列数组表单字段(account_code[]/side[]/currency[]/amount_ccy[]/fx_rate[]/line_memo[])
// 组装 lines jsonb → rpc post_journal_entry(source 'manual')。平衡由 DB 的延迟触发器
// 在提交时强制(JOURNAL_UNBALANCED 从 rpc 错误里回来,本地化后展示)。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizeFinanceError } from '../../financeErrorCodes'

export type CreateEntryState = {
    error?: string
    fieldErrors?: Record<string, string>
}

export async function createManualEntry(
    _prevState: CreateEntryState,
    formData: FormData
): Promise<CreateEntryState> {
    const t = await getTranslations()

    const entry_date = (formData.get('entry_date') as string)?.trim() || ''
    const memo = (formData.get('memo') as string)?.trim() || ''

    const accountCodes = formData.getAll('account_code').map(String)
    const sides = formData.getAll('side').map(String)
    const currencies = formData.getAll('currency').map(String)
    const amounts = formData.getAll('amount_ccy').map(String)
    const fxRates = formData.getAll('fx_rate').map(String) // USD 行提交空 hidden,保持位置对齐
    const lineMemos = formData.getAll('line_memo').map(String)

    const fieldErrors: Record<string, string> = {}
    if (!entry_date || Number.isNaN(Date.parse(entry_date))) {
        fieldErrors.entry_date = t('finance.errDate')
    }
    if (!memo) {
        fieldErrors.memo = t('finance.errMemo')
    }

    // 行校验(与 DB 二道防线一致,先给友好的字段级错误)
    type Line = {
        account_code: string
        side: string
        currency: string
        amount_ccy: number
        fx_rate?: number
        line_memo?: string
    }
    const lines: Line[] = []
    for (let i = 0; i < accountCodes.length; i++) {
        const rowNo = i + 1
        if (!accountCodes[i]) {
            fieldErrors[`line_${i}`] = t('finance.errAccount', { row: rowNo })
            continue
        }
        const amount = Number(amounts[i])
        if (!amounts[i] || Number.isNaN(amount) || amount <= 0) {
            fieldErrors[`line_${i}`] = t('finance.errAmount', { row: rowNo })
            continue
        }
        const currency = currencies[i] || 'USD'
        let fx_rate: number | undefined
        if (currency !== 'USD') {
            const fx = Number(fxRates[i])
            if (!fxRates[i] || Number.isNaN(fx) || fx <= 0) {
                fieldErrors[`line_${i}`] = t('finance.errors.FX_RATE_REQUIRED', { 0: currency })
                continue
            }
            fx_rate = fx
        }
        lines.push({
            account_code: accountCodes[i],
            side: sides[i] === 'credit' ? 'credit' : 'debit',
            currency,
            amount_ccy: amount,
            fx_rate,
            line_memo: lineMemos[i]?.trim() || undefined,
        })
    }
    if (lines.length < 2 && Object.keys(fieldErrors).length === 0) {
        fieldErrors.lines = t('finance.errMinLines')
    }

    if (Object.keys(fieldErrors).length > 0) {
        return { fieldErrors }
    }

    const supabase = await createClient()
    const { data, error } = await supabase.rpc('post_journal_entry', {
        p_entry_date: entry_date,
        p_memo: memo,
        p_source_type: 'manual',
        // 手工分录无来源单据;生成的 Args 类型把 uuid 参数标成必填 string,SQL 端可空
        p_source_id: null as unknown as string,
        p_lines: lines,
    })

    if (error) {
        return { error: await localizeFinanceError(error.message) }
    }

    const entryId = (data as { entry_id?: string } | null)?.entry_id

    revalidatePath('/finance')
    revalidatePath('/finance/journal')

    if (entryId) {
        redirect(`/finance/journal/${entryId}`)
    }
    redirect('/finance/journal')
}
