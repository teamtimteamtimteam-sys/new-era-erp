'use server'

// FX-RATES-1:批量录入的服务端动作。**一笔事务、全有或全无** ——
// 它调的是 record_fx_rates_bulk,而那个函数【循环调用 record_fx_rate】,
// 一行校验都没有自己写。表格因此不可能比表单松:没有第二个地方可以放松。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { localizeFxError } from '../../fxErrorCodes'
import { revalidatePath } from 'next/cache'

export type BulkFxState = { error?: string; recorded?: number }

export type BulkCell = { currency: string; rate_date: string; rate_type: string; rate: string }

export async function recordFxRatesBulk(cells: BulkCell[]): Promise<BulkFxState> {
    const t = await getTranslations()
    const rows = cells
        .filter((c) => c.rate.trim() !== '')
        .map((c) => ({
            currency: c.currency,
            rate_date: c.rate_date,
            rate_type: c.rate_type,
            rate: c.rate.trim(),
        }))

    if (rows.length === 0) {
        return { error: t('finance.fxPage.bulk.errNothingEntered') }
    }

    const supabase = await createClient()
    const { data, error } = await supabase.rpc('record_fx_rates_bulk', { p_rows: rows })

    if (error) {
        // FX_BULK_ROW|<n>|<原始错误> —— 把行号摘出来,再把里面那条真错误本地化,
        // 于是人看到的是「第 3 行:那一天还没到…」而不是一串码。
        const m = error.message.match(/FX_BULK_ROW\|(\d+)\|(.*)$/)
        if (m) {
            return {
                error: t('finance.fxPage.bulk.rowError', {
                    0: m[1],
                    1: await localizeFxError(m[2]),
                }),
            }
        }
        return { error: await localizeFxError(error.message) }
    }

    revalidatePath('/finance/fx')
    revalidatePath('/finance/fx/bulk')
    return { recorded: (data as unknown as { recorded: number })?.recorded ?? rows.length }
}
