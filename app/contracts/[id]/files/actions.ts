'use server'

// CONTRACT-ESIGN(Tim 2026-10-29 · 2026-10-30 A · E · Q7 · Q10 · Q12):合同电子文件的服务端那几步 —— 未签文件与对方签回件的【字节不经过这里】
//   (浏览器直传私有桶 contract-files,GOLIVE-2 第 9 行的形状;Vercel 的请求体上限 4.5 MB 管不到 25 MB 的文件)。这里只做:
//   begin   —— contract_file_begin:库判码、读权、合同状态、已签锁、PDF、25 MB,过了才登记一行 uploading、给出路径;
//   finish  —— 从存储里把那份对象【整份】读回来(读存储不是请求体,不受 4.5 MB 限):文件头必须是 PDF;未签文件还要打得开
//              (带密码 → CONTRACT_PDF_ENCRYPTED,因为之后盖不了章);算 sha256,交给 contract_file_finish(它再比一次大小与类型);
//              任何一步不过 → abandon;
//   abandon —— 没传成;
//   void    —— contract_file_void(签署人或 admin,要理由,Q7)。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { refuseFromCoded, type ActionOutcome } from '@/lib/action-refusal'
import { CONTRACT_FILES_BUCKET, checkPdf, isPdfHeader, sha256Hex } from '@/lib/contractFiles'
import { sniffFileType } from '@/lib/sniffFileType'
import { localizeEsignError } from './esignErrorCodes'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export type BeginResult = ActionOutcome & { id?: string; path?: string }

const refuse = (code: string) => refuseFromCoded(code, localizeEsignError)

function refresh() {
    revalidatePath('/contracts/[id]', 'page')
    revalidatePath('/contracts/[id]/sign', 'page')
}

export async function beginContractFile(input: {
    contractId: string; kind: 'original' | 'countersigned'; fileName: string; fileType: string; fileSize: number
}): Promise<BeginResult> {
    if (!UUID.test(input.contractId)) return refuse('CONTRACT_NOT_FOUND')
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('contract_file_begin', {
        p_contract_id: input.contractId,
        p_kind: input.kind,
        p_file_name: input.fileName || 'contract.pdf',
        // 浏览器已按文件头认过;认不出时交的是 application/octet-stream,库按名拒
        p_file_type: input.fileType,
        p_file_size: input.fileSize,
    })
    if (error) return refuseFromCoded(error.message, localizeEsignError)
    const slot = data as unknown as { id: string; path: string }
    return { id: slot.id, path: slot.path }
}

export async function finishContractFile(fileId: string): Promise<ActionOutcome> {
    if (!UUID.test(fileId)) return refuse('CONTRACT_FILE_NOT_FOUND')
    const supabase = await createClient()
    const abandon = async (code: string) => {
        await supabase.rpc('contract_file_abandon', { p_file_id: fileId })
        return refuse(code)
    }
    // 读回自己刚登记的那一行(读策略放行自己还在传的那一条)—— 路径与种类以库里那一行为准,不信浏览器交回来的
    const { data: found, error } = await supabase.from('contract_files').select('file_path, kind, status').eq('id', fileId).maybeSingle()
    if (error) return refuseFromCoded(error.message, localizeEsignError)
    const row = found as { file_path: string; kind: string; status: string } | null
    if (!row || row.status !== 'uploading') return refuse('CONTRACT_FILE_NOT_FOUND')
    const got = await supabase.storage.from(CONTRACT_FILES_BUCKET).download(row.file_path)
    if (got.error || !got.data) return abandon('CONTRACT_FILE_NOT_STORED')
    const bytes = new Uint8Array(await got.data.arrayBuffer())
    if (!isPdfHeader(bytes.subarray(0, 16))) return abandon('CONTRACT_FILE_TYPE_NOT_ACCEPTED|' + (sniffFileType(bytes.subarray(0, 16)) ?? 'application/octet-stream'))
    if (row.kind === 'original') {
        const pdf = await checkPdf(bytes)
        if (!pdf.ok) return abandon(pdf.code)
    }
    const { error: finErr } = await supabase.rpc('contract_file_finish', { p_file_id: fileId, p_sha256: sha256Hex(bytes) })
    if (finErr) {
        await supabase.rpc('contract_file_abandon', { p_file_id: fileId })
        return refuseFromCoded(finErr.message, localizeEsignError)
    }
    refresh()
    return { success: true }
}

export async function abandonContractFile(fileId: string): Promise<ActionOutcome> {
    if (!UUID.test(fileId)) return refuse('CONTRACT_FILE_NOT_FOUND')
    const supabase = await createClient()
    const { error } = await supabase.rpc('contract_file_abandon', { p_file_id: fileId })
    return error ? refuseFromCoded(error.message, localizeEsignError) : { success: true }
}

export async function voidContractFile(fileId: string, reason: string): Promise<ActionOutcome> {
    if (!UUID.test(fileId)) return refuse('CONTRACT_FILE_NOT_FOUND')
    if (!reason.trim()) return { ...(await refuse('CONTRACT_VOID_REASON_REQUIRED|')), field: 'reason' }
    const supabase = await createClient()
    const { error } = await supabase.rpc('contract_file_void', { p_file_id: fileId, p_reason: reason.trim() })
    if (error) return refuseFromCoded(error.message, localizeEsignError)
    refresh()
    return { success: true }
}
