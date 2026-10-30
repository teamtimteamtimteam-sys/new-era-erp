// CONTRACT-ESIGN:合同页「合同文件」那一块的服务端那一半 —— 读这份合同的每一个版本、把每一个控件按得下按不下(与理由)算好。
//   判据只说出来,不另判:能不能传 / 签 / 作废由库定(contract_file_begin · contract_sign_begin · contract_file_void),
//   这里按同样的几条先说一遍,让按不动的控件当场说出为什么(DBLOCK-1);库仍然会按名拒。
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { readAll } from '@/lib/readAll'
import { can } from '@/lib/permissions'
import { formatDateTime } from '@/lib/dates'
import { loadActorNames } from '@/app/components/ActorName'
import type { FileVersionView, UploadSlot } from './ContractFilesPanel'

type Row = {
    id: string; kind: 'original' | 'signed' | 'countersigned'; source_file_id: string | null
    status: 'uploading' | 'current' | 'superseded' | 'void' | 'abandoned'
    file_name: string; file_size: number | null; sha256: string | null; created_at: string; created_by: string; stored_at: string | null
    signer_name: string | null; signer_title: string | null; stamp_id: string | null; signature_page: number | null
    voided_at: string | null; voided_by: string | null; void_reason: string | null
}

type T = (key: string, values?: Record<string, string | number>) => string

export function fileSizeLabel(n: number | null): string {
    if (n === null) return ''
    // 一位小数、不分组(文件大小不是金额,不走 lib/format 的货币格式;不用 toLocaleString —— 它随浏览器而不随界面语言变)
    if (n < 1024) return `${n} B`
    if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
    return `${(n / 1024 / 1024).toFixed(1)} MB`
}

export async function loadContractFiles(supabase: SupabaseClient<Database>, t: T, locale: string, c: {
    id: string; code: string; status: string; customer_id: string | null; supplier_id: string | null
}) {
    const priceCode = c.customer_id ? 'data.view_prices' : 'data.view_purchase_prices'
    const sideCode = c.customer_id ? 'module.customers.view' : 'module.suppliers.view'
    const [readable, canTerms, canManage] = await Promise.all([
        (async () => (await can(sideCode)) && (await can(priceCode)))(),
        can('action.contract_terms'),
        can('action.manage_signatories'),
    ])
    if (!readable) return { readable: false as const, priceCode }

    const rows = mustRows(
        await readAll(() => supabase.from('contract_files')
            .select('id, kind, source_file_id, status, file_name, file_size, sha256, created_at, created_by, stored_at, signer_name, signer_title, stamp_id, signature_page, voided_at, voided_by, void_reason')
            .eq('contract_id', c.id).in('status', ['current', 'superseded', 'void'])
            .order('created_at', { ascending: false }), { label: 'contract_files' }),
        'contract_files') as unknown as Row[]
    const names = await loadActorNames(supabase, rows.flatMap((r) => [r.created_by, r.voided_by]))
    const who = (u: string | null) => (u && names.names.get(u)) || (names.restricted ? t('common.restricted') : t('contractFiles.someone'))

    // 我自己在不在名单上 —— 与 contract_sign_begin / contract_file_void 问的是同一支(持名单码的人读得到整张名单,所以不能按行数判)
    const signatory = mustOne(await supabase.rpc('contract_signatory_active'), 'contract_signatory_active') === true

    const currentOriginal = rows.find((r) => r.kind === 'original' && r.status === 'current') ?? null
    const currentSigned = currentOriginal ? rows.find((r) => r.kind === 'signed' && r.status === 'current' && r.source_file_id === currentOriginal.id) ?? null : null
    const currentCounter = currentSigned ? rows.find((r) => r.kind === 'countersigned' && r.status === 'current' && r.source_file_id === currentSigned.id) ?? null : null
    const statusLabel = t(`contracts.status.${c.status}`)

    const versions: FileVersionView[] = rows.map((r) => ({
        id: r.id, kind: r.kind, status: r.status as FileVersionView['status'],
        href: `/contracts/${c.id}/files/${r.id}`,
        fileName: r.file_name, sizeLabel: fileSizeLabel(r.file_size), sha256: r.sha256 ?? '',
        uploadedLine: r.kind === 'signed'
            ? t('contractFiles.signedBy', { name: r.signer_name ?? '', title: r.signer_title ?? '', at: r.stored_at ? formatDateTime(r.stored_at, locale) : '—' })
            : t('contractFiles.uploadedBy', { who: who(r.created_by), at: r.stored_at ? formatDateTime(r.stored_at, locale) : '—' }),
        signedLine: r.kind === 'signed'
            ? t(r.stamp_id ? 'contractFiles.signedWithStamp' : 'contractFiles.signedNoStamp', { page: r.signature_page ?? 1 })
            : null,
        voidLine: r.status === 'void'
            ? t('contractFiles.voidedBy', { who: who(r.voided_by), at: r.voided_at ? formatDateTime(r.voided_at, locale) : '—', reason: r.void_reason ?? '' })
            : null,
        voidable: (r.kind === 'signed' || r.kind === 'countersigned') && r.status === 'current',
    }))

    const ended = c.status !== 'draft' && c.status !== 'active'
    const original: UploadSlot = {
        allowed: canTerms, code: 'action.contract_terms',
        blockedReason: ended ? t('contractFiles.blocked.closed', { status: statusLabel })
            : currentSigned ? t('contractFiles.blocked.signedLocked') : null,
    }
    const countersigned: UploadSlot = {
        allowed: canTerms, code: 'action.contract_terms',
        blockedReason: !currentSigned ? t('contractFiles.blocked.needsSigned')
            : currentCounter ? t('contractFiles.blocked.countersignedFinal') : null,
    }
    const signBlocked =
        !currentOriginal ? t('contractFiles.blocked.noOriginal')
            : c.status !== 'active' ? t('contractFiles.blocked.notActive', { status: statusLabel })
            : currentSigned ? t('contractFiles.blocked.alreadySigned')
            : !signatory ? t('contractFiles.blocked.notSignatory')
            : null
    return {
        readable: true as const, priceCode, versions, original, countersigned,
        sign: { href: `/contracts/${c.id}/sign`, blockedReason: signBlocked },
        voidAllowed: signatory || canManage,
    }
}
