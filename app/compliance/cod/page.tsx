// app/compliance/cod/page.tsx
// SYSTEM-MAP-1(Tim D4 · Q4,2026-10-27):销毁证书清单 —— 安全与合规底下,只读,一张证书一行,新的在前。
//   【门】requireFunction(FN.codList) = data.view_cod,与 certificates_of_destruction 的读策略逐字同一个码;
//     ★ COD-READERS(Tim 2026-10-29,64d-5)把它从 action.issue_cod(admin · warehouse)放宽成读的码:
//     admin · warehouse · cfo · cco · cto · finance · gm。别的角色在菜单上看到「受限」。
//   【这一页什么都不做】签发、作废、内部副本都在那一批的页面上(CertificatePanel);这里只给去处。
//     已签发 / 已作废的给【存档的那份字节】(…/cod/pdf?cod=<编号>,对着 sha256 校验),与批次页那条链接同一个地址 —— 只读,GET。
//   【批号】读 inbound_batches_masked(进料批的价格列对这些读者收着;这里只要 id 与 code)。
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { formatDate, formatAuditStamp } from '@/lib/dates'
import CodTable, { type CodRow } from './CodTable'

type Row = {
    id: string; code: string | null; status: 'pending' | 'issued' | 'void'; completed_on: string; issued_at: string | null
    inbound_batch_id: string; void_reason: string | null; created_at: string
}

export default async function CodListPage() {
    const denied = await requireFunction(FN.codList)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const cods = mustRows(await supabase.from('certificates_of_destruction')
        .select('id, code, status, completed_on, issued_at, inbound_batch_id, void_reason, created_at')
        .order('created_at', { ascending: false }).order('id', { ascending: true }), 'certificates_of_destruction') as Row[]
    const batchIds = [...new Set(cods.map((c) => c.inbound_batch_id))]
    const batches = batchIds.length
        ? mustRows(await supabase.from('inbound_batches_masked').select('id, code').in('id', batchIds), 'inbound_batches_masked') as { id: string; code: string }[]
        : []
    const batchCode = new Map(batches.map((b) => [b.id, b.code]))

    const statusLabel = { pending: t('cod.statusPending'), issued: t('cod.statusIssued'), void: t('cod.statusVoid') } as const
    const rows: CodRow[] = cods.map((c) => ({
        id: c.id,
        code: c.code,
        statusLabel: c.status === 'void' && c.void_reason ? `${statusLabel.void} · ${c.void_reason}` : statusLabel[c.status],
        batchId: c.inbound_batch_id,
        // 批号读不到(读者没有进料查看码)时印「—」,不编一个
        batchCode: batchCode.get(c.inbound_batch_id) ?? null,
        completedOn: formatDate(c.completed_on, locale),
        completedOnRaw: c.completed_on,
        issuedAt: c.issued_at ? formatAuditStamp(c.issued_at) : '—',
        issuedAtRaw: c.issued_at,
        pdfHref: c.status !== 'pending' && c.code ? `/inbound/${c.inbound_batch_id}/cod/pdf?cod=${encodeURIComponent(c.code)}` : null,
    }))

    return (
        <ListPage title={t('codList.title')} intro={t('codList.intro')} state={{ kind: 'ok' }}>
            <CodTable rows={rows} empty={t('codList.empty')} />
        </ListPage>
    )
}
