// app/finance/bank/import/page.tsx
// 导入页(服务端壳):取在册映射档,表单交给客户端组件 —— CSV 解析全在浏览器里做
// (文件不上传服务器,只把解析好的行随 action 提交)。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import ImportStatementForm, { type ProfileOption } from './ImportStatementForm'
import type { BankMapping } from '@/lib/bankCsv'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function ImportStatementPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const res = await supabase
        .from('bank_import_profiles')
        .select('id, bank_account_code, name, mapping')
        .is('deleted_at', null)
        .order('name')

    if (res.error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('bank.importTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(res.error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const profiles: ProfileOption[] = mustRows(res).map((p) => ({
        id: p.id,
        bank_account_code: p.bank_account_code,
        name: p.name,
        mapping: p.mapping as unknown as BankMapping,
    }))

    return (
        <div className="p-8 max-w-6xl">
            <h1 className="text-2xl font-bold mb-4">{t('bank.importTitle')}</h1>
            <ImportStatementForm profiles={profiles} />
        </div>
    )
}
