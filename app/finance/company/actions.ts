'use server'

// 公司抬头设置:更新那唯一一行 + logo 的上传/移除。
// logo 走私有桶 company-assets;类型与大小在这里把关(PNG/JPG,≤2MB)。
// SVG 【不接受】—— @react-pdf/renderer 的 Image 不支持 SVG,收下只会得到一份缺图的
// 发票,那比当场拒收更糟。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { revalidatePath } from 'next/cache'

const BUCKET = 'company-assets'
const MAX_LOGO_BYTES = 2 * 1024 * 1024
const ALLOWED_LOGO_MIME = ['image/png', 'image/jpeg']

export type CompanyState = { error?: string; success?: boolean }

const TEXT_FIELDS = [
    'legal_name',
    'registration_no',
    'address_lines',
    'city',
    'postal_code',
    'country',
    'phone',
    'email',
    'website',
    'bank_name',
    'bank_account_name',
    'bank_account_no',
    'bank_swift',
    'bank_address',
    'invoice_footer_text',
] as const

export async function saveCompanyProfile(
    _prevState: CompanyState,
    formData: FormData
): Promise<CompanyState> {
    const t = await getTranslations()

    const legalName = String(formData.get('legal_name') ?? '').trim()
    if (!legalName) {
        return { error: t('company.errLegalName') }
    }

    const patch: Record<string, string | null> = {}
    for (const f of TEXT_FIELDS) {
        const v = String(formData.get(f) ?? '').trim()
        patch[f] = v || null
    }
    patch.legal_name = legalName // NOT NULL,不能写 null

    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase
        .from('company_profile')
        .update({ ...patch, updated_by: user?.id ?? null })
        .eq('id', true)

    if (error) return { error: error.message }

    revalidatePath('/finance/company')
    return { success: true }
}

// logo 上传:文件本体在服务端接收并直传私有桶(文件不大,不必走浏览器直传)
export async function uploadLogo(
    _prevState: CompanyState,
    formData: FormData
): Promise<CompanyState> {
    const t = await getTranslations()
    const file = formData.get('logo')

    if (!(file instanceof File) || file.size === 0) {
        return { error: t('company.errNoFile') }
    }
    if (file.size > MAX_LOGO_BYTES) {
        return { error: t('company.errLogoTooLarge') }
    }
    if (!ALLOWED_LOGO_MIME.includes(file.type)) {
        return { error: t('company.errLogoType') }
    }

    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const ext = file.type === 'image/png' ? 'png' : 'jpg'
    // 固定前缀 + 随机名:换 logo 时旧文件留在桶里(便于回退),DB 只指向当前这个
    const path = `logo/${crypto.randomUUID()}.${ext}`

    const { error: upErr } = await supabase.storage
        .from(BUCKET)
        .upload(path, file, { contentType: file.type, upsert: false })
    if (upErr) return { error: t('company.errUpload', { message: upErr.message }) }

    const { error } = await supabase
        .from('company_profile')
        .update({ logo_path: path, updated_by: user?.id ?? null })
        .eq('id', true)
    if (error) return { error: error.message }

    revalidatePath('/finance/company')
    return { success: true }
}

// 移除 logo:只清 DB 指针,桶里的对象保留(与附件模块一致的软处理)
export async function removeLogo(): Promise<CompanyState> {
    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase
        .from('company_profile')
        .update({ logo_path: null, updated_by: user?.id ?? null })
        .eq('id', true)
    if (error) return { error: error.message }

    revalidatePath('/finance/company')
    return { success: true }
}
