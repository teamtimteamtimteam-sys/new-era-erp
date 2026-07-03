// app/inbound/[id]/label/route.ts
// GET -> 自包含的二维码打印标签页(text/html)。二维码指向该批次的鉴权编辑页
// (标签会随危险品箱离场,鉴权保持开启 —— 有意为之)。仅从 app 内部打开。
import type { NextRequest } from 'next/server'
import QRCode from 'qrcode'
import { createClient } from '@/lib/supabase/server'
import { buildLabelHtml } from '@/app/components/labels/labelHtml'

type BatchRow = {
    id: string
    code: string
    quantity: number
    unit: string
    materials: { name: string } | null
    suppliers: { legal_name: string } | null
}

export async function GET(
    request: NextRequest,
    { params }: { params: Promise<{ id: string }> }
) {
    const { id } = await params
    const supabase = await createClient()

    const {
        data: { user },
    } = await supabase.auth.getUser()
    if (!user) {
        return Response.json({ error: 'unauthorized' }, { status: 401 })
    }

    const { data, error } = await supabase
        .from('inbound_batches')
        .select('id, code, quantity, unit, materials ( name ), suppliers ( legal_name )')
        .eq('id', id)
        .is('deleted_at', null)
        .single()

    if (error || !data) {
        return Response.json({ error: 'not_found' }, { status: 404 })
    }

    const b = data as unknown as BatchRow
    const url = request.nextUrl.origin + `/inbound/${id}/edit`
    const qrDataUrl = await QRCode.toDataURL(url, { width: 480, margin: 1 })

    const html = buildLabelHtml({
        kind: 'inbound',
        code: b.code,
        qrDataUrl,
        materialName: b.materials?.name ?? '',
        quantity: b.quantity,
        unit: b.unit,
        detailValue: b.suppliers?.legal_name ?? null,
    })

    return new Response(html, {
        headers: { 'Content-Type': 'text/html; charset=utf-8' },
    })
}
