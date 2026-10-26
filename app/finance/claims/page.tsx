// app/finance/claims/page.tsx
// CLAIM-1:审批那一半 —— 决定的人站的地方。
//
// 【两个听众,两张屏】提报的人在 /me(那里本来就有自助面板),
// 审批的人在这里。把提报人赶进财务模块去要回自己垫的钱,不合适;
// 而一个决定队列埋在别人的页面上,是一个没人会去看的队列。
//
// ★★ CONV-3(Kind D,转换【它自己】,不为它另设模板)★★
// 上半是决定队列(卡片,不是表格),下半是已决登记簿(CONV-1 已经换成
// DataTable)。这一页只做一件事:套上 ListPage 外壳,让拒绝态与三张
// 邻居页面(claims 自己下半、payroll-payments、processing-costs)共用同一个
// 组件。**不为决定队列造一个新的可复用形状** —— 它是这个仓库里唯一一张
// 决定队列,CONV-2 §① 已经拒绝过"一个例子就设计模板"。
//
// 【为什么恒为 ok,不是 empty/too-few】这一页有【两个独立的列表】,各自的
// 空态各说各的话(expenseClaims.noPending / .noneForEmployee),都住在
// ClaimDecisionPanel 内部、不受任何行数门槛管 —— 与 CONV-2 §⑧ 第 3 条
// 撞见的缺陷同形:让 ListPage 的 empty 分支替其中一半说话,会把另一半
// 一起藏起来。两个独立空态只能由各自的容器自己说。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { getBaseCurrency } from '@/lib/currency'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { canViewPrices } from '@/lib/permissions'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import ClaimDecisionPanel, { type ClaimItem, type ClaimRow } from './ClaimDecisionPanel'
import type { ReceiptRow } from '@/app/me/ClaimReceipts'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import { shapeListTotals } from '@/lib/listTotals'

// AUDIT-TRAIL-1c-3(Tim 的 Q20):每一张报销单一段审计记录(提交 · 决定 · 撤回 · 收据 · 批准时记下的费用单);
//   报销人自己那一半在 /me(my_expense_claim,M8)。
export default async function ClaimsPage({ searchParams }: { searchParams: Promise<{ trail?: string }> }) {
    const show = trailCount((await searchParams).trail)
    const denied = await requireModule(MOD.finance)
    if (denied) return denied
    const t = await getTranslations()
    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    // ★ FIN-CHAIN-1(Tim 2026-10-20,ROLE1-EXPENSE-CLAIM-DECIDE-BUTTON-WRONG-CODE):决定钮问的是【库的那一道门】——
    //   decide_expense_claim 要 module.finance.view + data.view_prices(再加审批级别,那一层按名拒),从来不要 .edit
    //   (Tim APR-3 Q1)。本页已经过了 requireModule(MOD.finance),所以 finance.view 必在;剩下的就是价格码 ——
    //   与日记账 / 发票 / GST 三张页面的决定钮同一个判据。此前它问 module.finance.edit,于是对 CFO 说"缺 .edit",而库会放行。
    const canDecide = await canViewPrices()

    const headers = mustRows(
        await supabase
            .from('expense_claim_status')
            .select('*')
            .order('spend_date', { ascending: false })
    ) as unknown as Omit<ClaimRow, 'items'>[]
    // EXPENSE-MULTILINE-1:每张单的明细(同一条读规则:持 finance.view,或者那张单说的就是你)
    const items = headers.length
        ? mustRows(
            await supabase.from('expense_claim_items')
                .select('id, claim_id, line_no, spend_date, amount_ccy, description, no_receipt_reason, account_code, tax_code')
                .in('claim_id', headers.map((h) => h.claim_id))
                .order('line_no'),
            'expense_claim_items',
        ) as unknown as (ClaimItem & { claim_id: string })[]
        : []
    const rows: ClaimRow[] = headers.map((h) => ({ ...h, items: items.filter((i) => i.claim_id === h.claim_id) }))
    // ★ CLAIM-RECEIPTS-1(Tim 2026-10-21,Q6 · Q7):每一笔的收据 —— 持 finance.view 读全部(本页的门就是它);只列 attached 的
    //   (拿掉的从单上隐去,Q5)。替人提单的人(expense_claims.created_by = 我)在这里也传得了(Q4),所以读一下每张单是谁提的。
    const receipts = headers.length
        ? mustRows(
            await supabase.from('expense_claim_receipts')
                .select('id, item_id, file_name')
                .in('claim_id', headers.map((h) => h.claim_id))
                .eq('status', 'attached')
                .order('created_at'),
            'expense_claim_receipts',
        ) as ReceiptRow[]
        : []
    const raisers = headers.length
        ? mustRows(
            await supabase.from('expense_claims').select('id, created_by').in('id', headers.map((h) => h.claim_id)),
            'expense_claims (raisers)',
        ) as { id: string; created_by: string | null }[]
        : []
    // 认证读不出来(error)时不猜"是不是提单人" —— 那就不画替人提单的那个上传框;库照样判(claim_receipt_begin)
    const { data: meData, error: meErr } = await supabase.auth.getUser()
    const me = meErr ? null : (meData.user?.id ?? null)
    const raisedByMe = raisers.filter((r) => me && r.created_by === me).map((r) => r.id)
    const receiptLimits = mustOne(await supabase.rpc('claim_receipt_limits'), 'claim_receipt_limits') as
        { set: boolean; max_bytes: number | null; types: string[] | null } | null

    const accounts = mustRows(
        await supabase.from('accounts')
            .select('code, name_en, account_type')
            .eq('account_type', 'expense')
            .order('code')
    ) as unknown as { code: string; name_en: string }[]

    const taxCodes = mustRows(
        await supabase.from('tax_codes').select('code, name_en, side, is_active')
    ) as unknown as { code: string; name_en: string; side: string; is_active: boolean }[]

    const pending = rows.filter((r) => r.status === 'submitted')
    const decided = rows.filter((r) => r.status !== 'submitted')
    // TABLE-FEATURES-2(Tim Q1):已决登记簿的表尾合计 —— 库算(db/functions/list_totals_expense_claims.sql),
    //   在 SQL 里用与上一行同一条 status <> 'submitted'。
    const decidedTotals = shapeListTotals(mustRows(await supabase.rpc('list_totals_expense_claims'), 'expense claims totals'))

    return (
        <ListPage
            title={t('expenseClaims.title')}
            intro={t('expenseClaims.subtitle')}
            // 备用金是【被否决的】,不是还没做 —— 无条件渲染,与有没有数据无关
            // (与 CONV-1 §③ 的 notices 槽同一条理由)。
            notices={
                <p className="mb-6 text-xs text-[color:var(--brand-muted-text)]">{t('expenseClaims.pettyCashRuledOut')}</p>
            }
            state={{ kind: 'ok' }}
        >
            <ClaimDecisionPanel
                trails={Object.fromEntries(rows.map((r) => [r.claim_id,
                    <AuditTrail key={r.claim_id} subject="expense_claim" id={r.claim_id} show={show} anchor={`claim-trail-${r.claim_id}`} compact />]))}
                pending={pending}
                decided={decided}
                decidedTotals={decidedTotals}
                accounts={accounts}
                taxCodes={taxCodes.filter((x) => x.is_active && x.side === 'input')}
                canDecide={canDecide}
                baseCurrency={baseCurrency}
                receipts={receipts}
                raisedByMe={raisedByMe}
                receiptLimits={receiptLimits}
            />
        </ListPage>
    )
}
