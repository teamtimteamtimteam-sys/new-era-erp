// app/tools/pricing/formulas/page.tsx
// 定价公式列表:行数很少,不分页,但保留标准的记录数。已软删的不列。
import { Button } from '@/app/components/ui/button'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { formatMoneyBare } from '@/lib/format'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import FormulasTable, { type FormulaRow as FormulasTableRow } from './FormulasTable'

type FormulaRow = {
    id: string
    code: string
    name: string
    direction: string
    price_basis: string
    price_index: string | null
    average_days: number | null
    treatment_charge_usd_per_tonne: number
    flat_discount_pct: number
    supplier_id: string | null
    customer_id: string | null
    is_active: boolean
}

export default async function FormulasPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.pricing)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const { data, error } = await supabase
        .from('pricing_formulas_masked')
        .select('id, code, name, direction, price_basis, price_index, average_days, treatment_charge_usd_per_tonne, flat_discount_pct, supplier_id, customer_id, is_active')
        .is('deleted_at', null)
        .order('code', { ascending: false })

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('pricing.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const rows = (data as unknown as FormulaRow[] | null) ?? []

    // 往来单位名:页级两次小 .in
    const supplierIds = Array.from(new Set(rows.map((r) => r.supplier_id).filter(Boolean))) as string[]
    const customerIds = Array.from(new Set(rows.map((r) => r.customer_id).filter(Boolean))) as string[]
    const [supRes, cusRes] = await Promise.all([
        supplierIds.length
            ? // LOG-1b:【这一处绝不过滤 counterparty_type】—— 解析器,不是选择器。
              supabase.from('supplier_lookup').select('id, legal_name').in('id', supplierIds)
            : Promise.resolve({ data: [] as { id: string; legal_name: string }[], error: null }),
        customerIds.length
            ? supabase.from('customer_lookup').select('id, legal_name').in('id', customerIds)
            : Promise.resolve({ data: [] as { id: string; legal_name: string }[], error: null }),
    ])
    // 视图列在生成类型里一律可空;行进了视图即非空 —— 取用处本地锁死。
    const nameById = new Map<string, string>()
    type NameRow = { id: string; legal_name: string }
    for (const s of mustRows(supRes) as unknown as NameRow[]) nameById.set(s.id, s.legal_name)
    for (const c of mustRows(cusRes) as unknown as NameRow[]) nameById.set(c.id, c.legal_name)

    const basisLabel = (r: FormulaRow) =>
        r.price_basis === 'average'
            ? t('pricing.basis.average', { days: r.average_days ?? 0 })
            : t('pricing.basis.spot')

    // CONV-5:套 CONV-1 的两文件模板。state 恒为 'ok' —— 抬头「新建公式」
    // 住在 actions 里(状态分支之前)。
    const tableRows: FormulasTableRow[] = rows.map((r) => ({
        id: r.id,
        code: r.code,
        name: r.name,
        direction: r.direction,
        basisLabel: basisLabel(r),
        treatmentChargeUsdPerTonne: r.treatment_charge_usd_per_tonne,
        flatDiscountPct: r.flat_discount_pct,
        counterpartyName: nameById.get(r.supplier_id ?? r.customer_id ?? '') ?? null,
        isActive: Boolean(r.is_active),
    }))

    return (
        <ListPage
            title={t('pricing.listTitle')}
            actions={
                <Button asChild>
                    <Link href="/tools/pricing/formulas/new">{t('pricing.new')}</Link>
                </Button>
            }
            state={{ kind: 'ok' }}
        >
            <FormulasTable rows={tableRows} empty={t('pricing.empty')} />
        </ListPage>
    )
}
