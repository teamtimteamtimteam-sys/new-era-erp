// SO-4b:新建报价(服务端壳)。取数与 /sales/orders/new 同形。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { requireEditPermission } from '@/app/components/moduleGuard'
import Subnav from '@/app/sales/Subnav'
import NewQuoteForm from './NewQuoteForm'

export default async function NewQuotePage() {
    const denied = await requireEditPermission('module.sales.edit', 'nav.sales')
    if (denied) return denied

    const supabase = await createClient()
    // 【客户不按 status 过滤,这是有意的】customers.status 是自由文本、默认
    // 'draft',而且全库没有任何一处按它把关 —— 报价本来就是发给还没成为客户的人
    // 的东西(SO-4 调查里的"潜在客户地基"那一条)。按它过滤会把这一刀最有用的
    // 场景挡在外面。
    const customers = mustRows(
        await supabase.from('customers').select('id, code, legal_name')
            .is('deleted_at', null).order('code'),
        'customers') as unknown as { id: string; code: string; legal_name: string }[]
    const materials = mustRows(
        await supabase.from('materials').select('id, code, name')
            .is('deleted_at', null).order('code'),
        'materials') as unknown as { id: string; code: string; name: string }[]
    const currencies = mustRows(
        await supabase.from('currencies').select('code').order('code'),
        'currencies') as unknown as { code: string }[]

    return (
        <>
            <Subnav />
            <NewQuoteForm customers={customers} materials={materials}
                          currencies={currencies.map((c) => c.code)} />
        </>
    )
}
