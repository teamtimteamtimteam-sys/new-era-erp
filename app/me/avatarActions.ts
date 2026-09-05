'use server'

// app/me/avatarActions.ts
// ════════════════════════════════════════════════════════════════════════════
// UI-1d:头像的上传与移除。**服务端收字节、服务端重新编码。**
// ════════════════════════════════════════════════════════════════════════════
//
// ★★【这不是新机器,这是 logo 那一处的形状 + 一句 sharp】★★
//   本刀的委托书把我支去读三份 AttachmentsPanel,并断言「NONE of them touches
//   image bytes」「the image handling is new」。两句都不对,而正确的先例
//   一直在树里:**app/finance/company/actions.ts 的 uploadLogo** —— 公司抬头的
//   logo,≤2MB、image/png + image/jpeg、由【服务端】收下 File 再传桶,
//   理由就写在那一行边上:「文件不大,不必走浏览器直传」。
//   所以 Step 1 要的「服务端持有字节」这件事,这棵树已经付过账了。
//
//   ★【记一句:这是同一种病的第三例】★ FIX-2a 记过它 —— **委托书描述的是
//     上一刀的小结,不是树本身。** UI-1c 的闸轮抓到四条假断言(其中一份文件
//     两刀之前就被删了),本刀抓到三条。判据不变:**先量,再改。**
//
// 【与 logo 那一处【不同】的两件事,各有理由】
//   ① 存的是【服务端产出的字节】,不是收到的字节。Tim 推翻了浏览器 canvas
//      重编码 + 服务端魔数校验的方案:「With (b) you store bytes a client
//      produced, magic-byte check or not; with (a) you store bytes you produced.」
//      这张图画在【每一个人、每一页】的顶栏上,而这是全系统唯一一处
//      由使用者往里放二进制的地方。
//   ② 桶是【公开】的,对象名是【固定】的(<uid>.webp,覆盖写)。logo 用
//      随机名 + 私有桶 + 一列指针;这里没有指针可存(见 lib/avatar.ts 抬头),
//      于是"对象在不在"就是状态本身。
//
// ★★【解码不可信的图片字节,就是这一刀买来的攻击面。它被三道闸夹住】★★
//   ① 大小:> 2MB 当场拒,**在任何解码之前**;
//   ② 尺寸:sharp 的 metadata() 【只读文件头,不解码像素】—— 实测一张
//      9000×9000 的纯色 PNG 只有 231KB(过得了①),而解码它是 81 兆像素。
//      所以这一闸落在攻击面【打开之前】,而不是之后;
//   ③ limitInputPixels:同一个数交给 libvips 自己再兜一层。
//   解码失败【是一句人看得见的话】,不是一次崩溃 —— try/catch 把 sharp 抛的
//   'Input buffer contains unsupported image format' 换成 t('me.errAvatarDecode')。
//
// ★【桶里绝不会出现一个 0 字节的对象】★ 上传那一句在【重编码返回了字节之后】
//   才发生,而且长度为 0 时当场返回错误。一个空对象会 200 给一张画不出来的图,
//   而那与"这个人没传过头像"在屏幕上不是同一件事 —— 前者是坏的,后者是首字母。
import { revalidatePath } from 'next/cache'
import { cookies } from 'next/headers'
import sharp from 'sharp'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import {
    AVATAR_ALLOWED_MIME,
    AVATAR_BUCKET,
    AVATAR_CACHE_SECONDS,
    AVATAR_EDGE_PX,
    AVATAR_LIMIT_INPUT_PIXELS,
    AVATAR_MAX_BYTES,
    AVATAR_MAX_INPUT_DIMENSION,
    AVATAR_VERSION_COOKIE,
    AVATAR_VERSION_COOKIE_MAX_AGE,
    AVATAR_WEBP_QUALITY,
    avatarObjectName,
} from '@/lib/avatar'

export type AvatarState = { error?: string; success?: boolean }

/**
 * 【认证的三态在这里也必须活着】(scripts/check-auth-error-swallowing.mjs 的那条)
 *   getUser() 失败时 user 也是 null —— 把【问不出来】与【确立地没登录】走同一条
 *   分支,就是让判词说出一个它没有确立的原因。这里分开:
 *     AuthRetryableFetchError → 判断不出,请重试;
 *     其余无 user            → 确立的否定。
 */
async function currentUserId(): Promise<
    { userId: string; error?: undefined } | { userId?: undefined; error: 'indeterminate' | 'signedOut' }
> {
    const supabase = await createClient()
    let user = null
    let authError: unknown = null
    try {
        const res = await supabase.auth.getUser()
        user = res.data.user
        authError = res.error
    } catch (e) {
        authError = e
    }
    if (user) return { userId: user.id }
    if ((authError as { name?: string } | null)?.name === 'AuthRetryableFetchError') {
        return { error: 'indeterminate' }
    }
    return { error: 'signedOut' }
}

/**
 * 换头像的【本人】不等那 60 秒的 max-age —— 写一个会自己过期的时间戳,
 * TopNav 读它挂成 ?v=<ts>。理由与生命周期写在 lib/avatar.ts 的 AVATAR_VERSION_COOKIE。
 * 移除时同样要写:否则浏览器还会拿缓存里那张【已经被删掉】的图。
 */
