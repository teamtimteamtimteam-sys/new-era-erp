#!/usr/bin/env node
// scripts/build-festival-doodles.mjs
// ════════════════════════════════════════════════════════════════════════════
// UI-1b(2026-09-05)· 把 Tim 的节日画作压成【一个固定的画框】
// ════════════════════════════════════════════════════════════════════════════
//
// ★ 这是一支【手动跑的工具】,不是构建步骤,也不是闸。★
//   它不进 `npm run build`:23 张原图共 30.7MB,住在仓库【外面】
//   (~/Downloads/Festivals)。产物(public/brand/festivals/*.webp)【进仓库】。
//   加一个新节日 = 把一张图丢进源目录、在 festival_doodles 表里加一行、
//   跑一次这支脚本。**一行代码都不用改。**
//
//   用法:node scripts/build-festival-doodles.mjs [--src=<dir>] [--dry]
//   默认 --src=~/Downloads/Festivals
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【为什么要归一化 —— 这一段是本文件存在的全部理由】★★
// ════════════════════════════════════════════════════════════════════════════
//
// 【实测,不是估的】23 张原图的画布有【四种】形状(2172×724 十五张、
//   1672×941 六张、1916×821 一张、2164×727 一张)。而【裁掉透明边之后】墨迹本身
//   的长宽比仍然散在 **2.57(父亲节)到 4.36(万圣节)** 之间。
//
//   于是两种朴素的画法都不成立:
//     · 固定【宽度】→ 高度随节日在 111px 与 187px 之间跳,**问候语与搜索框
//       每逢换节日就整体上下窜 76px**;
//     · 固定【高度】→ 宽度在 283px 与 480px 之间跳,标记相对搜索框忽大忽小。
//
//   所以:**裁到墨迹 → 居中垫进【同一个】3.40:1 的画框 → 编码 WebP。**
//   3.40:1 不是挑的,是 `evoltrya-wordmark.svg` 自己的 viewBox 比例
//   (1204.72 / 354.331 = 3.4001)。**于是平日字标与 23 张节日画共用同一个盒子,
//   页面上没有任何东西会因为今天是什么日子而移动一个像素。**
//
// ★【裁不出边的那一张:Vesak Day —— 而"不透明"这个词第一版用错了,更正在这里】★
//   22 张是抠出来的插画,四角全透明,裁剪一裁一个准。**Vesak Day 不是。**
//
//   ★ 报给 Tim 的那句「它没有透明背景」不精确,而更正让判断更准。★ 实测:
//   它是一张 **整幅横向铺满、上下两头羽化** 的图 —— 左右两条边是【硬的】
//   (照片直接跑出画布),上下两头淡出到透明。逐行平均 alpha:
//   y=300 处 0.94(实),y=0 处 0.19,y=723 处 0.02(两头都在淡出)。
//   所以它与另外 22 张的差别【不是】"有没有背景",是 **裁剪找不到左右边** ——
//   按墨迹裁出来仍是满幅宽,contain 之后两侧留透明条,而那两条【硬的竖边】
//   就悬在页面中间。Tim 那条裁定(圆角,当成一张有意的框图)对这个【更准的
//   事实仍然成立】,而且正是冲着那两条竖边来的。
//   处置:**cover 裁到 3.40:1(填满画框),再把四角圆角【烧进 alpha】。**
//     · 为什么圆角要烧进图而不是写 CSS:CSS 的 border-radius 圆的是 <img>
//       元素的盒子。走 cover 时两者恰好重合,但这支脚本不该依赖那个巧合 ——
//       烧进 alpha 是跟着图自己的边走的,换一张图也仍然对。
//
//   ★【裁剪锚点是 centre,而这是【删掉一个机制】之后的结果,不是省事】★
//   本刀写过一版"按哪边更羽化自动选锚点"的判据,想把顶边那道噪带裁掉。
//   **它在唯一一个走这条分支的资产上给出了错的答案**:底边(0.039)比顶边
//   (0.202)更透明,判据于是去裁底边 —— 而该裁的是顶边。
//   一个在唯一一个输入上就错的启发式不该进仓库;把它调参调到这一张图上正好
//   对,更不该。按 §21.5「一个没有触发条件的机制比没有更糟」的同一条精神,
//   它被【删掉】了。
//
//   ★【那道彩色噪带是【原图里的】,本脚本没有制造它,也不假装修好了它】★
//     已用无损 PNG 参照证过:**不经 WebP 也在**。它在顶边羽化区里,是那张图
//     渲染时留下的虹彩噪声。**这一段存在的理由:免得下一个人以为是这支脚本
//     压坏的,去调 quality 调一下午。** 真正的修法是重导一版,已记进
//     manual-walk-list.md(2027-05 之前,World EV Day 那张是干净的,不挡这一刀)。
//   到那天这支脚本【不用改】:它按"四角有没有墨"自动分流,不按文件名。
//
// ════════════════════════════════════════════════════════════════════════════
// 【命名约定:产物文件名 = holiday_key + .webp,一个字都不多】
//   festival_doodles.holiday_key = 'world-ev-day'
//     → public/brand/festivals/world-ev-day.webp
//   代码里【没有】文件名映射表,只有 `/brand/festivals/${key}.webp` 这一句拼接。
//   源文件名("World EV Day.PNG")到 key 的换算也在这里,规则是机械的:
//   小写 · 去掉撇号 · 非字母数字换成连字符 · 合并连字符。
//   ★ 换算之后必须命中 SQL 里那 23 个 key ★ —— 对不上就当场报出来,不猜。
// ════════════════════════════════════════════════════════════════════════════
import sharp from 'sharp'
import { readdirSync, statSync, mkdirSync, writeFileSync, existsSync } from 'node:fs'
import { join, dirname, basename } from 'node:path'
import { fileURLToPath } from 'node:url'
import { homedir } from 'node:os'

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const OUT_DIR = join(ROOT, 'public/brand/festivals')

