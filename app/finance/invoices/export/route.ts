// TABLE-EXPORT-2a(Tim 2026-10-22 Q2 · Q8):发票列表的统一导出 —— 服务端那一半。
// 按页面【自己的】读取(../invoiceRows.ts)翻页取全,以 JSON 交给表。守卫与页面同一个判据(MOD.finance);
// 超过 50,000 行按名拒绝。筛「全部」时在册的与作废的是两条读取,首尾相接(与页面同序:在册在前)。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { MOD } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportUnionResponse, exportDenied } from '@/lib/export/serverRows'
import { parseInvoiceListParams, issuedCount, issuedPage, voidCount, voidPage, shapeInvoiceRows } from '../invoiceRows'

export async function GET(request: NextRequest) {
    if (!(await canEnter(MOD.finance.permission))) return exportDenied()
    const p = parseInvoiceListParams(Object.fromEntries(request.nextUrl.searchParams))
    const supabase = await createClient()
    const issued = {
        count: async () => mustCount(await issuedCount(supabase, p), 'invoice_status'),
        page: (from: number, to: number) => issuedPage(supabase, p, from, to),
    }
    const voids = {
        count: async () => mustCount(await voidCount(supabase, p), 'invoices void'),
        page: (from: number, to: number) => voidPage(supabase, p, from, to),
    }
    return exportUnionResponse({
        label: 'invoices',
        sources: p.status === 'void' ? [voids] : p.status === 'all' ? [issued, voids] : [issued],
        shape: (rows) => shapeInvoiceRows(rows),
    })
}
