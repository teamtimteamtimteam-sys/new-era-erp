'use client'

// app/settings/roles/PermissionMatrix.tsx
// 角色的授权编辑:模块矩阵(View / Edit)+ data.* / action.* 勾选表。
//
// 【edit 蕴含 view 在界面里也强制】:勾 Edit 自动勾上 View,取消 View 一并取消 Edit。
// 不是给一句警告就算 —— 2b 量过,只授 edit 不授 view 会让 PostgREST 的
// INSERT ... RETURNING 直接 42501,整条写入路径断掉。那是坏配置,不是口味问题。
// 数据库那一道(set_role_permissions 的 EDIT_REQUIRES_VIEW)才是真正的守卫,
// 这里只是让人不必先犯错再被拒。
import { useState, useTransition } from 'react'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { saveRolePermissions } from '../accountsActions'
import { Button } from '@/app/components/ui/button'
import { CONTROL_CHECKBOX } from '@/app/components/ui/control-style'
import { EditableTable, type EditableColumn } from '@/app/components/ui/editable-table'

export type PermissionRow = {
    code: string
    category: string
    name_en: string
    name_zh: string
    description_en: string | null
    description_zh: string | null
    sort_order: number
}

/**
 * ★ DRAFT-6:一行 = 一个模块。**它必须是一个对象,不是那个模块串** ——
 * `EditableTable<T, D extends object>` 的 `page-owned` 那一支里 `D` 就是 `T`,
 * 而一个字符串不是 object。☞ 顺手把【只与目录有关、与勾选状态无关】的两件事
 * (显示名、有没有 edit 码)在这里算一次:它们不随 `codes` 变,
 * 算在渲染回调里只会每行每次重算一遍。
 */
type ModuleRow = { module: string; label: string; hasEdit: boolean }

