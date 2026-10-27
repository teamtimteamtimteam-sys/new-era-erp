// app/compliance/supplier-certificates/page.tsx
// SYSTEM-MAP-1(Tim D4 · Q3,2026-10-27):供应商证书总表 —— 安全与合规底下,只读。每一家供应商在册的每一张证书一行,最早到期的在前。
//   【Q3:只列日期,不算状态】「过期 / 快到期 / 有效」要一个"今天"和每种证书自己的提前量,而那条判据已经住在库里
//     (db/views/operations_arms_all.sql 的证书那一臂)。在这里用 JS 再算一遍就是第二份实现 —— Tim 把状态列排进了 SYSTEM-MAP-2 的迁移
//     (docs/forward-queue.md)。所以这一页一个日子都不算,只按 valid_until 升序排,没有日期的排最后。
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

type Row = {
    id: string; supplier_id: string; cert_type_code: string; cert_no: string | null; issuing_body: string | null
    valid_from: string | null; valid_until: string | null
    suppliers: { code: string; legal_name: string; deleted_at: string | null } | null
}

export default async function SupplierCertificatesPage() {
    const denied = await requireFunction(FN.supplierCertificates)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const [certRes, typeRes] = await Promise.all([
        supabase.from('supplier_compliance')
            .select('id, supplier_id, cert_type_code, cert_no, issuing_body, valid_from, valid_until, suppliers ( code, legal_name, deleted_at )')
            .is('deleted_at', null)
            .order('valid_until', { ascending: true, nullsFirst: false }).order('id', { ascending: true }),
        supabase.from('certificate_types').select('code, name_en, name_zh'),
    ])
    const certs = (mustRows(certRes, 'supplier_compliance') as unknown as Row[]).filter((c) => !c.suppliers?.deleted_at)
    const typeName = new Map((mustRows(typeRes, 'certificate_types') as { code: string; name_en: string; name_zh: string }[])
        .map((ct) => [ct.code, locale === 'zh' ? ct.name_zh : ct.name_en]))

    const rows: SupplierCertRow[] = certs.map((c) => ({
        id: c.id,
        supplierId: c.supplier_id,
        supplier: c.suppliers ? `${c.suppliers.code} — ${c.suppliers.legal_name}` : '—',
        type: typeName.get(c.cert_type_code) ?? c.cert_type_code,
        number: c.cert_no,
        issuer: c.issuing_body,
        validFrom: c.valid_from ? formatDate(c.valid_from, locale) : '—',
        validFromRaw: c.valid_from,
        validUntil: c.valid_until ? formatDate(c.valid_until, locale) : '—',
        validUntilRaw: c.valid_until,
    }))

    return (
        <ListPage title={t('supplierCerts.title')} intro={t('supplierCerts.intro')} state={{ kind: 'ok' }}>
            <SupplierCertsTable rows={rows} empty={t('supplierCerts.empty')} />
        </ListPage>
    )
}
