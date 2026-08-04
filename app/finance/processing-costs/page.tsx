// 加工成本结算(FIN-7 C3):实际额 → 汇付;估算 → 真实发票冲抵(提交前先看差异)。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../Subnav'
import CostSettlePanel from './CostSettlePanel'

export default async function ProcessingCostsPage() {
    const supabase = await createClient()
    const t = await getTranslations()
    const [entriesRes, runsRes, supRes] = await Promise.all([
        supabase.from('processing_cost_entries')
            .select('id, run_id, cost_type, amount_base, is_estimate, created_at')
            .is('deleted_at', null).is('remitted_at', null).is('relieved_at', null)
            .order('created_at'),
        supabase.from('processing_runs').select('id, code'),
        supabase.from('suppliers').select('id, legal_name').is('deleted_at', null).order('legal_name'),
    ])
    return (
        <div className="p-8 max-w-5xl">
            <h1 className="text-2xl font-bold mb-4">{t('finance.costSettle.title')}</h1>
            <Subnav />
            <CostSettlePanel entries={(entriesRes.data ?? []) as never} runs={(runsRes.data ?? []) as never}
                             suppliers={(supRes.data ?? []) as never} />
        </div>
    )
}
