import { getTranslations } from '@/lib/i18n/server'
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import Subnav from '@/app/finance/Subnav'
import NewOrderForm from './NewOrderForm'
import { can } from '@/lib/permissions'

export default async function NewSalesOrderPage() {
    const denied = await requireModule(MOD.finance)
    if (denied) return denied
    await getTranslations()
    const supabase = await createClient()

    const customers = mustRows(
        await supabase.from('customers').select('id, code, legal_name').is('deleted_at', null).order('code'),
        'customers')
    const materials = mustRows(
        await supabase.from('materials').select('id, code, name').is('deleted_at', null).order('code'),
        'materials')
    const currencies = mustRows(await supabase.from('currencies').select('code').order('code'), 'currencies')

    // SAL-B6:信用面板与销售面板读【同一份】customer_credit_status。
    // 【无 module.customers.view 的读者拿不到行,而不是拿到 0】—— 0 在信用面板上
    // 读作"没有限额、余额充足",是这个管控最危险的失败。所以要分辨"受限"与"零"。
    // SAL-B6 同一条:读得到信用行的前提是 module.customers.view(与 SalePanel 一致)
    const seeCredit = await can('module.customers.view')
    const credit = seeCredit
        ? mustRows(
              await supabase.from('customer_credit_status')
                  .select('customer_id, credit_limit_base, credit_hold, exposure_base, headroom_base, sales_blocked'),
              'customer_credit_status')
        : []

    return (
        <>
            <Subnav />
            <NewOrderForm customers={customers as { id: string; code: string; legal_name: string }[]}
                          materials={materials as { id: string; code: string; name: string }[]}
                          currencies={(currencies as { code: string }[]).map((c) => c.code)}
                          credit={credit as never[]}
                          canSeeCredit={seeCredit} />
        </>
    )
}
