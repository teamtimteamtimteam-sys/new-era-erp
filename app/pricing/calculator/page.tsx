// app/pricing/calculator/page.tsx
// 计价器(服务端壳):取启用中的公式;支持 ?formula=&quantity=&ni=&co=… 预填,
// 这样批次页可以带着已录的化验结果直接跳进来。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import CalculatorForm, { type FormulaOption } from './CalculatorForm'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { loadSubstances, toOptions } from '@/app/metal-prices/substanceQuery'

function todayIso(): string {
    return new Date().toISOString().slice(0, 10)
}

export default async function CalculatorPage({
    searchParams,
}: {
    searchParams: Promise<Record<string, string | undefined>>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.pricing)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    // PROC-4:物质清单从 substances 那张字典读(清单与顺序都由它定)。
    const substanceOptions = toOptions(await loadSubstances(supabase))
    const t = await getTranslations()

    const res = await supabase
        .from('pricing_formulas')
        .select('id, code, name, direction')
        .is('deleted_at', null)
        .eq('is_active', true)
        .order('code')

    if (res.error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('pricing.calcTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(res.error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const formulas = mustRows(res) as FormulaOption[]

    // 预填:?formula= 只在确实存在于清单里时才采纳;每个金属一个同名查询参数
    const wanted = (sp.formula ?? '').trim()
    const assay: Record<string, string> = {}
    for (const opt of substanceOptions) {
        const v = (sp[opt.value] ?? '').trim()
        if (v) assay[opt.value] = v
    }
    const rawDate = (sp.date ?? '').trim()

    const prefill = {
        formulaId: formulas.some((f) => f.id === wanted) ? wanted : '',
        quantity: (sp.quantity ?? '').trim(),
        date: rawDate && !Number.isNaN(Date.parse(rawDate)) ? rawDate : todayIso(),
        assay,
    }

    return (
        <div className="p-8 max-w-5xl">
            <h1 className="text-2xl font-bold mb-4">{t('pricing.calcTitle')}</h1>
            <CalculatorForm
                substanceOptions={substanceOptions} formulas={formulas} prefill={prefill} />
        </div>
    )
}
