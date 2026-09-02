// app/finance/settings/page.tsx
// 财务设置:期间锁(locked_before)+ GST 注册开关(GST-3)。
// 早于锁定日的分录会被拒绝 —— 会产生此类分录的业务操作(计价/销售/过账盘点等)
// 也会被一并阻止。
//
// 【GST-3:这一页此前【只读 locked_before 一列】】所以 Tim 来这里找 GST 开关
// 时,它不是藏在别处 —— 它根本不在 app 里的任何地方。见 GstPanel。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import LockForm from './LockForm'
import GstPanel from './GstPanel'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD, FN } from '@/lib/modules'
import { getFunctionAccess } from '@/lib/moduleAccess'

export default async function FinanceSettingsPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const { data, error } = await supabase
        .from('finance_settings')
        .select('locked_before, gst_registered, gst_registration_no')
        .eq('id', true)
        .single()

    // ★ IA-BUILD-1 / D7:【审批链搬到设置去了】★ 连同它的把关码 ——
    // module.finance.view → action.manage_permissions(Tim 的裁定:配审批链是
    // 系统管理的事,不是财务的内务)。这一页从此只管期间锁与 GST 注册。
    // 【入口留一条交叉引用】来这里找审批链的人得知道它去哪了;进不去的人看见
    // 的是一条具名的限制,不是一处缺席(D5)。
    const approvalsAccess = (await getFunctionAccess('settings'))
        .find((f) => f.fn.href === FN.approvals.href)

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('finance.settingsTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const lockedBefore = data?.locked_before ?? null

    // SOD-1:【在人动手之前就说出来】—— 这一页的手动锁是一条直连 UPDATE,
    // 会撞上 trg_finance_settings_sod。撞了再说,人已经填完日期、按过按钮了。
    // 所以先问一句:这个人在【还开着的期间里】记过手工凭证吗?
    // 判据与守卫同源(source_type='manual' + created_by = 我),但这里只【报告】,
    // 不判定 —— 真正的判定要等他选了哪一天,而那是服务端的事。
    // 【error 必须接住】丢掉它,「认证够不着」与「这个人没登录」共用一条分支,
    // 而这里的后果是告知【悄悄消失】—— 读起来正好是"你没有冲突"。
    const { data: { user }, error: userErr } = await supabase.auth.getUser()
    const sodUnknown = !!userErr
    let myManualDates: string[] = []
    if (user && !sodUnknown) {
        const q = supabase
            .from('journal_entries')
            .select('entry_date')
            .eq('source_type', 'manual')
            .eq('created_by', user.id)
            .order('entry_date')
        const { data: mine } = lockedBefore
            ? await q.gte('entry_date', lockedBefore)
            : await q
        myManualDates = [...new Set((mine ?? []).map((e) => e.entry_date as string))]
    }

    return (
        <div className="p-8 max-w-2xl">
            <h1 className="text-2xl font-bold mb-4">{t('finance.settingsTitle')}</h1>

            <div className="bg-gray-50 rounded p-4 mb-6 text-sm">
                <span className="text-gray-600 mr-1">{t('finance.lockedBefore')}:</span>
                {lockedBefore ? (
                    <span className="font-mono font-medium">{lockedBefore}</span>
                ) : (
                    <span className="text-gray-400">{t('finance.notSet')}</span>
                )}
            </div>

            {/* D7:审批链的新家。 */}
            <div className="border border-gray-200 rounded p-4 mb-6 bg-white">
                <h2 className="font-semibold mb-1">{t('finance.approvals.title')}</h2>
                {approvalsAccess?.allowed ? (
                    <Link href={FN.approvals.href} className="text-sm text-blue-700 hover:underline">
                        {t('finance.approvals.movedToSettings')}
                    </Link>
                ) : (
                    <p data-module-restricted="1" title={t('dashboard.restrictedHint')} className="text-sm text-gray-600">
                        {t('finance.approvals.movedToSettings')} · {t('common.restricted')}
                    </p>
                )}
            </div>

            {/* SOD-1:职责分离的【事前】告知。控件不禁用 —— 会不会被拒,取决于
                他填哪一天,而那要服务端才知道。禁用一个可能完全合法的动作,
                与放一个注定失败的按钮是同一种错,只是方向相反。 */}
            {sodUnknown && (
                <p className="text-sm text-amber-800 bg-amber-50 border border-amber-200 rounded px-3 py-2 mb-3">
                    {t('finance.sod.cannotCheck')}
                </p>
            )}

            {myManualDates.length > 0 && (
                <p className="text-sm text-amber-800 bg-amber-50 border border-amber-200 rounded px-3 py-2 mb-3">
                    {t('finance.sod.lockNotice', {
                        dates: myManualDates.join('、'),
                    })}
                </p>
            )}

            <LockForm lockedBefore={lockedBefore} />

            {/* 手动锁是覆盖手段;正常关账走月结页 */}
            <p className="text-sm text-gray-500 mt-4">
                <Link href="/finance/close" className="text-blue-600 hover:underline">
                    {t('finance.useClosePage')}
                </Link>
            </p>

            <p className="text-sm text-gray-500 mt-6 mb-8">{t('finance.lockExplainer')}</p>

            {/* GST-3:注册开关。**这一页此前完全没有它** —— 而 GST-1/GST-2 建的
                每一样东西都挂在它后面,于是两刀的成果一个人也碰不到。 */}
            <GstPanel
                registered={data?.gst_registered ?? false}
                registrationNo={data?.gst_registration_no ?? null}
            />
        </div>
    )
}
