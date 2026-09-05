'use server'

// 公司抬头设置:更新那唯一一行 + logo 的上传/移除。
// logo 走私有桶 company-assets;类型与大小在这里把关(PNG/JPG,≤2MB)。
// SVG 【不接受】—— @react-pdf/renderer 的 Image 不支持 SVG,收下只会得到一份缺图的
// 发票,那比当场拒收更糟。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { revalidatePath } from 'next/cache'
import { can, DATA_VIEW_BANKING } from '@/lib/permissions'

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

/**
 * FIX-2a item 3:被 data.view_banking 遮住的那五列。
 * 【它们与 company_profile_masked 里那五个 CASE WHEN 是同一份清单】——
 * 遮蔽在读的那一侧,这个数组是写的那一侧,两边说的必须是同一件事。
 * 新增一列银行字段时,两处一起加(与"遮蔽表加列要同时改授权与视图"同一条规矩)。
 */
const BANKING_FIELDS: readonly string[] = [
    'bank_name',
    'bank_account_name',
    'bank_account_no',
    'bank_swift',
    'bank_address',
]

export async function saveCompanyProfile(
    _prevState: CompanyState,
    formData: FormData
): Promise<CompanyState> {
    const t = await getTranslations()

    const legalName = String(formData.get('legal_name') ?? '').trim()
    if (!legalName) {
        return { error: t('company.errLegalName') }
    }

    // ★★【FIX-2a item 3:一次"看不见"不许被写成一次"清空"】★★
    //
    // 此前这个循环无条件写【全部十五列】,而 `v || null` 把空串变成 NULL。
    // 银行那五列在界面上对没有 data.view_banking 的人渲染成【空输入框】
    // (它们在 company_profile_masked 里被遮成 NULL),于是那个人改一下电话
    // 再保存,就会把公司真实的银行资料【清空】—— 而屏幕上什么都不会说。
    //
    // 【今天它打不着,而那是运气不是设计】实测:data.view_banking 与
    // module.finance.edit 恰好由同一批角色持有(admin / finance / gm),
    // 所以能保存的人都看得见。**但那是一次巧合**:授一个角色 finance.edit
    // 只要在权限屏上点几下,而那一刻不会有任何东西提醒任何人这件事。
    // 列授权也拦不住它 —— 实测 authenticated 对 bank_* 【有】UPDATE 权限
    // (被收回的只有 SELECT),所以数据库这一侧是放行的。
    //
    // 【判据是"这个人看得见这一列吗",不是"表单交了什么上来"】
    // 表单没交 = 可能是看不见(不渲染),也可能是清空(渲染了但留白)——
    // 两者在 FormData 里【是同一件事】(都是 null),所以不能从提交内容倒推,
    // 必须去问权限。这与 lib/permissions.ts 的立身之本是同一句话。
    const canBanking = await can(DATA_VIEW_BANKING)
    const writable = canBanking ? TEXT_FIELDS : TEXT_FIELDS.filter((f) => !BANKING_FIELDS.includes(f))

    const patch: Record<string, string | null> = {}
    for (const f of writable) {
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
