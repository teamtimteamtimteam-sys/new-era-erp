// app/compliance/supplier-certificates/page.tsx
// SYSTEM-MAP-1(Tim D4 · Q3,2026-10-27):供应商证书总表 —— 安全与合规底下,只读。每一家供应商在册的每一张证书一行,最早到期的在前。
//   【状态列:SYSTEM-MAP-2(Tim 2026-10-27 SYSTEM-MAP-1 Q3 → 64d-2)】「过期 / 快到期 / 有效」由库里那一份判据算
//     (db/functions/certificate_expiry_status.sql —— 提醒页 qualification_expiring 那一支读的同一支),经
//     db/views/supplier_certificate_status.sql 读出来。这一页一个日子都不算(在 JS 里再算一遍就是第二份实现),
//     仍按 valid_until 升序排,没有日期的排最后。
//   【门】requireFunction(FN.supplierCertificates) = module.suppliers.view,与 supplier_compliance / suppliers 的读策略同一个码。
//   【去处】每一行链到那家供应商的页面(证书的增改、附件、门户交上来的证书都在那里)。删掉了的证书与已删除的供应商不列。
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { formatDate } from '@/lib/dates'
import SupplierCertsTable, { type SupplierCertRow } from './SupplierCertsTable'
import { readAll } from '@/lib/readAll'

type Row = {
    id: string; supplier_id: string; supplier_code: string; supplier_name: string; cert_type_code: string; cert_no: string | null
    issuing_body: string | null; valid_from: string | null; valid_until: string | null; status: string
}

export default async function SupplierCertificatesPage() {
    const denied = await requireFunction(FN.supplierCertificates)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const [certRes, typeRes] = await Promise.all([
        // 删掉了的证书与已删除的供应商,视图自己就不列(它的 WHERE)
        readAll(() => supabase.from('supplier_certificate_status')
            .select('id, supplier_id, supplier_code, supplier_name, cert_type_code, cert_no, issuing_body, valid_from, valid_until, status')
            .order('valid_until', { ascending: true, nullsFirst: false }).order('id', { ascending: true }), { label: 'supplier_certificate_status' }),
        supabase.from('certificate_types').select('code, name_en, name_zh'),
    ])
    const certs = mustRows(certRes, 'supplier_certificate_status') as unknown as Row[]
    const typeName = new Map((mustRows(typeRes, 'certificate_types') as { code: string; name_en: string; name_zh: string }[])
        .map((ct) => [ct.code, locale === 'zh' ? ct.name_zh : ct.name_en]))

    const rows: SupplierCertRow[] = certs.map((c) => ({
        id: c.id,
        supplierId: c.supplier_id,
        supplier: `${c.supplier_code} — ${c.supplier_name}`,
        type: typeName.get(c.cert_type_code) ?? c.cert_type_code,
        number: c.cert_no,
        issuer: c.issuing_body,
        validFrom: c.valid_from ? formatDate(c.valid_from, locale) : '—',
        validFromRaw: c.valid_from,
        validUntil: c.valid_until ? formatDate(c.valid_until, locale) : '—',
        validUntilRaw: c.valid_until,
        status: c.status,
    }))

    return (
        <ListPage title={t('supplierCerts.title')} intro={t('supplierCerts.intro')} state={{ kind: 'ok' }}>
            <SupplierCertsTable rows={rows} empty={t('supplierCerts.empty')} />
        </ListPage>
    )
}
