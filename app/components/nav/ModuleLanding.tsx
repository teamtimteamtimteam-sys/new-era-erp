// app/components/nav/ModuleLanding.tsx
// 【一个一级模块的落地页】—— NAV-CLEANUP-1 ③/④,Tim 的 Q4 裁定。
//
// ════════════════════════════════════════════════════════════════════════════
// ★【它【只】列本模块自己的二级条目,而那份清单【从注册表派生】】★
// 所以它不可能与顶栏的二级菜单漂开 —— 两者读的是同一支
// getFunctionAccess(moduleId)。**这正是 Tim 否掉"经营内容"的理由**:
// 一个带经营数字的 Overview 是一件新的报表功能,它需要自己的口径与勘察,
// 而这一刀是导航。落地页在这里回答的只有一个问题:**这个模块底下有什么。**
//
// ★【进不去的条目画成「· 受限」,不是省略】★(D5)
// 「受限」与「不存在」在屏幕上必须分得开 —— 这个仓库为这条区别付过四次账。
//
// ★【空的时候要说出【是谁】空的,不是画一张白页】★(Tim 的 Q4 明令)
// 一个一条都进不去的读者看到的是一句具名的话,而不是一个什么都没有的框。
// 【它其实到不了这一步】落地页自己也有判据,进不来的人在菜单上就看见「· 受限」;
// 这一段是为"判据放行了、名下却一条都不给"这种不一致准备的 —— 那是个矛盾,
// 而矛盾要说出来。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'
import { getFunctionAccess } from '@/lib/moduleAccess'

export default async function ModuleLanding({
    moduleId,
    titleKey,
    /** 这一页自己那条条目的 href —— 不把自己列进自己的清单里。 */
    selfHref,
}: {
    moduleId: string
    titleKey: string
    selfHref: string
}) {
    const t = await getTranslations()
    const items = (await getFunctionAccess(moduleId)).filter(({ fn }) => fn.href !== selfHref)
    const openable = items.filter((i) => i.allowed)

    return (
        <div className="p-8">
            <h1 className="text-2xl font-bold mb-1">{t(titleKey)}</h1>
            {/* 【说出它是什么】—— 一个不说自己是什么的落地页会被当成"内容还没加载出来"。 */}
            <p className="text-sm text-[color:var(--brand-muted-glass)] mb-6 max-w-2xl">
                {t('nav.landingHint')}
            </p>

            {openable.length === 0 && (
                <p
                    data-landing-empty="1"
                    className="rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900 max-w-2xl"
                >
                    {t('nav.landingNothingOpen')}
                </p>
            )}

            <ul className="grid gap-2 sm:grid-cols-2 max-w-3xl">
                {items.map(({ fn, allowed }) =>
                    allowed ? (
                        <li key={fn.href}>
                            <Link
                                href={fn.href}
                                className="block rounded-[var(--brand-radius)] border border-[color:var(--brand-border)] px-4 py-3 text-sm hover:bg-[color:var(--brand-accent)]"
                            >
                                {t(fn.navKey)}
                            </Link>
                        </li>
                    ) : (
                        <li key={fn.href}>
                            <span
                                data-module-restricted="1"
                                title={t('dashboard.restrictedHint')}
                                className="block rounded-[var(--brand-radius)] border border-dashed border-[color:var(--brand-border)] px-4 py-3 text-sm text-[color:var(--brand-muted-glass)] cursor-default"
                            >
                                {t(fn.navKey)} · {t('common.restricted')}
                            </span>
                        </li>
                    ),
                )}
            </ul>
        </div>
    )
}
