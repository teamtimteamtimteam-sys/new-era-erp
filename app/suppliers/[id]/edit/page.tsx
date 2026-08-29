import Link from 'next/link'
import { formatTimestamp } from '@/lib/format'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import EditSupplierForm from './EditSupplierForm'
import StatusPanel from './StatusPanel'
import CompliancePanel from './CompliancePanel'
import AttachmentsPanel from './AttachmentsPanel'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { can } from '@/lib/permissions'
import ContactsPanel, { type ContactRow } from '@/app/customers/ContactsPanel'
import ReceiptPatternPanel, {
    type PatternRow, type ContributingReceipt,
} from './ReceiptPatternPanel'

export default async function EditSupplierPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.suppliers)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    // PARTY-1:这家供应商的联系人们(软删的不列)
    const canEditSupplier = await can('module.suppliers.edit')
    const supplierContacts = mustRows(
        await supabase.from('counterparty_contacts')
            .select('id, name, name_inferred, role, email, phone, is_primary, notes')
            .eq('supplier_id', id).is('deleted_at', null)
            .order('is_primary', { ascending: false }).order('name'),
        'counterparty_contacts') as ContactRow[]

    const { data: supplier, error } = await supabase
        .from('suppliers')
        .select('*')
        .eq('id', id)
        .is('deleted_at', null)
        .single()

    // GST-2:进项税码字典 + 开关(只在已注册时渲染那一格)。
    const [gstSettingsRes, gstCodesRes] = await Promise.all([
        supabase.from('finance_settings').select('gst_registered').limit(1).single(),
        supabase.from('tax_codes').select('code, name_en, name_zh')
            .eq('side', 'input').eq('is_active', true).order('sort_order'),
    ])

    if (error || !supplier) {
        notFound()
    }

    const { data: complianceRows } = await supabase
        .from('supplier_compliance')
        .select('id, cert_type_code, cert_no, issuing_body, valid_from, valid_until, notes, document_id')
        .eq('supplier_id', id)
        .is('deleted_at', null)
        .order('created_at', { ascending: false })

    // CMP-1:类型来自 certificate_types 表 —— 加一种证书是编辑一行数据,不是改代码
    const { data: certTypeRows } = await supabase
        .from('certificate_types')
        .select('code, name_en, name_zh, disposition')
        .eq('is_active', true)
        .order('sort_order')

    const { data: attachmentRows } = await supabase
        .from('supplier_attachments')
        .select('id, file_name, file_type, file_size, doc_category, storage_path, created_at')
        .eq('supplier_id', id)
        .is('deleted_at', null)
        .order('created_at', { ascending: false })

    // ── GRN-2:这家供应商的收货模式 ──────────────────────────────────────────
    // 【这一页的门与这份数据的门不是同一道】页面是 module.suppliers.view,
    // supplier_receipt_pattern 是 module.purchasing.view。少了这个判据,
    // 一个没有采购权限的读者会看到一块空面板 —— 而空面板读起来是"记录干净"。
    // 【先问权限,再决定查不查】不查询就没有"0 行"可以被误读成"没有差异",
    // 这比查完再解释 null 更不容易出错(GRN-1b 在批次详情上栽的正是那一处)。
    const canSeePattern = await can(MOD.purchasing.permission)
    let patternRow: PatternRow | null = null
    let contributing: ContributingReceipt[] = []
    if (canSeePattern) {
        const [patRes, conRes] = await Promise.all([
            supabase
                .from('supplier_receipt_pattern')
                .select('window_days, window_from, comparable_receipts, short_receipts, over_receipts, ' +
                        'declared_vs_actual_receipts, material_mismatch_receipts, assay_beyond_receipts, ' +
                        'receipts_with_any_discrepancy, short_lines, over_lines, short_qty, over_qty, ' +
                        'excluded_receipts, undated_receipts, undated_with_discrepancy, ' +
                        'earliest_receipt, latest_receipt, grn_short_pct, grn_over_pct, grn_assay_tolerance_pct')
                .eq('supplier_id', id)
                .maybeSingle(),
            // 逐条点名的那一份 —— 【窗口由视图那一行说了算,不在这里再写一个 180】
            supabase
                .from('grn_discrepancies')
                .select('batch_id, batch_code, arrival_date, kinds')
                .eq('supplier_id', id)
                .order('arrival_date', { ascending: false }),
        ])
        // 【失败必须失败】读不出来的模式面板必须报错,不许渲染成一块干净的记录
        patternRow = mustOne(patRes, 'supplier_receipt_pattern') as unknown as PatternRow | null
        const all = mustRows(conRes, 'grn_discrepancies') as unknown as ContributingReceipt[]
        // 只列【真的有差异】的那些,并且只列窗口内的 —— 判断是视图下的,
        // 这里只按视图给的 window_from 做展示筛选,不重新判定什么算差异。
        const from = patternRow?.window_from ?? null
        contributing = all.filter(
            (r) => r.kinds?.length > 0 && r.arrival_date !== null && (!from || r.arrival_date >= from)
        )
    }

    // 默认付款条款模板下拉:启用的 + 该供应商当前指着的那个(即便已停用/已删,
    // 也得让它出现在选项里 —— 否则一打开编辑页就"看起来像无",一保存就静默清掉)
    const { data: templateRows } = await supabase
        .from('payment_term_templates')
        .select('id, name')
        .is('deleted_at', null)
        .eq('is_active', true)
        .order('name')
    const templates = [...(templateRows ?? [])]
    const currentTplId = supplier.default_payment_term_template_id
    if (currentTplId && !templates.some((tpl) => tpl.id === currentTplId)) {
        // 上面那句注释警告的正是这个失败模式,但它只挡住了"已停用",没挡住【查询失败】:
        // 读不到当前模板 → 选项里没有它 → 下拉回落到空的"无" → 一保存就静默清掉。
        const curRes = await supabase
            .from('payment_term_templates')
            .select('id, name')
            .eq('id', currentTplId)
            .single()
        const cur = mustOne(curRes, 'payment_term_templates current')
        if (cur) templates.unshift({ id: cur.id, name: `${cur.name} (${t('finance.inactive')})` })
    }

    // 在服务端按当前语言格式化时间,再传给客户端面板 —— 避免客户端 toLocaleString 引发水合不一致
    const attachments = (attachmentRows ?? []).map((a) => ({
        id: a.id,
        file_name: a.file_name,
        file_type: a.file_type,
        file_size: a.file_size,
        doc_category: a.doc_category,
        storage_path: a.storage_path,
        created_at_display: formatTimestamp(a.created_at, dateLocale),
    }))

    return (
        <div className="p-8 max-w-4xl">
            <div className="mb-6">
                <Link
                    href="/suppliers"
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-2">{t('suppliers.editTitle')}</h1>
            <p className="text-sm text-gray-600 mb-6">
                <span className="font-mono">{supplier.code}</span>
                <span className="mx-2">·</span>
                <span className="px-2 py-0.5 bg-gray-200 rounded text-xs">
                    {t('suppliers.status.' + supplier.status)}
                </span>
            </p>

            <StatusPanel id={supplier.id} currentStatus={supplier.status} />
            {/* GRN-2:摆在编辑表单【之前】—— 决定要不要再跟这家下单的人,
                该先读到这家的收货记录,而不是先看到一堆可改的字段。 */}
            <ReceiptPatternPanel
                row={patternRow}
                receipts={contributing}
                canSee={canSeePattern} />
            <EditSupplierForm supplier={supplier} templates={templates}
                gstRegistered={gstSettingsRes.data?.gst_registered ?? false}
                taxCodes={mustRows(gstCodesRes).map((c) => ({
                    code: c.code, name_en: c.name_en, name_zh: c.name_zh,
                }))} />
            <CompliancePanel
                supplierId={supplier.id}
                rows={complianceRows ?? []}
                certTypes={certTypeRows ?? []}
                attachments={(attachmentRows ?? []).map((a) => ({ id: a.id, file_name: a.file_name }))}
                locale={locale}
            />
            <AttachmentsPanel supplierId={supplier.id} rows={attachments} />

            {/* ── PARTY-1:供应商的联系人 ──────────────────────────────────
                ★【供应商此前【一列联系方式都没有】】★ 客户那三列是 2026-07-31 加的,
                供应商侧从来没有过 —— 所以这里不是一次迁移,是一个【缺口】。
                【为什么挂在编辑页上】今天没有供应商详情页(只有列表 / 新建 / 编辑),
                而供应商就是在这一页被维护的。有了详情页再搬。
                【抬头在服务端渲染】理由与客户那一页同一条:藏在客户端开关后面的
                针,fetch 冒烟看不见。 */}
            <section className="mt-6">
                <h2 className="text-lg font-semibold mb-1">{t('contacts.sectionTitle')}</h2>
                <p className="text-xs text-gray-600 mb-2 max-w-3xl">{t('contacts.sectionWhat')}</p>
                <ContactsPanel supplierId={supplier.id} rows={supplierContacts} canEdit={canEditSupplier} />
            </section>
        </div>
    )
}