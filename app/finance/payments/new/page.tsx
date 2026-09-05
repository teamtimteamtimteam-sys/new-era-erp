// app/finance/payments/new/page.tsx
// 收付款登记页(服务端壳):取客户/供应商(在册)+ 两侧全部未结单据 + 可预付的
// 采购单(cut 4b:定金在货物存在之前就要付,那一刻没有任何 AP 单据可核销 ——
// 指向采购单的核销行就是预付款,分录走 1300 而不是 2000,拆账在 record_payment 内)。
// ?direction= 定初始方向,?supplier= 预选供应商(采购单详情"登记付款"入口带过来),
// 表单交给客户端组件。
// NOTE: 未结单据两侧全量下发、客户端按往来单位过滤 —— 免选择后的往返;
// 数据量小(未结清才进视图),体量上来再改按需加载。
import { getBaseCurrency } from '@/lib/currency'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import NewPaymentForm, { type PartyOption, type OpenItem, type PoItem } from './NewPaymentForm'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { can } from '@/lib/permissions'
import { MOD } from '@/lib/modules'

// 视图列生成类型全可空;行进视图即非空,取用列本地锁死
type ArItem = {
    sales_record_id: string
    invoice_id: string | null
    doc_kind: string
    customer_id: string | null
    doc_code: string
    sale_date: string
    open_ccy: number
    currency: string
}
type ApItem = {
    // PAY-FRT:视图的第三支('freight')此前没有出现在这个类型里 —— 它照样被
    // 原样传下去,只是 TypeScript 不知道有这一种,于是 action 的分支漏掉它
    // 也没有任何东西会红。把它写出来,是让编译器参与这件事。
    doc_kind: 'inbound' | 'expense' | 'freight'
    doc_id: string
    // PAYEE-1b:往来对象可以是供应商或员工;这一列永远非空。
    counterparty_id: string
    doc_code: string
    doc_date: string
    open_ccy: number
    currency: string
}

