// app/pricing/formulas/new/page.tsx
// 新建定价公式(服务端壳):取在册供应商/客户供"适用对象"下拉。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import FormulaForm, { EMPTY_FORMULA, type PartyOption } from '../FormulaForm'
import { createFormula } from '../actions'
import { mustRows } from '@/lib/db-helpers'

export default async function NewFormulaPage() {
    const supabase = await createClient()
    const t = await getTranslations()

    const [supRes, cusRes] = await Promise.all([
        supabase.from('suppliers').select('id, legal_name').is('deleted_at', null).order('legal_name'),
        supabase.from('customers').select('id, legal_name').is('deleted_at', null).order('legal_name'),
    ])

    const suppliers: PartyOption[] = (mustRows(supRes)).map((s) => ({ id: s.id, name: s.legal_name }))
    const customers: PartyOption[] = (mustRows(cusRes)).map((c) => ({ id: c.id, name: c.legal_name }))

    return (
        <div className="p-8">
            <h1 className="text-2xl font-bold mb-4">{t('pricing.new')}</h1>
            <Subnav />
            <FormulaForm
                action={createFormula}
                defaults={EMPTY_FORMULA}
                suppliers={suppliers}
                customers={customers}
            />
        </div>
    )
}
