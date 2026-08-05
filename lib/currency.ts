// lib/currency.ts
// 【本位币是数据,不是常量】
//
// 界面里写死币种已经连栽四次:NewPaymentForm 的 `currency === 'USD' ? 1 : …`
// (FIN-12)、手工凭证表单同一句(本文件修的这次)、以及一堆 `!== 'SGD'` 的显示
// 判断。根源是同一个:FIN-0 把本位币从 USD 改成 SGD,而这些常量没人记得改,
// 也没有任何东西会因此失败。
//
// 所以本位币从 currencies.is_base 取,一次请求内缓存。服务端组件/动作直接
// await getBaseCurrency();客户端组件由页面把它当 prop 传进去。
// scripts/check-currency-literals.mjs 保证不会再冒出新的写死处。
import { cache } from 'react'
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'

export const getBaseCurrency = cache(async (): Promise<string> => {
    const supabase = await createClient()
    const rows = mustRows(
        await supabase.from('currencies').select('code, is_base').eq('is_base', true),
        'currencies base'
    )
    // 没有本位币是配置坏了,不是"没数据" —— 不许悄悄回退成某个字面量
    if (rows.length !== 1) {
        throw new Error(`currencies.is_base 应恰好一行,实得 ${rows.length} 行`)
    }
    return rows[0].code as string
})

export const getCurrencyCodes = cache(async (): Promise<string[]> => {
    const supabase = await createClient()
    return mustRows(
        await supabase.from('currencies').select('code').order('code'),
        'currencies'
    ).map((r) => r.code as string)
})

// 银行账户 ↔ 本币的对照表在 lib/currencyMap.ts(纯函数,客户端也能引)
export { bankAccountFor, currencyOfBank } from '@/lib/currencyMap'