export default async function NewPaymentPage({
    searchParams,
}: {
    searchParams: Promise<{ direction?: string; supplier?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    // SOD-1:事前告知要知道"我是谁"。
    // 【error 必须接住】丢掉它,「认证够不着」与「这个人没登录」就走同一条分支 ——
    // 而这里那条分支的后果是【告知悄悄消失】,读起来正好是"没有冲突",
    // 也就是把"我不知道"显示成了一个具体的答案。所以分三类:
    // 够不着 → 说"查不了";没登录 → 本来就到不了这一页;正常 → 比对。
    const { data: { user: sodUser }, error: sodUserErr } = await supabase.auth.getUser()
    const sodUnknown = !!sodUserErr
    const me = sodUnknown ? null : (sodUser?.id ?? null)
    const t = await getTranslations()
    const baseCurrency = await getBaseCurrency()

    const initialDirection = sp.direction === 'out' ? 'out' : 'in'
    // 预选供应商只对付款方向有意义
    const initialPartyId = initialDirection === 'out' ? (sp.supplier ?? '') : ''

    const [customersRes, suppliersRes, employeesRes, arRes, apRes, poRes] = await Promise.all([
        supabase
            .from('customer_lookup')
            .select('id, legal_name')
            .is('deleted_at', null)
            .order('legal_name'),
        supabase
            // ★★【FIX-2a:收款人名单走查名视图 —— 此前对 cfo 整张是空的】★★
            // 这一页的守卫是 module.finance.view,而 suppliers 基表挂
            // module.suppliers.view。cfo 只持 finance / logistics / purchasing 三个
            // 模块,于是「付给谁」那个下拉一个人都没有 —— 屏幕说的是"没有往来对象"。
            //
            // 【SOD-1 的 created_by 【不】跟着搬进查名视图】,而这不是一次将就:
            // 那一列是审计列,而 supplier_lookup 的受众现在有五个模块码。
            // 下面单独取,取不到时 createdByMe 为 false ——
            // 而 NewPaymentForm 抬头【已经写明】那是一个合法状态
            // (「规矩不适用时(created_by 没有记下来)它完全合法」):
            // 不出现那句提醒【不是】一句"没有冲突"的断言,真正的判定在服务端那道闸上。
            .from('supplier_lookup')
            .select('id, legal_name')
            .is('deleted_at', null)
            // ════════════════════════════════════════════════════════════════
            // PAY-FRT:这里【不】排除货代 —— LOG-1b 在 11 个点位加了
            // `.neq('counterparty_type','forwarder')`,十个是对的(供应商名单、
            // 采购、收货、计价公式:货代不供货,不该出现在那些地方)。
            // 【这一个不是】:这是【付款对象】的下拉,而货代恰恰是一个你欠钱的
            // 往来对象 —— 未付运费的贷方就记在它名下。把它排除掉,等于
            // record_payment 认识运费单了、账龄里也看得见,而屏幕上【选不到那个人】,
            // 于是那扇门仍旧是关的,只是关在了上一层。
            // 【这与 SUP-TYPE-1b 立的规矩是同一条】:非供货往来户必须留在
            // 开支/付款/运费/加工成本这几个下拉里 —— "后者正是非供货往来户存在的
            // 理由,收窄它们会是一次真正的功能损失"(docs/known-issues.md)。
            // 货代是那句话最纯粹的例子。
            // ════════════════════════════════════════════════════════════════
            .order('legal_name'),
        // PAYEE-1b:出款也可以付给员工(报销)。读遮蔽视图,门是 module.hr.view。
        supabase
            // FIX-2a:员工走【查名】视图 —— employees_masked 整张挂 module.hr.view,
            // 于是 cfo 与 finance 读回零行,「付给员工(报销)」那一组下拉是空的。
            // employee_lookup 只出 id / 工号 / 称呼名 / 法定名(Tim 的 Q2 裁定),
            // 薪酬与证件一列都不带。
            .from('employee_lookup')
            .select('id, legal_name')
            .is('deleted_at', null)
            .order('legal_name'),
        supabase
            .from('ar_open_items')
            .select('sales_record_id, invoice_id, doc_kind, customer_id, doc_code, sale_date, open_ccy, currency')
            .order('sale_date', { ascending: true }),
        // PAYEE-1b:核销候选按【往来对象】取 —— 员工行的 supplier_id 是 NULL,
        // 照旧读它,员工的应付永远匹配不上任何一个选中的往来对象(等于看不见)。
        supabase
            .from('ap_open_items')
            .select('doc_kind, doc_id, counterparty_id, doc_code, doc_date, open_ccy, currency')
            .order('doc_date', { ascending: true }),
        // 可预付的采购单:视图本身排除已取消,这里再排除已结束的
        supabase
            .from('purchase_order_status')
            .select('po_id, supplier_id, code, order_date, estimated_total_ccy, prepaid_base, currency')
            .neq('status', 'closed')
            .order('order_date', { ascending: true }),
    ])

    const error = customersRes.error ?? suppliersRes.error ?? employeesRes.error ?? arRes.error ?? apRes.error ?? poRes.error
    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('finance.newPaymentTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    // 视图列在生成类型里一律可空;行进了视图即非空 —— 取用处本地锁死(FIX-1 同一写法)。
    const customers: PartyOption[] = (mustRows(customersRes) as unknown as
        { id: string; legal_name: string }[]).map((c) => ({
        id: c.id,
        name: c.legal_name,
    }))
    // FIX-2a:建户人单独取 —— 只有读得到 suppliers 基表的人才有这一列。
    // 【谁真的需要它】能【提交】付款的是 module.finance.edit(实测 admin / finance /
    // gm),而这三个角色都持 suppliers.view —— 也就是说 SOD-1 那句事前提醒
    // 在它真正起作用的每一个人那里【一字未变】。读不到的人(cfo)本来就提交不了。
    const supplierRows = mustRows(suppliersRes) as unknown as { id: string; legal_name: string }[]
    const createdByOf = new Map<string, string | null>()
    if (await can('module.suppliers.view')) {
        for (const s of mustRows(
            await supabase.from('suppliers').select('id, created_by').is('deleted_at', null),
            'supplier created_by (SOD-1)'
        )) {
            createdByOf.set(s.id as string, s.created_by as string | null)
        }
    }
    // 查不了的时候【说出来】,不要让告知无声消失。
    const suppliers: PartyOption[] = supplierRows.map((s) => ({
        id: s.id,
        name: s.legal_name,
        // SOD-1:这一家是不是【我】建的。null = 没有记下建户人(线上 8 家既有
        // 供应商就是这样),那时规矩【不适用】—— 不是"查过了没问题"。
        createdByMe: createdByOf.get(s.id) != null && createdByOf.get(s.id) === me,
    }))
    const employees: PartyOption[] = (mustRows(employeesRes) as { id: string; legal_name: string }[])
        .map((e) => ({ id: e.id, name: e.legal_name }))
    // SO-3a:应收有两种单据('sale' 销售记录 / 'invoice' 订单流发票),
    // doc_kind 由视图自己给(ap 的先例),doc_id 相应二选一。
    const arItems: OpenItem[] = ((arRes.data as unknown as ArItem[] | null) ?? []).map((r) => ({
        doc_id: r.doc_kind === 'invoice' ? (r.invoice_id as string) : r.sales_record_id,
        doc_kind: (r.doc_kind === 'invoice' ? 'invoice' : 'sale') as OpenItem['doc_kind'],
        party_id: r.customer_id ?? '',
        doc_code: r.doc_code,
        doc_date: r.sale_date,
        open_ccy: r.open_ccy,
        currency: r.currency,
    }))
    const apItems: OpenItem[] = ((apRes.data as unknown as ApItem[] | null) ?? []).map((r) => ({
        doc_id: r.doc_id,
        doc_kind: r.doc_kind,
        party_id: r.counterparty_id,
        doc_code: r.doc_code,
        doc_date: r.doc_date,
        open_ccy: r.open_ccy,
        currency: r.currency,
    }))
    const poItems: PoItem[] = ((poRes.data as unknown as {
        po_id: string
        supplier_id: string | null
        code: string
        order_date: string
        estimated_total_ccy: number
        prepaid_base: number
        currency: string
    }[] | null) ?? []).map((r) => ({
        po_id: r.po_id,
        party_id: r.supplier_id ?? '',
        code: r.code,
        order_date: r.order_date,
        estimated_total_ccy: r.estimated_total_ccy,
        prepaid_base: r.prepaid_base,
        currency: r.currency,
    }))

    return (
        <div className="p-8 max-w-5xl">
            <h1 className="text-2xl font-bold mb-4">{t('finance.newPaymentTitle')}</h1>
            <NewPaymentForm
                customers={customers}
                suppliers={suppliers}
                sodUnknown={sodUnknown}
                employees={employees}
                arItems={arItems}
                apItems={apItems}
                poItems={poItems}
                initialDirection={initialDirection}
                initialPartyId={initialPartyId}
                baseCurrency={baseCurrency}
            />
        </div>
    )
}
