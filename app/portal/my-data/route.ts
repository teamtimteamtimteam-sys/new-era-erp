// app/portal/my-data/route.ts
// MES-9a(2026-10-19,MES-9 Step 0 Q20,Tim):【门户账号下载系统里关于它自己的一切】(PDPA 的访问请求)。
//   以这个请求自己的会话调 portal_export_my_data() —— 它只授 supplier_portal,先过 portal_require_link,只回调用者自己的东西。
//   一个员工会话调它是 42501(这里回 403);撤销了 / 会话结束 → 403 并带着那个码。成功 → 一份 JSON 附件。
import { NextResponse } from 'next/server'
import { createClient } from '@/lib/supabase/server'

export async function GET() {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('portal_export_my_data')
    if (error) {
        const code = (error.message.match(/([A-Z_]+)(?:\|.*)?$/)?.[1]) ?? error.code ?? 'ERROR'
        return NextResponse.json({ error: code }, { status: error.code === '42501' || code.startsWith('PORTAL_') ? 403 : 500 })
    }
    const stamp = new Date().toISOString().slice(0, 10)
    return new NextResponse(JSON.stringify(data, null, 2), {
        status: 200,
        headers: {
            'Content-Type': 'application/json; charset=utf-8',
            'Content-Disposition': `attachment; filename="my-data-${stamp}.json"`,
            'Cache-Control': 'no-store',
        },
    })
}
