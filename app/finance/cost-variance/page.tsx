// 估算 vs 实际(FIN-7 C5):按成本类型 × 月,多个月并排 —— 系统性偏差才看得见。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import { formatAmount } from '@/lib/format'
import { getBaseCurrency } from '@/lib/currency'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function CostVariancePage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()
    // 列头是月份,没有一处写着币种 —— 差异金额自己带(CCY-1)
    const baseCurrency = await getBaseCurrency()
    const res = await supabase.from('processing_cost_variance').select('*')
    type Row = { month: string; cost_type: string; estimated_total: number; actual_total: number; variance: number; direction: string }
    const rows = mustRows(res) as unknown as Row[]
    const months = [...new Set(rows.map((r) => r.month.slice(0, 7)))].sort().slice(-6)
    const types = [...new Set(rows.map((r) => r.cost_type))].sort()
    const by = new Map(rows.map((r) => [r.cost_type + '|' + r.month.slice(0, 7), r]))
    return (
        <div className="p-8 max-w-5xl">
            <h1 className="text-2xl font-bold mb-4">{t('finance.variance.title')}</h1>
            <p className="text-sm text-gray-600 mb-4">{t('finance.variance.intro')}</p>
            {rows.length === 0 ? <p className="text-sm text-gray-500">{t('finance.variance.empty')}</p> : (
                <table className="w-full border-collapse border border-gray-300 text-sm">
                    <thead className="bg-gray-100"><tr>
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('finance.variance.type')}</th>
                        {months.map((m) => <th key={m} className="border border-gray-300 px-3 py-2 text-right font-mono">{m}</th>)}
                    </tr></thead>
                    <tbody>
                        {types.map((ty) => (
                            <tr key={ty}>
                                <td className="border border-gray-300 px-3 py-2">{t('processing.costTypes.' + ty)}</td>
                                {months.map((m) => {
                                    const r = by.get(ty + '|' + m)
                                    return (
                                        <td key={m} className="border border-gray-300 px-3 py-2 text-right font-mono">
                                            {r ? (
                                                <span title={`est ${r.estimated_total} / act ${r.actual_total}`}
                                                      className={r.variance > 0 ? 'text-red-700' : r.variance < 0 ? 'text-green-700' : ''}>
                                                    {r.variance > 0 ? '+' : ''}{formatAmount(r.variance, baseCurrency)}
                                                </span>
                                            ) : '—'}
                                        </td>
                                    )
                                })}
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}
        </div>
    )
}
