// app/inventory/inbound/[materialId]/page.tsx
// 库存钻取:某物料的在库进料批次(未软删 + remaining_qty > 0),按 remaining_qty 降序。
// cut 5:估值(单价 × 剩余)+ 库龄(距到货日,上色提示)。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { STAGE_OPTIONS, labelKeyForValue } from '@/app/inbound/options'
import { getTranslations } from '@/lib/i18n/server'
import { formatMoneyBare } from '@/lib/format'
import { toneForBucket, AGING_TONE_CLASSES } from '@/lib/valuation'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import InboundBatchesTable, { type InboundBatchRow } from './InboundBatchesTable'

type Row = {
    id: string
    code: string
    quantity: number
    remaining_qty: number
    unit: string
    stage: string
    arrival_date: string | null
    // FIX-2a:供应商名不再内嵌(内嵌对 suppliers 另套一遍 RLS),单独取后压进这里。
    supplier_id: string | null
}

// INV-VAL-1:估值视图的一行。landed_* 在没有 data.view_prices 时是 null
// (受限),而 unpriced 说的是"这批货有没有价" —— 两个判据,不许合并。
type Val = {
    id: string
    landed_unit_cost: number | null
    landed_value_base: number | null
    unpriced: boolean
    aging_days: number | null
    aging_bucket: string | null
}

export default async function InboundDrillPage({
    params,
}: {
    params: Promise<{ materialId: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.inventory)
    if (denied) return denied

    const { materialId } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    // INV-VAL-1:行数据仍从遮蔽表取(供应商要内嵌,而视图没有外键),
    // 【钱与库龄档从估值视图取】—— 口径与注销/盘点/勾稽同一份,
    // 档位是 aging_bucket 的结果,屏幕不再自己划边界。
    const [matRes, batchesRes, valRes] = await Promise.all([
        supabase.from('material_lookup').select('name').eq('id', materialId).single(),
        supabase
            .from('inbound_batch_lookup')
            // FIX-2a:内嵌 suppliers 要 module.suppliers.view,而这一页的守卫是
            // inventory.view —— sales 通过守卫却读不到供应商,整条查询少一列;
            // 而 inbound_batches_masked 本身要 inbound.view,sales 连行都没有。
            // 两半一起修:行走查名视图,供应商名单独取。
            .select('id, code, quantity, remaining_qty, unit, stage, arrival_date, supplier_id')
            .eq('material_id', materialId)
            .is('deleted_at', null)
            .gt('remaining_qty', 0)
            .order('remaining_qty', { ascending: false }),
        supabase
            .from('inbound_batch_valuation')
            .select('id, landed_unit_cost, landed_value_base, unpriced, aging_days, aging_bucket')
            .eq('material_id', materialId)
            .gt('remaining_qty', 0),
    ])

    if (matRes.error || !matRes.data) {
        notFound()
    }

    // 【失败必须失败】—— 与本页其余取数一致,不用 `?? []`。
    const rows = mustRows(batchesRes) as unknown as Row[]
    // FIX-2a:供应商名走查名视图,一次 .in() 取回。
    const supIds = Array.from(new Set(rows.map((r) => r.supplier_id).filter(Boolean))) as string[]
    const supName = new Map<string, string>()
    if (supIds.length) {
        for (const sup of mustRows(
            await supabase.from('supplier_lookup').select('id, legal_name').in('id', supIds),
            'supplier names'
        )) {
            supName.set(sup.id as string, sup.legal_name as string)
        }
    }
    const valById = new Map<string, Val>()
    for (const v of (valRes.data as unknown as Val[] | null) ?? []) valById.set(v.id, v)
    const total = rows.reduce((s, r) => s + r.remaining_qty, 0)
    // 估值汇总:只累计【拿得到到岸成本】的批次;未计价的单独计数提示。
    const totalValue = rows.reduce(
        (s, r) => s + (valById.get(r.id)?.landed_value_base ?? 0),
        0
    )
    // 【判据是 unpriced,不是"金额取不到"】受限读者的 landed_* 全是 null,
    // 拿它当未计价,这个徽标会对 operations 报出"全部未计价"—— 一句假话。
    const unpricedCount = rows.filter((r) => valById.get(r.id)?.unpriced === true).length

    const stageLabel = (v: string) => {
        const k = labelKeyForValue(STAGE_OPTIONS, v)
        return k ? t(k) : v
    }


    // ★【行数据在服务端压平】阶段标签、价格的两种缺席、库龄色调都在这里算完。
    const tableRows: InboundBatchRow[] = rows.map((r) => {
        const v = valById.get(r.id)
        const days = v?.aging_days ?? null
        const tone = toneForBucket(v?.aging_bucket ?? null)
        return {
            id: r.id,
            code: r.code,
            href: `/inbound/${r.id}/edit`,
            supplier: (r.supplier_id ? supName.get(r.supplier_id) : null) ?? '—',
            quantityText: `${r.quantity} ${r.unit}`,
            remainingText: `${r.remaining_qty} ${r.unit}`,
            stageLabel: stageLabel(r.stage),
            arrivalDate: r.arrival_date ?? '—',
            unitPriceText:
                v?.landed_unit_cost != null
                    ? formatMoneyBare(v.landed_unit_cost, '列头「到岸单位成本 (SGD)」')
                    : null,
            // 【判据是 unpriced,不是"金额取不到"】受限读者的 landed_* 全是 null。
            unitPriceAbsence: v?.unpriced ? t('valuation.unpriced') : t('valuation.priceRestricted'),
            batchValueText:
                v?.landed_value_base != null
                    ? formatMoneyBare(v.landed_value_base, '列头「批次价值 (SGD)」')
                    : '—',
            ageDays: days !== null && tone !== null ? String(days) : null,
            ageToneClass: tone !== null ? AGING_TONE_CLASSES[tone] : '',
        }
    })

    return (
        <ListPage
            breadcrumb={
                <Link href="/inventory" className="text-blue-600 hover:underline text-sm">
                    {t('inventory.drill.back')}
                </Link>
            }
            title={`${matRes.data.name} · ${t('inventory.drill.title')}`}
            // ★★ 详情页恒为 ok —— 这种物料在不在由上面的 notFound() 回答。
            state={{ kind: 'ok' }}
            notices={
                /* 汇总行:剩余合计 + 库存价值(已计价部分)+ 未计价批数 */
                <p className="text-sm mb-3">
                    <span className="text-gray-600 mr-1">{t('inventory.drill.sumLabel')}:</span>
                    <span className="font-mono">{total}</span>
                    <span className="mx-2 text-gray-300">·</span>
                    <span className="text-gray-600 mr-1">{t('valuation.colStockValue')}:</span>
                    <span className="font-mono">{formatMoneyBare(totalValue, '紧挨着的行标签「库存价值 (SGD)」')}</span>
                    {unpricedCount > 0 && (
                        <span className="ml-2 text-gray-400">
                            {t('valuation.unpricedCount', { n: unpricedCount })}
                        </span>
                    )}
                </p>
            }
        >
            <InboundBatchesTable rows={tableRows} />
        </ListPage>
    )
}
