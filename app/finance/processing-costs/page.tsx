// 加工成本结算(FIN-7 C3):实际额 → 汇付;估算 → 真实发票冲抵(提交前先看差异)。
//
// ★ CONV-3(Kind-C):套 ListPage 外壳,恒为 ok —— 两半各自的「没有待结的」
// 由 CostSettlePanel 自己说。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { ListPage } from '@/app/components/ui/list-page'
import CostSettlePanel from './CostSettlePanel'
import { getBaseCurrency } from '@/lib/currency'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { formatDate } from '@/lib/dates'
import { trailCount } from '@/app/components/trail/AuditTrail'
import ListTrail, { type ListTrailRecord } from '@/app/components/trail/ListTrail'

// AUDIT-TRAIL-1c-3(Tim 的 Q19):这一页的审计记录是【结算留下的单据】—— 汇缴的分录(remit_processing_costs 一次一张)与
//   冲抵的费用单(relieve_processing_accruals 一次一张)。条目自己的修改史留在加工单那一页上(processing_run)。
//   哪几张是结算留下的,只有成本条目知道(remitted_journal_entry_id / relief_expense_id),而成本条目的读规则是加工的码 ——
//   读不到它的人看到的是一句具名的拒绝,不是一块空白(今天每一个持 finance.view 的角色也持 processing.view,Step 0 §e)。
export default async function ProcessingCostsPage({ searchParams }: { searchParams: Promise<{ trail?: string }> }) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied
    const canEditGate = await can('module.finance.edit')

    const supabase = await createClient()
    const t = await getTranslations()
    const baseCurrency = await getBaseCurrency()
    // 【走遮蔽视图,不走基表】amount_base 的 SELECT 在基表上是收回的(perm2b),
    // 直接选它一律 42501;金额只能经 _masked 按 data.view_prices 取。
    // 结算三列曾经不在视图里,两条路都不通 —— 视图已于 fin7-fu 补齐。
    const [entriesRes, runsRes, supRes] = await Promise.all([
        supabase.from('processing_cost_entry_lookup')
            .select('id, run_id, cost_type, amount_base, is_estimate, created_at')
            .is('deleted_at', null).is('remitted_at', null).is('relieved_at', null)
            .order('created_at'),
        supabase.from('processing_run_lookup').select('id, code'),
        // LOG-1b:货代不进供应商名单
        supabase.from('supplier_lookup').select('id, legal_name').is('deleted_at', null).neq('counterparty_type', 'forwarder').order('legal_name'),
    ])
    // 读不出来就报错,不许渲染成「没有待结算」—— 见 lib/db-helpers 的政策注释
    const entries = mustRows(entriesRes, 'processing_cost_entries_masked')
    const runs = mustRows(runsRes, 'processing_runs')
    const suppliers = mustRows(supRes, 'suppliers')

    const canSeeEntries = await can('module.processing.view')
    let settled: ListTrailRecord[] = []
    if (canSeeEntries) {
        // 遮蔽伴生视图(与基表同一道行谓词:module.processing.view;这两列是单据 id,不是钱)
        const done = mustRows(await supabase.from('processing_cost_entries_masked')
            .select('remitted_journal_entry_id, relief_expense_id')
            .or('remitted_journal_entry_id.not.is.null,relief_expense_id.not.is.null'), 'processing_cost_entries settled') as
            { remitted_journal_entry_id: string | null; relief_expense_id: string | null }[]
        const jIds = [...new Set(done.map((x) => x.remitted_journal_entry_id).filter((x): x is string => !!x))]
        const eIds = [...new Set(done.map((x) => x.relief_expense_id).filter((x): x is string => !!x))]
        const js = jIds.length ? mustRows(await supabase.from('journal_entries').select('id, code, entry_date, status').in('id', jIds), 'journal_entries remittance') as
            { id: string; code: string; entry_date: string; status: string }[] : []
        const es = eIds.length ? mustRows(await supabase.from('expenses').select('id, code, expense_date, status').in('id', eIds), 'expenses relief') as
            { id: string; code: string; expense_date: string; status: string }[] : []
        settled = [
            ...js.map((j) => ({ subject: 'journal_entry' as const, id: j.id, href: `/finance/journal/${j.id}`,
                label: `${j.code} · remittance ${formatDate(j.entry_date, 'en')}${j.status === 'reversed' ? ' (reversed)' : ''}` })),
            ...es.map((e) => ({ subject: 'expense' as const, id: e.id, href: `/finance/expenses/${e.id}`,
                label: `${e.code} · relief ${formatDate(e.expense_date, 'en')}${e.status === 'reversed' ? ' (reversed)' : ''}` })),
        ]
    }
    return (
        <ListPage title={t('finance.costSettle.title')} maxWidth="max-w-5xl" state={{ kind: 'ok' }}>
            <CostSettlePanel canEdit={canEditGate} entries={entries as never} runs={runs as never}
                             suppliers={suppliers as never} baseCurrency={baseCurrency} />
            <ListTrail intro="listTrail.intro.costSettlement" show={trailCount((await searchParams).trail)} records={settled} refused={!canSeeEntries} />
        </ListPage>
    )
}
