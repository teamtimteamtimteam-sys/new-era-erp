// app/finance/freight/new/page.tsx
// 录一张运费单(服务端壳):取货代候选 + 可分摊的在册进料批次。
import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency, getCurrencyCodes } from '@/lib/currency'
import { mustRows } from '@/lib/db-helpers'
import NewFreightForm, { type BatchOption } from './NewFreightForm'
import Subnav from '../../Subnav'
import { requireEditPermission } from '@/app/components/moduleGuard'

export default async function NewFreightPage() {
    // 【写页面按 module.finance.edit 把关】—— 与 metal_prices 那四页同一条规矩:
    // 守卫跟着数据自己的 RLS 走,而 freight_documents 的写策略就是这个码。
    const denied = await requireEditPermission('module.finance.edit', 'finance.subnav.freight')
    if (denied) return denied

    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    const currencies = await getCurrencyCodes()

    const suppliers = mustRows(
        // LOG-1b:【反向过滤】运费的收款方只能是货代。这一处与其它十一处方向相反,
        // 所以它单独写在这里,而不是复用那条排除条件。
        await supabase.from('suppliers').select('id, code, legal_name')
            .is('deleted_at', null).eq('status', 'active')
            .eq('counterparty_type', 'forwarder').order('legal_name'),
        'suppliers'
    ) as { id: string; code: string; legal_name: string }[]

    // 可分摊的批次:在册的进料批。【已被消耗的也要在列】—— 迟到的运费是主路径,
    // 那批货很可能早就加工完卖掉了,不列出来就等于把主路径关在门外。
    const batches = mustRows(
        await supabase.from('inbound_batches_masked')
            .select('id, code, quantity, unit, remaining_qty, unit_price, arrival_date')
            .is('deleted_at', null)
            .order('arrival_date', { ascending: false, nullsFirst: false })
            .limit(200),
        'inbound_batches_masked'
    ) as unknown as BatchOption[]

    return (
        <div className="p-8">
            <Subnav />
            <NewFreightForm
                suppliers={suppliers}
                batches={batches}
                currencies={currencies}
                baseCurrency={baseCurrency}
            />
        </div>
    )
}
