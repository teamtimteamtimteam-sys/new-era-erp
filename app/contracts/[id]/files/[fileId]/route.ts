// CONTRACT-ESIGN(Tim 2026-10-30 Q8 · Q11):取一份合同文件 —— 流【存下的字节】,并对着 contract_files.sha256 重算,对不上 409
//   (一份与记录不符的"签过的合同"比没有更坏 —— 与 COD 的 streamStored 同一个形状)。
//   读不读得到由库定:那一行与那个对象都要那一侧的读码 + 价格码(contract_file_readable);读不到 → 404(与看不见的合同同一个答案)。
//   作废的版本照样取得到(Q7:留着、标「作废」)。还在传 / 没传成的不给。
import { NextResponse } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { mustOne } from '@/lib/db-helpers'
import { CONTRACT_FILES_BUCKET, readStored } from '@/lib/contractFiles'

export const dynamic = 'force-dynamic'

export async function GET(_request: Request, { params }: { params: Promise<{ id: string; fileId: string }> }) {
    const { id, fileId } = await params
    const supabase = await createClient()
    const row = mustOne(
        await supabase.from('contract_files').select('file_path, file_name, sha256, status')
            .eq('id', fileId).eq('contract_id', id).in('status', ['current', 'superseded', 'void']).maybeSingle(),
        'contract_files'
    ) as { file_path: string; file_name: string; sha256: string; status: string } | null
    if (!row) return new NextResponse('Not found', { status: 404 })
    const got = await readStored(supabase, CONTRACT_FILES_BUCKET, row.file_path, row.sha256)
    if (!got.ok) {
        return got.code === 'HASH_MISMATCH'
            ? new NextResponse('Stored file does not match its recorded digest', { status: 409 })
            : new NextResponse('Stored file unavailable', { status: 404 })
    }
    const name = row.file_name.toLowerCase().endsWith('.pdf') ? row.file_name : `${row.file_name}.pdf`
    return new NextResponse(Buffer.from(got.bytes), {
        headers: {
            'Content-Type': 'application/pdf',
            'Content-Disposition': `inline; filename="contract.pdf"; filename*=UTF-8''${encodeURIComponent(name)}`,
            'Cache-Control': 'private, no-store',
            'X-Content-SHA256': row.sha256,
        },
    })
}
