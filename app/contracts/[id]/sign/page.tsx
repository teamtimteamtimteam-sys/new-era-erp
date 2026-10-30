// CONTRACT-ESIGN(Tim 2026-10-30 Q1 · Q3 · Q4 · Q5 · Q6):签一份合同文件 —— 在用的那一份未签文件,一页一页预览,点选签名(与印章)落在哪一页哪个位置
//   (默认最后一页右下角),重新输入密码,签。签不了的时候页面照样打得开,说出为什么(DBLOCK-1):没有文件 · 合同不在生效中 · 已经签过 ·
//   不在名单上 · 还没有签名样本(去 /me 画一次)。读不到这份合同的文件(Q8)→「受限」与理由。看不见的合同 → 404(与合同页同一个答案)。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getLocale, getTranslations } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { Refusal } from '@/app/components/ui/refusal'
import { SIGNING_ASSETS_BUCKET, readStored } from '@/lib/contractFiles'
import SignForm from './SignForm'

export default async function SignContractPage({ params }: { params: Promise<{ id: string }> }) {
    const denied = await requireModule(MOD.suppliers)
    if (denied) return denied
    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    const found = mustRows(
        await supabase.from('contracts').select('id, code, title, status, customer_id, supplier_id').eq('id', id).is('deleted_at', null),
        'contracts') as { id: string; code: string; title: string; status: string; customer_id: string | null; supplier_id: string | null }[]
    const c = found[0]
    if (!c) notFound()
    const back = <Link href={`/contracts/${c.id}`} className="hover:underline text-sm app-link">{t('contractSign.back', { code: c.code })}</Link>
    const heading = <h1 className="mb-2"><span className="font-mono">{c.code}</span> · {t('contractSign.title')}</h1>

    const priceCode = c.customer_id ? 'data.view_prices' : 'data.view_purchase_prices'
    const sideCode = c.customer_id ? 'module.customers.view' : 'module.suppliers.view'
    if (!((await can(sideCode)) && (await can(priceCode)))) {
        return (
            <div className="p-8 max-w-4xl space-y-4">
                {back}{heading}
                <Refusal className="whitespace-normal text-left">{t('contractFiles.restricted', { code: priceCode })}</Refusal>
            </div>
        )
    }

    const files = mustRows(
        await supabase.from('contract_files').select('id, kind, status, source_file_id, file_name, sha256')
            .eq('contract_id', c.id).eq('status', 'current').limit(20),
        'contract_files') as { id: string; kind: string; status: string; source_file_id: string | null; file_name: string; sha256: string }[]
    const original = files.find((f) => f.kind === 'original') ?? null
    const signed = original ? files.find((f) => f.kind === 'signed' && f.source_file_id === original.id) ?? null : null
    const signatory = mustOne(await supabase.rpc('contract_signatory_active'), 'contract_signatory_active') === true

    // 我的签名样本(读策略只露本人那一行;图只有本人读得到)与在用的印章(签署人读得到)
    const me = mustOne(await supabase.rpc('current_user_employee'), 'current_user_employee') as string | null
    const specimen = signatory && me
        ? (mustRows(await supabase.from('signature_specimens').select('file_path, sha256').eq('employee_id', me).is('superseded_at', null).limit(1),
            'signature_specimens') as { file_path: string; sha256: string }[])[0] ?? null
        : null
    const stamp = signatory
        ? (mustRows(await supabase.from('company_stamps').select('file_path, sha256').is('superseded_at', null).limit(1),
            'company_stamps') as { file_path: string; sha256: string }[])[0] ?? null
        : null
    const dataUri = async (row: { file_path: string; sha256: string } | null) => {
        if (!row) return null
        const got = await readStored(supabase, SIGNING_ASSETS_BUCKET, row.file_path, row.sha256)
        return got.ok ? `data:image/png;base64,${Buffer.from(got.bytes).toString('base64')}` : null
    }
    const [specimenUri, stampUri] = await Promise.all([dataUri(specimen), dataUri(stamp)])

    const statusLabel = t(`contracts.status.${c.status}`)
    const blocked =
        !original ? t('contractFiles.blocked.noOriginal')
            : c.status !== 'active' ? t('contractFiles.blocked.notActive', { status: statusLabel })
            : signed ? t('contractFiles.blocked.alreadySigned')
            : !signatory ? t('contractFiles.blocked.notSignatory')
            : !specimenUri ? t('contractSign.noSpecimen')
            : null

    return (
        <div className="p-4 sm:p-8 max-w-5xl space-y-4">
            {back}
            <div>
                {heading}
                <p className="text-sm text-[color:var(--brand-muted-text)] max-w-3xl">{t('contractSign.intro')}</p>
            </div>
            {blocked || !original || !specimenUri ? (
                <div className="space-y-2" data-sign-blocked={c.code}>
                    <Refusal className="whitespace-normal text-left">{blocked}</Refusal>
                    {signatory && !specimenUri && <p className="text-sm"><Link href="/me#signature" className="app-link hover:underline">{t('contractSign.drawSpecimen')}</Link></p>}
                </div>
            ) : (
                <SignForm
                    contractId={c.id}
                    contractCode={c.code}
                    fileId={original.id}
                    fileName={original.file_name}
                    pdfHref={`/contracts/${c.id}/files/${original.id}`}
                    specimenUri={specimenUri}
                    stampUri={stampUri}
                    locale={locale}
                />
            )}
        </div>
    )
}
