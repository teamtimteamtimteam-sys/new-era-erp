'use client'

// 公司抬头设置表单:身份 / 地址 / 联系方式 / 银行资料 / 单据 五组。
// logo 单独一个小表单(上传即生效),与主表单互不影响。
import { useActionState, useTransition } from 'react'
import Image from 'next/image'
import { saveCompanyProfile, uploadLogo, removeLogo, type CompanyState } from './actions'
import { useTranslations } from '@/lib/i18n/client'

const initialState: CompanyState = {}

export type CompanyProfileRow = {
    legal_name: string
    registration_no: string | null
    address_lines: string | null
    city: string | null
    postal_code: string | null
    country: string | null
    phone: string | null
    email: string | null
    website: string | null
    bank_name: string | null
    bank_account_name: string | null
    bank_account_no: string | null
    bank_swift: string | null
    bank_address: string | null
    invoice_footer_text: string | null
    logo_path: string | null
}

export default function CompanyProfileForm({
    profile,
    logoUrl,
}: {
    profile: CompanyProfileRow
    logoUrl: string | null
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(saveCompanyProfile, initialState)
    const [logoState, logoAction, logoPending] = useActionState(uploadLogo, initialState)
    const [removing, startRemove] = useTransition()

    const field = (
        name: keyof CompanyProfileRow,
        labelKey: string,
        opts: { required?: boolean; textarea?: boolean; rows?: number } = {}
    ) => (
        <div className={opts.textarea ? '' : 'flex-1 min-w-[14rem]'}>
            <label className="block text-sm font-medium mb-1">
                {t(labelKey)} {opts.required && <span className="text-red-600">*</span>}
            </label>
            {opts.textarea ? (
                <textarea
                    name={name}
                    rows={opts.rows ?? 3}
                    defaultValue={(profile[name] as string) ?? ''}
                    className="w-full border border-gray-300 px-3 py-2 rounded"
                />
            ) : (
                <input
                    type="text"
                    name={name}
                    required={opts.required}
                    defaultValue={(profile[name] as string) ?? ''}
                    className="w-full border border-gray-300 px-3 py-2 rounded"
                />
            )}
        </div>
    )

    const group = (titleKey: string, children: React.ReactNode) => (
        <fieldset className="border border-gray-200 rounded p-4">
            <legend className="text-sm font-medium px-1">{t(titleKey)}</legend>
            <div className="space-y-3">{children}</div>
        </fieldset>
    )

    return (
        <div className="space-y-6 max-w-3xl">
            <p className="text-sm text-gray-500">{t('company.note')}</p>

            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">{state.error}</div>
            )}
            {state.success && (
                <div className="bg-green-50 border border-green-300 text-green-800 px-4 py-3 rounded text-sm">
                    {t('company.saved')}
                </div>
            )}

            <form action={formAction} className="space-y-5">
                {group(
                    'company.groupIdentity',
                    <>
                        <div className="flex flex-wrap gap-3">
                            {field('legal_name', 'company.legalName', { required: true })}
                            {field('registration_no', 'company.registrationNo')}
                        </div>
                        <div className="flex flex-wrap gap-3">{field('website', 'company.website')}</div>
                        {/* GST 登记号不在这里 —— 它住在财务设置(同一个号只存一份)*/}
                        <p className="text-xs text-gray-500">{t('company.gstNote')}</p>
                    </>
                )}

                {group(
                    'company.groupAddress',
                    <>
                        {field('address_lines', 'company.addressLines', { textarea: true, rows: 3 })}
                        <div className="flex flex-wrap gap-3">
                            {field('city', 'company.city')}
                            {field('postal_code', 'company.postalCode')}
                            {field('country', 'company.country')}
                        </div>
                    </>
                )}

                {group(
                    'company.groupContact',
                    <div className="flex flex-wrap gap-3">
                        {field('phone', 'company.phone')}
                        {field('email', 'company.email')}
                    </div>
                )}

                {group(
                    'company.groupBank',
                    <>
                        <div className="flex flex-wrap gap-3">
                            {field('bank_name', 'company.bankName')}
                            {field('bank_account_name', 'company.bankAccountName')}
                        </div>
                        <div className="flex flex-wrap gap-3">
                            {field('bank_account_no', 'company.bankAccountNo')}
                            {field('bank_swift', 'company.bankSwift')}
                        </div>
                        {field('bank_address', 'company.bankAddress', { textarea: true, rows: 2 })}
                    </>
                )}

                {group(
                    'company.groupDocuments',
                    field('invoice_footer_text', 'company.invoiceFooterText', { textarea: true, rows: 2 })
                )}

                <button
                    type="submit"
                    disabled={isPending}
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {isPending ? t('common.saving') : t('common.save')}
                </button>
            </form>

            {/* logo:独立小表单,上传即生效 */}
            <fieldset className="border border-gray-200 rounded p-4">
                <legend className="text-sm font-medium px-1">{t('company.logo')}</legend>

                {logoState.error && (
                    <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-2 rounded mb-3 text-sm">
                        {logoState.error}
                    </div>
                )}

                {logoUrl ? (
                    <div className="mb-3">
                        {/* 签名 URL 是外部主机,用普通 img 避免 next/image 的远程域白名单配置 */}
                        {/* eslint-disable-next-line @next/next/no-img-element */}
                        <img src={logoUrl} alt="logo" className="h-16 object-contain border border-gray-200 rounded p-2" />
                    </div>
                ) : (
                    <p className="text-sm text-gray-500 mb-3">{t('company.noLogo')}</p>
                )}

                <form action={logoAction} className="flex flex-wrap items-end gap-3">
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {logoUrl ? t('company.replaceLogo') : t('company.uploadLogo')}
                        </label>
                        <input
                            type="file"
                            name="logo"
                            accept="image/png,image/jpeg"
                            className="text-sm file:mr-3 file:rounded file:border-0 file:bg-blue-600 file:px-4 file:py-2 file:text-white hover:file:bg-blue-700"
                        />
                        <p className="text-xs text-gray-500 mt-1">{t('company.logoHint')}</p>
                    </div>
                    <button
                        type="submit"
                        disabled={logoPending}
                        className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                    >
                        {logoPending ? t('company.uploading') : t('company.upload')}
                    </button>
                    {logoUrl && (
                        <button
                            type="button"
                            disabled={removing}
                            onClick={() => startRemove(async () => { await removeLogo() })}
                            className="border border-red-300 text-red-600 px-4 py-2 rounded hover:bg-red-50 disabled:opacity-50"
                        >
                            {t('company.removeLogo')}
                        </button>
                    )}
                </form>
            </fieldset>
        </div>
    )
}