export default function PermissionMatrix({
    roleId,
    permissions,
    initial,
    disabled = false,
}: {
    roleId: string
    permissions: PermissionRow[]
    initial: string[]
    disabled?: boolean
}) {
    const t = useTranslations()
    const locale = useLocale()
    const [codes, setCodes] = useState<string[]>(initial)
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [done, setDone] = useState(false)

    // 模块清单从目录里推导,不写死 —— 加一个模块只是往 permissions 表插两行
    const modules = Array.from(
        new Set(
            permissions
                .filter((p) => p.category === 'module')
                .map((p) => p.code.split('.')[1])
        )
    )
    const moduleMeta = (m: string) =>
        permissions.find((p) => p.code === `module.${m}.view`)

    // ★★【MANUAL-FIX-1 A:Edit 那一格【只在目录里真有这个码时】才画】★★
    //   此前这一列对每个模块【无条件】画一个勾选框,而模块清单是从任意
    //   module.* 码的中段推出来的 —— 于是 module.logistics.view 让物流有了一行,
    //   那一行的 Edit 框却对应着一个【不存在】的 module.logistics.edit。
    //   勾上它再保存,set_role_permissions 会以 PERMISSION_NOT_FOUND 拒掉
    //   【整次调用】—— 于是那一勾不只是没有生效,它还挡住了同一次保存里
    //   其它所有改动,而屏幕上没有一个字说明为什么。
    //   【不铸那个码,而是不画那一格】物流的写入【故意】挂在 module.purchasing.edit
    //   上(db/migrations/2026-09-01-navreg1-logistics-gets-its-own-code.sql:17-20:
    //   「铸一个没有任何策略引用的 module.logistics.edit,就是铸一个死码」)。
    //   目录是迁移级的,界面【不该能凭空造码】—— 那正是那条 RPC 守卫的原话。
    const catalogue = new Set(permissions.map((p) => p.code))
    const hasEditCode = (m: string) => catalogue.has(`module.${m}.edit`)

    const others = permissions
        .filter((p) => p.category !== 'module')
        .sort((a, b) => a.sort_order - b.sort_order)

    const has = (c: string) => codes.includes(c)

    const moduleRows: ModuleRow[] = modules.map((m) => {
        const meta = moduleMeta(m)
        return {
            module: m,
            label: meta
                ? (locale === 'zh' ? meta.name_zh : meta.name_en).replace(
                      /\s*[(（](view|查看)[)）]\s*$/i,
                      ''
                  )
                : m,
            hasEdit: hasEditCode(m),
        }
    })

    /* ★★ DRAFT-6 · `page-owned` 要一个【必填】的 `dirty`,而这张表的判据必须
       **按集合比,不按顺序比** —— 这不是讲究,是 `setModule` 的形状逼出来的:
       它是 `filter` 掉那两个码、再 `[...next, view, edit]` 追加回去
       (见下面那一段),于是**勾上再取消同一个模块,集合一模一样而顺序变了**。
       ☞ 一个 `join()` 的比较会在那一刻起【永远】说脏,而一个恒亮的
         「未保存」提醒等于没有提醒 —— 与 `#3` 那条「进门就脏」是同一个后果,
         只是走的是另一条路。
       ⚠ 站内 `<Link>` 不拦,是组件抬头声明过的限制。 */
    const codesKey = (list: readonly string[]) => [...list].sort().join('|')
    const matrixDirty = codesKey(codes) !== codesKey(initial)

    /* ════════════════════════════════════════════════════════════════════════
       ★★★【`#11` 的列 —— 而这一张的全部难处是【两个 `—` 会撞车】】★★★

       DRAFT-5 建议把 View / Edit 两列 `priority` 掉,`render` 投影
       **✓ / — / 没有这一档的那条短横**。★ 本刀的闸轮把它翻掉了,理由是量出来的:

       ┌ `—` 读作「**没勾**」   ← `#12` / `#14` 的只读投影惯用法(Tim 的 Q2,DRAFT-5)
       └ `—` 读作「**没有这样东西**」← 本表的 Q6 裁定(下面那一格,原样留着)

       ☞ **同一个字形,同一列,同一屏,两种意思。** 更难看的是:Q6 当初挑 `—`
         的理由**逐字**是「空格读起来像"还没勾",短横读起来像"这里没有这样东西"」——
         照搬那个惯用法,等于把 Q6 自己的论据当场推翻。
       ⚠ 而今天分辨这两者的东西是一个 `title=` **悬浮提示** —— 手机上根本没有悬浮。

       ★★ **Tim 的 Q1 裁定:模块是【唯一】的 priority 列;View / Edit 两列
         可编辑但不 priority,于是真勾选框待在手机展开区里(Q7);
         而两列的答案【用话】叠进模块那一格**(TABLE-PHONE-4,与 `#22` 同一条)。
       ☞ 话分得开三种状态,字形分不开 —— 而这正是本仓库那条
         「一个有意义的空要写成那句话本身」在**三态**上的样子。
       ★ 顺带买到两件:① 三个 priority 列正是这次搬家要治的那种溢出,现在只有一列;
         ② `permissions.noEditCapability` 从此不再只有悬浮才读得到。

       ★★ **`disabled` 这个入参【不接到 `canEdit` 上】**(Tim 的 Q3):
         `canEdit={false}` 会让**桌面**每一格退回 `render`,于是一个没有编辑权的人
         看到的从「一排灰掉的勾选框」变成「一排字」—— 那是一次没有人要求的行为改动。
         ☞ 所以 `canEdit` 保持默认,`disabled` 照旧传进那两个勾选框里。
       ⚠ **后果照直记:这两列的 `render` 在屏幕上【一次都渲染不到】** ——
         它们不是 priority(手机行不画),而 `canEdit` 恒真(桌面格画 `edit`)。
         留着它们是列描述符的契约要求,而**写成真话而不是一句占位**,
         是为了它哪天真的被画出来时不撒谎。
       ════════════════════════════════════════════════════════════════════════ */
    const answer = (code: string) =>
        has(code) ? t('permissions.granted') : t('permissions.notGranted')

    const moduleColumns: EditableColumn<ModuleRow, ModuleRow>[] = [
        {
            key: 'module',
            header: t('permissions.module'),
            priority: true,
            render: (r) => (
                <>
                    {r.label}
                    <span className="ml-2 text-xs text-gray-400">{r.module}</span>
                    {/* ★★ TABLE-PHONE-4 的叠加块:手机档拿掉的两列,带着各自的列头
                        叠在这里,**零次点按**,而且**是话不是字形**(见上面那一段)。
                        ⚠ 它【不能】改走展开区:那里画的是勾选框本身,而一个人
                          要先点开才读得到「这个模块到底授没授」。 */}
                    <div className="sm:hidden mt-1 space-y-0.5 font-sans text-xs text-gray-600">
                        <div>
                            <span className="text-gray-500">{t('permissions.view')}: </span>
                            {answer(`module.${r.module}.view`)}
                        </div>
                        <div>
                            <span className="text-gray-500">{t('permissions.edit')}: </span>
                            {r.hasEdit
                                ? answer(`module.${r.module}.edit`)
                                : t('permissions.noEditCapability')}
                        </div>
                    </div>
                </>
            ),
        },
        {
            key: 'view',
            header: t('permissions.view'),
            className: 'w-24 text-center',
            // ★ 见上面那段最后一条:这个投影今天渲染不到,而它说的是真话。
            render: (r) => answer(`module.${r.module}.view`),
            edit: (r) => (
                <input
                    type="checkbox"
                    className={CONTROL_CHECKBOX}
                    aria-label={`${r.label} ${t('permissions.view')}`}
                    disabled={disabled}
                    checked={has(`module.${r.module}.view`)}
                    onChange={(e) => setModule(r.module, 'view', e.target.checked)}
                />
            ),
        },
        {
            key: 'edit',
            header: t('permissions.edit'),
            className: 'w-24 text-center',
            render: (r) =>
                r.hasEdit ? (
                    answer(`module.${r.module}.edit`)
                ) : (
                    <span className="text-gray-400" title={t('permissions.noEditCapability')}>
                        —
                    </span>
                ),
            edit: (r) =>
                /* 目录里没有这个码 = 这个模块【没有】编辑这一档权限。
                   画一条短横而不是留空:空格读起来像"还没勾",
                   短横读起来像"这里没有这样东西"。

                   ★★【记录在案的例外 —— Tim 的 Q6 裁定,2026-09-21】★★
                   草稿模型那一族有一条通则:**一个【有意义的空】要写成
                   那句话本身,永远不要写 `—`**(先例:`#7` 的两处空、
                   `#26` 的「不计价」)。**这一格【不适用】那一条。**
                   ☞ 理由:那条通则管的是**一个空着的值** ——
                     「还没有人填」「这一栏不重要」都可能被读出来,
                     所以要用一句话把它钉死。
                     **而这一格根本不是一个值** —— 它说的是
                     **「这个模块没有『编辑』这样东西」**:
                     目录里没有 `module.<m>.edit` 这个码,
                     画一个勾选框等于让人勾一个**铸不出来的权限**
                     (`MANUAL-FIX-1 A` 为它付过一次账)。
                   ☞ **同族先例:`#20 OutputAssayForm` 的对照列**
                     (DRAFT-4 §1 Q4 旁注)—— 那里的 `—` 也是
                     「这个金属真的没有录过」,不是「还没填」。
                   ⚠ 后来的人:**不要把这一格"顺手统一"成一句话** ——
                     那会把一句「没有这样东西」改成一句「还没填」,
                     而后者是假的。

                   ★★【DRAFT-6 的收据(2026-09-21):这一整块理由【一个字都没有改】,
                     它只是跟着那一格从 `<td>` 搬进了 `edit()`。】★★
                   ⚠ 而 Tim 的 Q1 在它旁边加了一条**它管不到的**事:
                     这条短横只活在【桌面】那一列里。手机那一档分辨三种状态
                     靠的是模块格里那两行话(见上面那一段)——
                     **因为在那里,同一个 `—` 会与「没勾」撞车。** */
                r.hasEdit ? (
                    <input
                        type="checkbox"
                        className={CONTROL_CHECKBOX}
                        aria-label={`${r.label} ${t('permissions.edit')}`}
                        disabled={disabled}
                        checked={has(`module.${r.module}.edit`)}
                        onChange={(e) => setModule(r.module, 'edit', e.target.checked)}
                    />
                ) : (
                    <span className="text-gray-400" title={t('permissions.noEditCapability')}>
                        —
                    </span>
                ),
        },
    ]

    function setModule(m: string, kind: 'view' | 'edit', on: boolean) {
        const view = `module.${m}.view`
        const edit = `module.${m}.edit`
        setCodes((cur) => {
            let next = cur.filter((c) => c !== view && c !== edit)
            const hadView = cur.includes(view)
            const hadEdit = cur.includes(edit)
            if (kind === 'view') {
                // 取消 View 时一并取消 Edit(edit 没有 view 会让写入路径断掉)
                if (on) next = [...next, view, ...(hadEdit ? [edit] : [])]
            } else {
                // 勾 Edit 时自动补上 View
                if (on) next = [...next, view, edit]
                else if (hadView) next = [...next, view]
            }
            return next
        })
    }

    function toggleOther(code: string) {
        setCodes((cur) => (cur.includes(code) ? cur.filter((c) => c !== code) : [...cur, code]))
    }

    function save() {
        setError(null)
        setDone(false)
        startTransition(async () => {
            const res = await saveRolePermissions(roleId, codes)
            if (res.error) setError(res.error)
            else setDone(true)
        })
    }

    return (
        <div>
            <h2 className="mb-1">{t('permissions.matrixTitle')}</h2>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-3">{t('permissions.editRequiresViewHint')}</p>

            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">
                    {error}
                </div>
            )}
            {done && <p className="mb-3 text-sm text-green-700">{t('permissions.saved')}</p>}

            {/* ★★ DRAFT-6:模块矩阵搬上 `<EditableTable>`(`page-owned`)。
                ☞ 这一页**没有 `<form>`** —— `saveRolePermissions(roleId, codes)` 收的是
                  带类型的实参,所以这里**一座桥都不需要**,格子里也不会有 `name=`
                  (与 `#6`/`#7` 同一条,DRAFT-3 §2.2)。**这一张是纯粹的外观 + 手机档的活。**
                ⚠ 下面那一叠 data.* / action.* 的勾选**不是表**(它是一列带说明的
                  `<label>` 卡片,说明本身就是重点)—— 本刀一个字都没有碰它。 */}
            <EditableTable<ModuleRow, ModuleRow>
                rows={moduleRows}
                columns={moduleColumns}
                rowKey={(r) => r.module}
                phone={{ mode: 'columns' }}
                mode="page-owned"
                dirty={matrixDirty}
                labels={{ expand: t('common.expandRow') }}
                className="mb-6"
            />

            <h3 className="mb-1">{t('permissions.dataAndActions')}</h3>
            {/* 描述【就是重点】—— 要授出 data.view_pay 的人,应当先读到它到底泄露什么。 */}
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-3">{t('permissions.dataAndActionsHint')}</p>
            <div className="space-y-2 mb-6">
                {others.map((p) => (
                    <label
                        key={p.code}
                        className="flex gap-3 items-start border border-gray-200 rounded px-3 py-2"
                    >
                        <input
                            type="checkbox"
                            disabled={disabled}
                            className={`${CONTROL_CHECKBOX} mt-1`}
                            checked={has(p.code)}
                            onChange={() => toggleOther(p.code)}
                        />
                        <span className="text-sm">
                            <span className="font-medium">
                                {locale === 'zh' ? p.name_zh : p.name_en}
                            </span>
                            <span className="ml-2 text-xs text-gray-400">{p.code}</span>
                            <span className="block text-[color:var(--brand-muted-text)]">
                                {(locale === 'zh' ? p.description_zh : p.description_en) ?? ''}
                            </span>
                        </span>
                    </label>
                ))}
            </div>

            <Button
                type="button"
                onClick={save}
                disabled={pending || disabled}
            >
                {pending ? t('common.saving') : t('permissions.savePermissions')}
            </Button>
        </div>
    )
}
