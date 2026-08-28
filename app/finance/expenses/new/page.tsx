// app/finance/expenses/new/page.tsx
// 开支登记页(服务端壳):取 active 的 expense 科目(按编码排序,名称按语言)
// + 在册供应商(挂账开支要选),表单交给客户端组件。
import { can } from '@/lib/permissions'
import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency } from '@/lib/currency'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import NewExpenseForm, {
    type AccountOption, type SupplierOption, type AssetOption, type PoLineOption,
} from './NewExpenseForm'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function NewExpensePage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    const t = await getTranslations()
    const locale = await getLocale()

    const [accountsRes, suppliersRes, employeesRes, assetsRes, poLinesRes, poHeadsRes, lineExpensesRes, capAccountRes, settingsRes, whtNaturesRes, taxCodesRes] = await Promise.all([
        supabase
            .from('accounts')
            .select('code, name_en, name_zh')
            .eq('account_type', 'expense')
            .eq('is_active', true)
            .order('code'),
        supabase
            .from('suppliers')
            .select('id, legal_name, default_tax_code, tax_residence')
            .is('deleted_at', null)
            // LOG-1b:货代不进供应商名单(他们保留 supplier id 只为账上那条链)
            // 【服务商(房东/水电)要留下】—— 只排货代,不是只留供货商
            .neq('counterparty_type', 'forwarder')
            .order('legal_name'),
        // PAYEE-1b:未付费用的往来对象可以是员工(报销)。
        // 【读 employees_masked】它是遮蔽视图,门是 module.hr.view —— 没有 HR
        // 权限的财务读者会读到 0 行,而那时下拉里会显示"名单为空"那句话。
        // 那句话在这里【略微不准】(真相是"你看不到"而不是"没有人"),
        // 但两者的下一步是同一句:去人事模块。留一条已知项,不假装它准。
        supabase
            .from('employees_masked')
            .select('id, legal_name')
            .is('deleted_at', null)
            .order('legal_name'),
        // ── EQP-1c-c:【已登记、还能加成本】的机器 ────────────────────────────
        // 判据照抄 record_expense 追加支自己那两条拒绝(见它的函数体):
        //   ASSET_ALREADY_IN_SERVICE → in_service_date 必须为空
        //   ASSET_DISPOSED           → status 必须是 active
        // 【为什么照抄而不是自己想一套】列表若比函数宽,人会挑到一台注定被拒的机器;
        // 若比函数窄,人会以为某台机器加不了成本 —— 而两种都不是这张表单该做的判断。
        supabase.from('fixed_assets')
            .select('id, code, description, cost_base')
            .eq('status', 'active').is('in_service_date', null).order('code'),
        // ── EQP-1c-c:设备采购行 + 它挂的机器 + 它属于谁 + 它有没有被报销过 ──
        // 【"已报销"的判据【就是】EQP-1b-ii 那一条,不是另想的一条】:
        // 那条行上存在一笔 status = 'posted' 的支出。同一句话有三个地方在说 ——
        // uq_expenses_live_po_line(索引,负责正确)、record_expense 的
        // PO_LINE_ALREADY_EXPENSED(函数,负责可读)、以及这里(列表,只负责
        // 【不引导人去踩】)。前两者是保证,这一处不是:即便挑错了,服务端照样按名拒。
        // 【读遮蔽视图,不读表】—— purchase_order_lines 是遮蔽表(REVOKE SELECT +
        // 列清单授权),而本查询要的 estimated_amount_ccy 【正是被扣住的三列之一】
        // (另两列是 estimated_unit_price / price_provenance)。直接查表 → 42501。
        // 【PostgreSQL 给的提示是"把表的 SELECT 授给 authenticated" —— 不能照做】
        // 那会把遮蔽整个撤掉,把金额列敞给每一个登录用户。提示是机械的:
        // 它不知道那几列是【故意】扣住的。
        // 【视图上不做 embed】本仓库每一处读遮蔽视图的地方都是分开查、在 TS 里拼
        // (invoices_masked / invoice_lines_masked 那几处就是),这里照办。
        supabase.from('purchase_order_lines_masked')
            .select('id, line_no, asset_id, purchase_order_id, estimated_amount_ccy')
            .not('asset_id', 'is', null),
        supabase.from('purchase_orders_masked')
            .select('id, code, supplier_id, status, approval_status, currency, deleted_at'),
        supabase.from('expenses')
            .select('id, code, status, purchase_order_line_id')
            .not('purchase_order_line_id', 'is', null),
        // 1500 的名字【从库里取】,不写死 —— 资本支出的借方就是它(record_expense 定死)。
        supabase.from('accounts').select('code, name_en, name_zh').eq('code', '1500').maybeSingle(),
        supabase.from('finance_settings').select('gst_registered').limit(1).single(),
        // GST-2:进项税码字典。【只取进项侧】—— 销项码挂到费用单上会被
        // resolve_tax_code 按名拒(TAX_CODE_WRONG_SIDE),而一个能选到拒绝的
        // 下拉是在把人骗去撞墙。
        supabase.from('wht_natures').select('code, name_en, name_zh, sort_order')
            .eq('is_active', true).order('sort_order'),
        supabase.from('tax_codes').select('code, name_en, name_zh, is_claimable')
            .eq('side', 'input').eq('is_active', true).order('sort_order'),
    ])

    const error = accountsRes.error ?? suppliersRes.error ?? employeesRes.error ?? assetsRes.error ?? poLinesRes.error ?? poHeadsRes.error ?? lineExpensesRes.error ?? whtNaturesRes.error ?? taxCodesRes.error
    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('expense.new')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    // ── EQP-1c-c:可挑的机器,以及可挑的设备采购行 ────────────────────────
    const assets: AssetOption[] = (mustRows(assetsRes)).map((a) => ({
        id: a.id, label: `${a.code} — ${a.description}`,
    }))
    type RawLine = {
        id: string; line_no: number; asset_id: string | null; purchase_order_id: string
        estimated_amount_ccy: number | null
    }
    type RawHead = { id: string; code: string; supplier_id: string; status: string
                     approval_status: string; currency: string; deleted_at: string | null }
    // 【在 TS 里拼,而不是在视图上 embed】—— 见上面那段注释。
    const headById = new Map((mustRows(poHeadsRes) as unknown as RawHead[]).map((h) => [h.id, h]))
    const billedByLine = new Map<string, string>()
    for (const e of mustRows(lineExpensesRes) as unknown as
            { id: string; code: string; status: string; purchase_order_line_id: string }[]) {
        // 【已报销 = status='posted'】—— EQP-1b-ii 的原话,判据一字未改。
        if (e.status === 'posted') billedByLine.set(e.purchase_order_line_id, e.code)
    }
    const poLines: PoLineOption[] = (mustRows(poLinesRes) as unknown as RawLine[])
        .map((l) => ({ ...l, purchase_orders: headById.get(l.purchase_order_id) ?? null }))
        // 【与 record_expense 的 D2 三条守卫同口径】单据要存在(未软删)、未作废、已获批。
        // 挑到一条不满足的,服务端会按名拒(PO_NOT_FOUND / PO_CANCELLED / PO_NOT_APPROVED)——
        // 这里只是不把它摆出来。
        .filter((l) => l.purchase_orders
            && l.purchase_orders.deleted_at === null
            && l.purchase_orders.status !== 'cancelled'
            && l.purchase_orders.approval_status === 'approved')
        .map((l) => ({
            id: l.id,
            lineNo: l.line_no,
            assetId: l.asset_id as string,
            supplierId: l.purchase_orders!.supplier_id,
            poCode: l.purchase_orders!.code,
            currency: l.purchase_orders!.currency,
            estimate: l.estimated_amount_ccy,
            // 【已报销 = 那条行上有一笔 status='posted' 的支出】—— EQP-1b-ii 的原话。
            // 带上编号,好让那个【禁用的】选项说得出是被哪一张单占着的。
            billedBy: billedByLine.get(l.id) ?? null,
        }))
    // 【读不到采购单与"没有采购单"是两件事】空列表要说得出是哪一种(见表单)。
    const canSeePurchasing = await can('module.purchasing.view')
    const capRow = capAccountRes.data as { code: string; name_en: string; name_zh: string } | null
    // D5:资本支出的借方【就是 1500】(record_expense 定死),名字从库里取,不写死。
    const capitalAccountLabel = capRow
        ? `${capRow.code} ${locale === 'zh' ? capRow.name_zh : capRow.name_en}`
        : '1500'

    const accounts: AccountOption[] = (mustRows(accountsRes)).map((a) => ({
        code: a.code,
        name: locale === 'zh' ? a.name_zh : a.name_en,
    }))
    const suppliers: SupplierOption[] = (mustRows(suppliersRes)).map((s) => ({
        id: s.id,
        name: s.legal_name,
        default_tax_code: s.default_tax_code,
        // WHT-1:居民身份跟着供应商一起过来 —— 表单据此决定要不要【追问】代扣。
        // 【它只驱动追问,不驱动金额】扣多少一律由 record_expense 解析并冻在单上。
        tax_residence: s.tax_residence,
    }))
    const employees: SupplierOption[] = (mustRows(employeesRes) as { id: string; legal_name: string }[])
        .map((e) => ({ id: e.id, name: e.legal_name }))

    return (
        <div className="p-8 max-w-4xl">
            <h1 className="text-2xl font-bold mb-4">{t('expense.new')}</h1>
            <Subnav />
            <NewExpenseForm
                baseCurrency={baseCurrency} accounts={accounts} suppliers={suppliers}
                employees={employees} assets={assets} poLines={poLines}
                canSeePurchasing={canSeePurchasing} capitalAccountLabel={capitalAccountLabel}
                gstRegistered={settingsRes.data?.gst_registered ?? false}
                whtNatures={mustRows(whtNaturesRes).map((n) => ({
                    code: n.code as string,
                    name: locale === 'zh' ? (n.name_zh as string) : (n.name_en as string),
                }))}
                taxCodes={mustRows(taxCodesRes).map((c) => ({
                    code: c.code, name_en: c.name_en, name_zh: c.name_zh,
                    is_claimable: c.is_claimable,
                }))} />
        </div>
    )
}
