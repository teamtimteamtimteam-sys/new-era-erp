// app/inbound/receive/page.tsx
// 移动端现场收货页(服务端抓下拉数据,渲染客户端表单)。可在任意设备用 URL 直达。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import ReceiveForm, { type PoLineOption, type BlockedSupplier } from './ReceiveForm'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function ReceivePage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.inbound)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const [suppliersRes, materialsRes, poLinesRes, blockedRes] = await Promise.all([
        supabase
            .from('suppliers')
            .select('id, code, legal_name')
            .is('deleted_at', null)
            .order('legal_name'),
        supabase
            .from('materials')
            .select('id, code, name')
            .is('deleted_at', null)
            .order('name'),
        // 可收货的采购单行(cut 4c;客户端按供应商过滤)
        supabase
            .from('po_receivable_lines')
            .select('po_id, po_code, supplier_id, order_date, line_id, line_no, material_id, material_name, remaining_qty, unit')
            .order('po_code')
            .order('line_no'),
        // CMP-2:收货会被证书拦截的供应商(视图与触发器同一份谓词)——
        // 表单据此把拦截原因写在按钮旁,而不是让服务端的拒绝当第一声。
        supabase
            .from('supplier_receiving_blocked')
            .select('supplier_id, supplier_code, cert_type_code, name_en, name_zh, valid_until'),
    ])

    // IOD-1b:收货库位的可选清单 —— 只列在用库位(便利);停用/不存在由
    // resolve_receipt_location 在函数里点名拒,下拉挡不住直接调 RPC 的人。
    const locationChoices = mustRows(
        await supabase.from('storage_locations').select('id, code, name').eq('is_active', true).order('code'),
        'storage_locations'
    ) as unknown as { id: string; code: string; name: string }[]

    return (
        <div className="p-4 max-w-md mx-auto">
            <div className="mb-4">
                <Link href="/inbound" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-6">{t('receive.title')}</h1>

            <ReceiveForm
            locations={locationChoices}
                suppliers={mustRows(suppliersRes)}
                materials={mustRows(materialsRes)}
                poLines={(mustRows(poLinesRes)) as PoLineOption[]}
                blockedSuppliers={(mustRows(blockedRes)) as BlockedSupplier[]}
            />
        </div>
    )
}
