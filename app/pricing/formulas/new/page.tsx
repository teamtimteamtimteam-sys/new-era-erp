// app/pricing/formulas/new/page.tsx
// 新建定价公式(服务端壳):取在册供应商/客户供"适用对象"下拉。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import FormulaForm, { EMPTY_FORMULA, type PartyOption, type QuoteDate } from '../FormulaForm'
import { createFormula } from '../actions'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function NewFormulaPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.pricing)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const [supRes, cusRes] = await Promise.all([
        supabase.from('suppliers').select('id, legal_name').is('deleted_at', null).order('legal_name'),
        supabase.from('customers').select('id, legal_name').is('deleted_at', null).order('legal_name'),
    ])

    const suppliers: PartyOption[] = (mustRows(supRes)).map((s) => ({ id: s.id, name: s.legal_name }))
    const customers: PartyOption[] = (mustRows(cusRes)).map((c) => ({ id: c.id, name: c.legal_name }))

    // 行情覆盖(最近一年,数据量极小):供表单当场说出"这两个基准现在算不算同一个数"。
    // 读 price_date 而不是 created_at —— 补录过的行情按【行情日】算窗口内外。
    const quoteRes = await supabase
        .from('metal_prices')
        .select('metal, price_date')
        .is('deleted_at', null)
        .gte('price_date', new Date(Date.now() - 365 * 86400000).toISOString().slice(0, 10))
        .order('price_date', { ascending: false })
    const quoteDates = mustRows(quoteRes) as QuoteDate[]


    return (
        <div className="p-8">
            <h1 className="text-2xl font-bold mb-4">{t('pricing.new')}</h1>
            <Subnav />
            <FormulaForm
                action={createFormula}
                defaults={EMPTY_FORMULA}
                suppliers={suppliers}
                customers={customers}
                quoteDates={quoteDates}
            />
        </div>
    )
}
