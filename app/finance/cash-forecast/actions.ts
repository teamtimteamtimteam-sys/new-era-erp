'use server'

// app/finance/cash-forecast/actions.ts
// CASHFLOW-1:预测页的服务端动作 —— 全部只是转发,一行算术都没有。
// AGENTS.md 那条(这个仓库为它付过四次账):要预览一次写入的屏幕
// 【要问数据库它会是什么】。预测尤其如此:期初、AR、AP 都是别处已经算好的数,
// 在这里再算一遍就是它们的第二份实现。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { localizeCashForecastError } from '../cashForecastErrorCodes'

export type ForecastState = { error?: string; success?: boolean }

export async function freezeForecast(
    weekStart: string, supersedeReason: string | null,
): Promise<ForecastState> {
    const supabase = await createClient()
    const reason = (supersedeReason ?? '').trim()
    const { error } = await supabase.rpc('freeze_cash_forecast', {
        p_week_start: weekStart,
        ...(reason !== '' ? { p_supersede_reason: reason } : {}),
    })
    if (error) return { error: await localizeCashForecastError(error.message) }
    revalidatePath('/finance/cash-forecast')
    return { success: true }
}

export async function saveForecastLine(input: {
    id?: string | null
    label: string; direction: string; amount: string; currency: string
    cadence: string; startDate: string; endDate?: string | null; isActive?: boolean
}): Promise<ForecastState> {
    const supabase = await createClient()
    const row = {
        label: input.label.trim(),
        direction: input.direction,
        amount_ccy: Number(input.amount),
        currency: input.currency,
        cadence: input.cadence,
        start_date: input.startDate,
        end_date: input.endDate && input.endDate !== '' ? input.endDate : null,
        is_active: input.isActive ?? true,
    }
    const { error } = input.id
        ? await supabase.from('cash_forecast_lines').update(row).eq('id', input.id)
        : await supabase.from('cash_forecast_lines').insert(row)
    if (error) return { error: await localizeCashForecastError(error.message) }
    revalidatePath('/finance/cash-forecast')
    return { success: true }
}

export async function setExpectedDate(
    termId: string, expectedDate: string | null, purchaseOrderId: string,
): Promise<ForecastState> {
    const supabase = await createClient()
    // 【不传 = 撤回那个估计】fu1 给了 p_expected_date 一个 DEFAULT NULL,
    // 于是生成的类型把它标成可选,这里不需要为了骗过编译器去强转类型。
    const d = (expectedDate ?? '').trim()
    const { error } = await supabase.rpc('set_payment_term_expected_date', {
        p_term_id: termId,
        ...(d !== '' ? { p_expected_date: d } : {}),
    })
    if (error) return { error: await localizeCashForecastError(error.message) }
    revalidatePath(`/purchasing/orders/${purchaseOrderId}`)
    revalidatePath('/finance/cash-forecast')
    return { success: true }
}
