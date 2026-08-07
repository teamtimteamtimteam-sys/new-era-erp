// app/finance/bank/import/page.tsx
// 导入页(服务端壳):取在册映射档,表单交给客户端组件 —— CSV 解析全在浏览器里做
// (文件不上传服务器,只把解析好的行随 action 提交)。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import ImportStatementForm, { type ProfileOption } from './ImportStatementForm'
import type { BankMapping } from '@/lib/bankCsv'

export default async function ImportStatementPage() {
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
            <Subnav />
            <ImportStatementForm profiles={profiles} />
        </div>
    )
}
