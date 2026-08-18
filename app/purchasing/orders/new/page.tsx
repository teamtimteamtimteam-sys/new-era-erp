// app/purchasing/orders/new/page.tsx
// 新建采购单(服务端壳):在册供应商(含默认付款条款模板)/ 在册物料 / 启用的采购向
// 计价公式 / 启用的付款条款模板(带行,供客户端套用与供应商默认自动带出)。
import Link from 'next/link'
import { getBaseCurrency } from '@/lib/currency'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import NewOrderForm, {
    type SupplierOption,
    type MaterialOption,
    type FormulaOption,
    type TemplateOption,
} from './NewOrderForm'
import { maskedRows } from '@/lib/maskedRows'
import type { Tables } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function NewOrderPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.purchasing)
    if (denied) return denied

    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    const t = await getTranslations()

    const [suppliersRes, materialsRes, formulasRes, templatesRes, tplLinesRes] = await Promise.all([
        supabase
            // SUP-TYPE-1b:【只列供货的供应商】——【但这里的理由与收货那两张不同,
            // 不要照抄】实测:purchase_orders 上【没有任何守卫】看 supplies_goods,
            // 所以开一张给房东的采购单,服务端是【收下的】。
            // 收窄它是一个【判断】,不是"别摆出会被拒的控件":
            // 一张永远收不到货的采购单没有意义 —— 收货那一侧会按名拒
            // (RECEIPT_AGAINST_NON_GOODS_VENDOR),于是这张单只能一直挂着。
            // 【所以这一处比收货那两处弱】它拦得住手滑,拦不住决心:
            // 直连仍然建得出来。真要禁,得在 purchase_orders 上加一道守卫,
            // 那是一支迁移,不在本刀(纯渲染)范围内 —— 记在 known-issues 里。
            .from('suppliers')
            .select('id, legal_name, default_payment_term_template_id')
            .is('deleted_at', null)
            .eq('supplies_goods', true)
            .order('legal_name'),
        supabase
            .from('materials')
            .select('id, code, name')
            .is('deleted_at', null)
            .order('code'),
        // 采购向或通用的启用公式(direction 'sale' 专用的不出现)
        supabase
            .from('pricing_formulas')
            .select('id, code, name, direction')
            .is('deleted_at', null)
            .eq('is_active', true)
            .neq('direction', 'sale')
            .order('code'),
        supabase
            .from('payment_term_templates')
            .select('id, name')
            .is('deleted_at', null)
            .eq('is_active', true)
            .order('name'),
        supabase
            .from('payment_term_template_lines_masked')
            .select('template_id, seq, label, percentage, fixed_amount_ccy, trigger_event, days_offset')
            .order('seq'),
    ])

    const error =
        suppliersRes.error ?? materialsRes.error ?? formulasRes.error ?? templatesRes.error ?? tplLinesRes.error
    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('purchasing.newOrder')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const suppliers: SupplierOption[] = (mustRows(suppliersRes)).map((s) => ({
        id: s.id,
        name: s.legal_name,
        default_template_id: s.default_payment_term_template_id,
    }))
    const materials: MaterialOption[] = (mustRows(materialsRes)).map((m) => ({
        id: m.id,
        label: `${m.code} — ${m.name}`,
    }))
    const formulas: FormulaOption[] = (mustRows(formulasRes)).map((f) => ({
        id: f.id,
        label: `${f.code} — ${f.name}`,
    }))
    const linesByTpl = new Map<string, TemplateOption['lines']>()
    for (const l of maskedRows<Tables<'payment_term_template_lines'>, 'fixed_amount_ccy'>(mustRows(tplLinesRes))) {
        const arr = linesByTpl.get(l.template_id) ?? []
        arr.push({
            label: l.label,
            percentage: l.percentage,
            fixed_amount_ccy: l.fixed_amount_ccy,
            trigger_event: l.trigger_event,
            days_offset: l.days_offset,
        })
        linesByTpl.set(l.template_id, arr)
    }
    const templates: TemplateOption[] = (mustRows(templatesRes)).map((tpl) => ({
        id: tpl.id,
        name: tpl.name,
        lines: linesByTpl.get(tpl.id) ?? [],
    }))

    return (
        <div className="p-8 max-w-6xl">
            <div className="mb-6">
                <Link href="/purchasing/orders" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="text-2xl font-bold mb-4">{t('purchasing.newOrder')}</h1>
            <Subnav />
            <NewOrderForm
                baseCurrency={baseCurrency}
                suppliers={suppliers}
                materials={materials}
                formulas={formulas}
                templates={templates}
            />
        </div>
    )
}
