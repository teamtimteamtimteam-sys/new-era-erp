// APR-1(2026-09-22)· 这条策略的变更史。
//
// ★★【为什么这块面板非有不可 —— 而不是"顺手加的"】★★
// 本刀同时在修 APR0-WORK-ORDER-APPROVALS-INVISIBLE:一张留痕【写得进、读不出】,
// 而它的失败方式是一个安静的零。新建一张 finance_settings_history 却不在任何地方
// 读它,就是【当场把同一个形状再造一遍】—— 一份没有人看得见的留痕,
// 与没有留痕在屏幕上长得一模一样。
//
// ★【空集在这里【不许】读成"从来没变过"】★ 线上那一行(false · finance · cfo · 1000)
//   是这块屏幕存在之前直接改库设上的,所以本表在 APR-1 之后【是空的】,
//   而那不是一个缺陷。空状态那句话必须把这件事说出来,否则它读起来正好等于
//   "这条策略从来没有被人动过" —— 一句关于内控的、错误的断言。
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatDateTime } from '@/lib/dates'

export type PolicyChange = {
    id: string
    changed_at: string
    changed_by: string | null
    old_approvals_enabled: boolean | null
    new_approvals_enabled: boolean | null
    old_approval_level1_role_code: string | null
    new_approval_level1_role_code: string | null
    old_approval_level2_role_code: string | null
    new_approval_level2_role_code: string | null
    old_approval_threshold_base: string | number | null
    new_approval_threshold_base: string | number | null
}

export default async function ApprovalsHistory({
    rows,
    whoByUserId,
}: {
    rows: PolicyChange[]
    whoByUserId: Record<string, string>
}) {
    const t = await getTranslations()
    const locale = await getLocale()

    const unset = t('finance.approvals.historyUnset')
    const onOff = (v: boolean | null) =>
        v === null ? unset : v ? t('finance.approvals.historyOn') : t('finance.approvals.historyOff')
    const val = (v: string | number | null) => (v === null ? unset : String(v))

    // 【只列【真的变了】的那几格】把四行全列出来、其中三行两侧一样,
    // 读的人得自己去比对 —— 而一份变更史唯一不可替代的问题就是"哪里变了"。
    const changes = (r: PolicyChange) => {
        const out: string[] = []
        const push = (field: string, from: string, to: string) => {
            if (from !== to) out.push(t('finance.approvals.historyArrow', { field, from, to }))
        }
        push(t('finance.approvals.enabledLabel'),
            onOff(r.old_approvals_enabled), onOff(r.new_approvals_enabled))
        push(t('finance.approvals.level1'),
            r.old_approval_level1_role_code ?? unset, r.new_approval_level1_role_code ?? unset)
        push(t('finance.approvals.threshold'),
            val(r.old_approval_threshold_base), val(r.new_approval_threshold_base))
        push(t('finance.approvals.level2'),
            r.old_approval_level2_role_code ?? unset, r.new_approval_level2_role_code ?? unset)
        return out
    }

    return (
        <section className="border border-gray-200 rounded p-4 mb-6">
            <h2 className="mb-2">{t('finance.approvals.historyTitle')}</h2>
            {rows.length === 0 ? (
                <p className="text-sm text-[color:var(--brand-muted-text)] bg-gray-50 border border-gray-200 rounded px-3 py-2">
                    {t('finance.approvals.historyEmpty')}
                </p>
            ) : (
                <ul className="space-y-3">
                    {rows.map((r) => (
                        <li key={r.id} className="border-b border-gray-100 pb-2 last:border-0">
                            <p className="text-xs text-[color:var(--brand-muted-text)]">
                                {t('finance.approvals.historyBy', {
                                    who: (r.changed_by && whoByUserId[r.changed_by])
                                        || t('finance.approvals.historyWhoUnknown'),
                                    when: formatDateTime(r.changed_at, locale),
                                })}
                            </p>
                            <ul className="ml-4 list-disc text-sm">
                                {changes(r).map((line) => <li key={line}>{line}</li>)}
                            </ul>
                        </li>
                    ))}
                </ul>
            )}
        </section>
    )
}
