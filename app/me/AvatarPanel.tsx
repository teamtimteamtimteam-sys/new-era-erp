'use client'

// app/me/AvatarPanel.tsx
// ════════════════════════════════════════════════════════════════════════════
// UI-1d ④:换头像的地方 —— /me,一个独立的小 fieldset,上传即生效
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么是 /me】(Tim 的裁定,UI-1d Q3)
//   ① /me 已经是头像下拉里「我的档案」那一行指向的地方(AvatarMenu.tsx),
//      而这一页的抬头写着它是【员工自助】—— 关于你自己的东西住在这里;
//   ② 形状是树里已经付过账的那一个:公司抬头页的 logo 小表单
//      (CompanyProfileForm.tsx)—— 一个独立 fieldset、上传即生效、
//      与页面其余部分互不影响;
//   ③ **不放进头像下拉**:UI-1c 刚把那张下拉做成一张【去处】的菜单,
//      而在一个"点外面就关"的菜单里塞一个文件选择器是个坏交互 ——
//      文件选择框一弹,焦点离开菜单,菜单就该关了。
//
// ★★【放在哪里【不是】强制手段 —— 策略才是】★★
//   这一段值得写死在代码里,因为它正是最容易被想反的一处:
//   "上传控件只出现在 /me,所以改不了别人的头像" 是一句【错的】推理。
//   直接调 uploadAvatar 这个 server action 绕开任何页面都是可能的。
//   真正拦住它的是**存储策略**:
//       name = auth.uid()::text || '.webp'
//   —— 写谁的头像由 JWT 里的 uid 决定,与请求从哪一页发出来【毫无关系】。
//   本刀对着线上双向证过这一条,并把策略注入成放行版看着断言变红。
//   见 db/migrations/2026-09-05-ui1d-avatar-bucket.sql 与本刀的证明脚本。
//
// ★【没有员工档案的人在这里【看得见这一段】】★ 这一页对没建档的账号本来
//   只画一句"去找管理员"(page.tsx 的早返回)。头像挂在【auth 账号】上,
//   不挂在员工档案上(UI-1d Step 2 的裁定),所以这一段被放在那个早返回
//   【之前】—— 一个 HR 还没建档的新人照样换得了自己的头像,而他的名字那一行
//   仍然按 UI-1a 的判据不画。两件事互不牵连,那正是"挂在 auth 账号上"的意思。
import { useActionState, useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import AvatarImage from '@/app/components/nav/AvatarImage'
import { uploadAvatar, removeAvatar, type AvatarState } from './avatarActions'
import { AVATAR_ALLOWED_MIME } from '@/lib/avatar'

const initialState: AvatarState = {}

export default function AvatarPanel({
    avatarUrl,
    initials,
}: {
    /** 与顶栏拿到的是【同一个地址】(同一个 lib/avatar.ts 拼的)。 */
    avatarUrl: string | null
    /** 与顶栏画的是【同一组首字母】—— UI-1a 的 initialsOf 算的,页面传下来。 */
    initials: string
}) {
    const t = useTranslations()
    const [state, formAction, pending] = useActionState(uploadAvatar, initialState)
    const [removing, startRemove] = useTransition()
    // ★★【移除失败也必须【说出来】】★★
    //   公司抬头页那个 logo 面板写的是 `await removeLogo()` —— **返回值直接丢掉**。
    //   于是移除失败时屏幕上【什么都不发生】:图还在,没有一个字说为什么。
    //   本刀不照抄那一处:一次失败的移除与一次没点到的按钮长得一模一样,
    //   而"什么都没发生"正是这个仓库反复点名的那种把缺席画成答案的写法。
    //   (那一处是既有缺陷,不在本刀范围里 —— 记在 docs/known-issues.md。)
    const [removeError, setRemoveError] = useState<string | null>(null)
    const error = state.error ?? removeError

    return (
        <fieldset className="border border-gray-200 rounded p-4 mb-6" data-panel="avatar">
            <legend className="text-sm font-medium px-1">{t('me.avatar')}</legend>

            {error && (
                <div
                    data-avatar-error=""
                    className="bg-red-100 border border-red-400 text-red-700 px-4 py-2 rounded mb-3 text-sm"
                >
                    {error}
                </div>
            )}

            <div className="flex flex-wrap items-end gap-4">
                {/* 预览用的是【顶栏那一个组件】—— 于是"图坏了回落成首字母"这条路
                    在这一页与在顶栏上是同一份实现,不是两份会漂开的实现。 */}
                <AvatarImage
                    src={avatarUrl}
                    initials={initials}
                    className="h-16 w-16 border border-gray-200"
                    initialsClassName="text-lg"
                    alt={t('me.avatar')}
                />

                <form action={formAction} className="flex flex-wrap items-end gap-3">
                    <div>
                        <label className="block text-sm font-medium mb-1" htmlFor="avatar-file">
                            {t('me.avatarChoose')}
                        </label>
                        <input
                            id="avatar-file"
                            type="file"
                            name="avatar"
                            accept={AVATAR_ALLOWED_MIME.join(',')}
                            className="text-sm file:mr-3 file:rounded file:border-0 file:bg-blue-600 file:px-4 file:py-2 file:text-white hover:file:bg-blue-700"
                        />
                        {/* 【这句话把三条闸原原本本说出来】2MB、三种格式、会被裁成方的。
                            人在选文件【之前】就知道会被拒什么,比事后一句红字好。 */}
                        <p className="text-xs text-gray-500 mt-1">{t('me.avatarHint')}</p>
                    </div>
                    <button
                        type="submit"
                        disabled={pending}
                        className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                    >
                        {pending ? t('me.avatarUploading') : t('me.avatarUpload')}
                    </button>
                    {/* 【移除永远画着】—— 页面不知道对象在不在(顶栏也不知道,理由同一条),
                        所以这里不能按"有没有头像"来决定画不画这个按钮。对一个本来
                        就没有头像的人按下去是一次无害的空操作,而把按钮藏起来则需要
                        先花一趟往返去问一个不必问的问题。 */}
                    <button
                        type="button"
                        disabled={removing || pending}
                        onClick={() => startRemove(async () => {
                            const r = await removeAvatar()
                            setRemoveError(r.error ?? null)
                        })}
                        className="border border-red-300 text-red-600 px-4 py-2 rounded hover:bg-red-50 disabled:opacity-50"
                    >
                        {t('me.avatarRemove')}
                    </button>
                </form>
            </div>
        </fieldset>
    )
}
