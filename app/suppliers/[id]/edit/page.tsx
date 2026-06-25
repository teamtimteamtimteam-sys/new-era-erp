import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import EditSupplierForm from './EditSupplierForm'
import StatusPanel from './StatusPanel'
import CompliancePanel from './CompliancePanel'
import { getTranslations } from '@/lib/i18n/server'

export default async function EditSupplierPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const { data: supplier, error } = await supabase
        .from('suppliers')
        .select('*')
        .eq('id', id)
        .is('deleted_at', null)
        .single()

    if (error || !supplier) {
        notFound()
    }

    const { data: complianceRows } = await supabase
        .from('supplier_compliance')
        .select('id, cert_type, cert_no, issuing_body, valid_from, valid_until, notes')
        .eq('supplier_id', id)
        .is('deleted_at', null)
        .order('created_at', { ascending: false })

    return (
        <div className="p-8 max-w-4xl">
            <div className="mb-6">
                <Link
                    href="/suppliers"
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-2">{t('suppliers.editTitle')}</h1>
            <p className="text-sm text-gray-600 mb-6">
                <span className="font-mono">{supplier.code}</span>
                <span className="mx-2">·</span>
                <span className="px-2 py-0.5 bg-gray-200 rounded text-xs">
                    {t('suppliers.status.' + supplier.status)}
                </span>
            </p>

            <StatusPanel id={supplier.id} currentStatus={supplier.status} />
            <EditSupplierForm supplier={supplier} />
            <CompliancePanel supplierId={supplier.id} rows={complianceRows ?? []} />
        </div>
    )
}