// ── 画框 ────────────────────────────────────────────────────────────────────
// 3.40:1 —— evoltrya-wordmark.svg 的 viewBox 比例(1204.72 / 354.331)。
const FRAME_W = 1224
const FRAME_H = 360 // 1224 / 360 = 3.4 精确
// 【为什么是 1224 而不是更小】首页最大渲染宽度是 26rem = 416px(clamp 的上限)。
// 416 × 3(DPR 3 的手机)= 1248,取 1224 差 2%,肉眼不可分辨而省下一档体积。
const WEBP_QUALITY = 82
// --brand-radius 是 6px,而那是【渲染尺寸】上的 6px。源图 1224 宽、最大渲染
// 416 宽,缩放比 2.942 —— 所以源图上要画 6 × 2.942 ≈ 18px 才在屏幕上是 6px。
const CORNER_RADIUS_SRC = 18
// 「四角不透明」的判据:alpha > ALPHA_FLOOR 就算有墨。与巡检时用的同一个阈值。
const ALPHA_FLOOR = 8

function keyOf(filename) {
    return basename(filename)
        .replace(/\.[^.]+$/, '')
        .toLowerCase()
        .replace(/['’]/g, '')
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-|-$/g, '')
}

/** 墨迹包围盒 + 四角是否不透明。一次 raw 解码回答两个问题。 */
async function inkBox(file) {
    const { data, info } = await sharp(file).ensureAlpha().raw().toBuffer({ resolveWithObject: true })
    const { width: W, height: H, channels: C } = info
    let minX = W, minY = H, maxX = -1, maxY = -1
    for (let y = 0; y < H; y++) {
        for (let x = 0; x < W; x++) {
            if (data[(y * W + x) * C + 3] > ALPHA_FLOOR) {
                if (x < minX) minX = x
                if (x > maxX) maxX = x
                if (y < minY) minY = y
                if (y > maxY) maxY = y
            }
        }
    }
    if (maxX < 0) throw new Error(`${file}:整张图全透明,没有墨迹`)
    let corners = 0
    for (const [x, y] of [[0, 0], [W - 1, 0], [0, H - 1], [W - 1, H - 1]]) {
        if (data[(y * W + x) * C + 3] > ALPHA_FLOOR) corners++
    }
    return { W, H, left: minX, top: minY, width: maxX - minX + 1, height: maxY - minY + 1, corners }
}

/** 圆角遮罩:一张 FRAME_W×FRAME_H 的 1 通道图,圆角外是 0。 */
function roundedMask(r) {
    const svg = `<svg width="${FRAME_W}" height="${FRAME_H}"><rect x="0" y="0" width="${FRAME_W}" height="${FRAME_H}" rx="${r}" ry="${r}" fill="#fff"/></svg>`
    return Buffer.from(svg)
}

async function main() {
    const args = process.argv.slice(2)
    const srcArg = args.find((a) => a.startsWith('--src='))
    const dry = args.includes('--dry')
    const SRC = srcArg ? srcArg.slice(6).replace(/^~/, homedir()) : join(homedir(), 'Downloads/Festivals')

    if (!existsSync(SRC)) {
        console.error(`源目录不存在:${SRC}`)
        process.exit(2)
    }
    if (!dry) mkdirSync(OUT_DIR, { recursive: true })

    const files = readdirSync(SRC).filter((f) => /\.(png|jpe?g|webp)$/i.test(f)).sort()
    if (files.length === 0) {
        console.error(`源目录里一张图都没有:${SRC}`)
        process.exit(2)
    }

    let totalIn = 0, totalOut = 0
    const manifest = []
    for (const f of files) {
        const src = join(SRC, f)
        const key = keyOf(f)
        const inBytes = statSync(src).size
        totalIn += inBytes

        const box = await inkBox(src)
        const opaqueBleed = box.corners > 0

        let pipe
        if (opaqueBleed) {
            // ── 边缘裁不出来的:cover 裁到画框比例,再把圆角烧进 alpha ────────
            pipe = sharp(src)
                .resize({ width: FRAME_W, height: FRAME_H, fit: 'cover', position: 'centre' })
                .ensureAlpha()
                .composite([{ input: roundedMask(CORNER_RADIUS_SRC), blend: 'dest-in' }])
        } else {
            // ── 抠图:裁到墨迹 → contain 垫进画框(透明底,居中)──────────────
            pipe = sharp(src)
                .extract({ left: box.left, top: box.top, width: box.width, height: box.height })
                .resize({
                    width: FRAME_W, height: FRAME_H, fit: 'contain', position: 'centre',
                    background: { r: 0, g: 0, b: 0, alpha: 0 },
                })
        }

        const buf = await pipe.webp({ quality: WEBP_QUALITY, alphaQuality: 100 }).toBuffer()
        totalOut += buf.length
        if (!dry) writeFileSync(join(OUT_DIR, `${key}.webp`), buf)

        manifest.push({
            src: f, key, mode: opaqueBleed ? 'cover+round' : 'trim+pad',
            kbIn: Math.round(inBytes / 1024), kbOut: Math.round(buf.length / 1024),
        })
    }

    const pad = (s, n) => String(s).padEnd(n)
    console.log(pad('SOURCE', 30), pad('holiday_key', 26), pad('MODE', 12), pad('KB in', 7), 'KB out')
    for (const m of manifest) console.log(pad(m.src, 30), pad(m.key, 26), pad(m.mode, 12), pad(m.kbIn, 7), m.kbOut)
    console.log(`\n${manifest.length} 张 · ${(totalIn / 1048576).toFixed(2)} MB → ${(totalOut / 1024).toFixed(0)} KB` + (dry ? '  (--dry,没有写文件)' : `  → ${OUT_DIR}`))
    console.log(`画框 ${FRAME_W}×${FRAME_H}(${(FRAME_W / FRAME_H).toFixed(4)}:1)· WebP q${WEBP_QUALITY}`)
}

main().catch((e) => { console.error(e); process.exit(1) })
