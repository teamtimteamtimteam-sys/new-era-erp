// COMM-1:新建一份佣金协议。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import CommissionForm, { type Agent, type Currency } from '../CommissionForm'

export default async function NewCommissionPage() {
    const denied = await requireModule(MOD.suppliers)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    // 【只列 service_vendor】—— 守卫在库里也拒(guard_commission_agreement_agent),
    // 这里收窄名单是为了不让人选出一个必然被拒的对手方。两道,不是一道。
    const agents = mustRows(
        await supabase.from('suppliers')
            .select('id, code, legal_name')
            .eq('counterparty_type', 'service_vendor')
            .is('deleted_at', null)
            .order('code'),
        'suppliers') as Agent[]
    const currencies = mustRows(
        await supabase.from('currencies').select('code').order('code'),
        'currencies') as Currency[]

    return (
        <div className="p-8">
            <h1 className="text-2xl font-bold mb-4">{t('commissions.newTitle')}</h1>
            <CommissionForm agents={agents} currencies={currencies} />
        </div>
    )
}
