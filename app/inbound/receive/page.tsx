// app/inbound/receive/page.tsx
// 移动端现场收货页(服务端抓下拉数据,渲染客户端表单)。可在任意设备用 URL 直达。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import ReceiveForm, { type PoLineOption } from './ReceiveForm'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'

export default async function ReceivePage() {
    const supabase = await createClient()
    const t = await getTranslations()

    const [suppliersRes, materialsRes, poLinesRes] = await Promise.all([
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
    ])

    return (
        <div className="p-4 max-w-md mx-auto">
            <div className="mb-4">
                <Link href="/inbound" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-6">{t('receive.title')}</h1>

            <ReceiveForm
                suppliers={mustRows(suppliersRes)}
                materials={mustRows(materialsRes)}
                poLines={(mustRows(poLinesRes)) as PoLineOption[]}
            />
        </div>
    )
}
