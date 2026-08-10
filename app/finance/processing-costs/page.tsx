// 加工成本结算(FIN-7 C3):实际额 → 汇付;估算 → 真实发票冲抵(提交前先看差异)。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import Subnav from '../Subnav'
import CostSettlePanel from './CostSettlePanel'
import { getBaseCurrency } from '@/lib/currency'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function ProcessingCostsPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()
    const baseCurrency = await getBaseCurrency()
    // 【走遮蔽视图,不走基表】amount_base 的 SELECT 在基表上是收回的(perm2b),
    // 直接选它一律 42501;金额只能经 _masked 按 data.view_prices 取。
    // 结算三列曾经不在视图里,两条路都不通 —— 视图已于 fin7-fu 补齐。
    const [entriesRes, runsRes, supRes] = await Promise.all([
        supabase.from('processing_cost_entries_masked')
            .select('id, run_id, cost_type, amount_base, is_estimate, created_at')
            .is('deleted_at', null).is('remitted_at', null).is('relieved_at', null)
            .order('created_at'),
        supabase.from('processing_runs').select('id, code'),
        supabase.from('suppliers').select('id, legal_name').is('deleted_at', null).order('legal_name'),
    ])
    // 读不出来就报错,不许渲染成「没有待结算」—— 见 lib/db-helpers 的政策注释
    const entries = mustRows(entriesRes, 'processing_cost_entries_masked')
    const runs = mustRows(runsRes, 'processing_runs')
    const suppliers = mustRows(supRes, 'suppliers')
    return (
        <div className="p-8 max-w-5xl">
            <h1 className="text-2xl font-bold mb-4">{t('finance.costSettle.title')}</h1>
            <Subnav />
            <CostSettlePanel entries={entries as never} runs={runs as never}
                             suppliers={suppliers as never} baseCurrency={baseCurrency} />
        </div>
    )
}