async function stampAvatarVersion(): Promise<void> {
    const jar = await cookies()
    jar.set(AVATAR_VERSION_COOKIE, String(Date.now()), {
        maxAge: AVATAR_VERSION_COOKIE_MAX_AGE,
        path: '/',
        sameSite: 'lax',
        httpOnly: false,
    })
}

/** 顶栏画在每一页上,所以整个 layout 都要重画,不只是 /me。 */
function revalidateEverywhere(): void {
    revalidatePath('/', 'layout')
}

export async function uploadAvatar(
    _prevState: AvatarState,
    formData: FormData
): Promise<AvatarState> {
    const t = await getTranslations()
    const file = formData.get('avatar')

    // ── ① 大小与类型:在【解码之前】,与 uploadLogo 逐条对应 ──────────────
    if (!(file instanceof File) || file.size === 0) {
        return { error: t('me.errAvatarNoFile') }
    }
    if (file.size > AVATAR_MAX_BYTES) {
        return { error: t('me.errAvatarTooLarge') }
    }
    if (!AVATAR_ALLOWED_MIME.includes(file.type)) {
        return { error: t('me.errAvatarType') }
    }

    const who = await currentUserId()
    if (who.error === 'indeterminate') return { error: t('me.errAvatarAuthUnknown') }
    if (who.error) return { error: t('me.errAvatarSignedOut') }

    const input = Buffer.from(await file.arrayBuffer())

    // ── ② 尺寸:metadata() 只读文件头,不解码像素 ─────────────────────────
    // 【声明的 MIME 在这里【不】被当真】—— 上一步看的是浏览器说了什么,
    // 这一步看的是字节自己说了什么。两者不一致时,以字节为准并拒收。
    let width: number | undefined
    let height: number | undefined
    let format: string | undefined
    try {
        const meta = await sharp(input).metadata()
        width = meta.width
        height = meta.height
        format = meta.format
    } catch {
        return { error: t('me.errAvatarDecode') }
    }
    if (!width || !height || !format) {
        return { error: t('me.errAvatarDecode') }
    }
    if (!['png', 'jpeg', 'jpg', 'webp'].includes(format)) {
        return { error: t('me.errAvatarType') }
    }
    if (width > AVATAR_MAX_INPUT_DIMENSION || height > AVATAR_MAX_INPUT_DIMENSION) {
        return {
            error: t('me.errAvatarTooManyPixels', {
                w: String(width),
                h: String(height),
                max: String(AVATAR_MAX_INPUT_DIMENSION),
            }),
        }
    }

    // ── ③ 解码 + 重编码。**存进桶里的是这一行产出的字节** ────────────────
    // rotate() 不带参数 = 按 EXIF 的 Orientation 摆正,并把那个标记清掉;
    //   少了它,手机竖拍的照片会侧躺 —— 而"侧躺"看起来像我们把图弄坏了。
    // flatten() 把透明底压到白色:圆形按钮底下是磨砂玻璃,一张带透明洞的 PNG
    //   会把玻璃透出来,读起来像一张【坏掉的图】,而不是一个人的脸。
    // fit:'cover' + position:'centre' —— 非方图【裁】不【缩】。留白的方案在
    //   32px 的圆里只会让人脸更小,而这张图存在的理由就是让人认出是谁。
    let output: Buffer
    try {
        output = await sharp(input, { limitInputPixels: AVATAR_LIMIT_INPUT_PIXELS })
            .rotate()
            .resize(AVATAR_EDGE_PX, AVATAR_EDGE_PX, { fit: 'cover', position: 'centre' })
            .flatten({ background: '#ffffff' })
            .webp({ quality: AVATAR_WEBP_QUALITY })
            .toBuffer()
    } catch {
        return { error: t('me.errAvatarDecode') }
    }
    if (output.length === 0) {
        return { error: t('me.errAvatarDecode') }
    }

    // ── ④ 落桶。到这里为止,桶里什么都还没动过 ──────────────────────────
    const supabase = await createClient()
    const { error: upErr } = await supabase.storage
        .from(AVATAR_BUCKET)
        .upload(avatarObjectName(who.userId), output, {
            contentType: 'image/webp',
            cacheControl: String(AVATAR_CACHE_SECONDS),
            upsert: true,
        })
    if (upErr) return { error: t('me.errAvatarUpload', { message: upErr.message }) }

    await stampAvatarVersion()
    revalidateEverywhere()
    return { success: true }
}

/**
 * 移除:**把对象删掉**,不是清一个指针。
 * logo 那一处的软处理(只清 DB 指针、对象留着)在这里没有对应物 ——
 * 这里没有指针,对象【在不在】就是状态本身(Tim 的裁定,UI-1d Q5)。
 * 删掉之后地址 404,`<img>` 的 onError 把首字母换回来 —— 与"从来没传过"
 * 走的是同一条回落路径,所以这条路本刀已经证过了。
 */
export async function removeAvatar(): Promise<AvatarState> {
    const t = await getTranslations()
    const who = await currentUserId()
    if (who.error === 'indeterminate') return { error: t('me.errAvatarAuthUnknown') }
    if (who.error) return { error: t('me.errAvatarSignedOut') }

    const supabase = await createClient()
    const { error } = await supabase.storage
        .from(AVATAR_BUCKET)
        .remove([avatarObjectName(who.userId)])
    if (error) return { error: t('me.errAvatarRemove', { message: error.message }) }

    await stampAvatarVersion()
    revalidateEverywhere()
    return { success: true }
}
