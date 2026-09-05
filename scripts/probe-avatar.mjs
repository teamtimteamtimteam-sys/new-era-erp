#!/usr/bin/env node
// scripts/probe-avatar.mjs
// ════════════════════════════════════════════════════════════════════════════
// UI-1d 的交互探针 —— 它证【三件在服务端看不见的事】
// ════════════════════════════════════════════════════════════════════════════
//
//   P1 · 渲染期回落:对象【不在】时,顶栏与 /me 画的是今天那一组首字母,
//        而不是破图、也不是空圆。★ 这一条委托书点名要单独证 ★ ——
//        上传期的回落(拒收一个坏文件)与渲染期的回落(对象 404 了)
//        是两件事,而后者才是"每一页、每一个人"都会碰到的那一件。
//   P2 · 走产品自己的门上传一张【非方形 + 带透明】的 PNG,回来的必须是
//        256×256 的 WebP,而且屏幕上真的画出来了。
//   P3 · 移除之后地址 404,而屏幕【回到首字母】—— 于是"删掉"与"没传过"
//        在屏幕上是同一件事,那正是回落该有的性质。
//   P4 · 一个伪装成 .png 的文本文件必须被【解码失败】挡住,人看到一句话,
//        而桶里【不多一个对象】。
//
// ★【为什么跑在 `next start` 上,不跑在 `next dev` 上】★ UI-1c 实测过:
//   这棵树在 next dev 下 hydration 不收尾,交互探针于是量不到任何点击的结果。
//   那次用一张【没被碰过的页面】做对照,确认是探针环境而不是回归。
//
// ★【账号是一次性的,而"用完即删"这句承诺由退出码兑现】★ 与 survey-phone
//   同一套(PRE-ACCOUNT-1:四个一次性 admin 活了 17.5 小时,因为清理静默失败)。
//   这里还多一样要清:它上传的那个头像对象。清不掉 → 退非零。
//
// 用法:node scripts/probe-avatar.mjs        (需要一份【生产构建】在 .next 里)
import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { spawn, execSync } from 'node:child_process'
import { createConnection } from 'node:net'
import sharp from 'sharp'
import { acquireOrExit, release } from './liveLock.mjs'

const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3201                 // 3198 是 survey-phone 的,3199 是冒烟的
const CDP_PORT = 9337
const CHROME = join(process.env.HOME, '.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.54/chrome-headless-shell-mac-arm64/chrome-headless-shell')

const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const rest = (p, o = {}) => fetch(URL_ + p, { ...o, headers: {
    apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(o.headers || {}) } })

const results = []
const fail = []
function probe(id, ok, detail) {
    results.push({ id, ok, detail })
    if (!ok) fail.push(`${id}: ${detail}`)
    console.log(`${ok ? '✓' : '✗'} ${id.padEnd(28)} ${detail}`)
}

let server = null, chrome = null, accountId = null, avatarPath = null
const cleanupFailures = []
// ★ 存储的 DELETE 不能带 application/json 的 content-type 而又不带 body ——
//   storage-api 会回 400 「Body cannot be empty when content-type is set to
//   'application/json'」。实测踩过一次,而那次的红【看起来像】"对象删不掉"。
const restNoJson = (p, o = {}) => fetch(URL_ + p, { ...o, headers: {
    apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, ...(o.headers || {}) } })
async function restCleanup(p, o, what, noJson = false) {
    try {
        const r = await (noJson ? restNoJson : rest)(p, o)
        if (!r.ok) cleanupFailures.push(`${what} → HTTP ${r.status} ${(await r.text()).slice(0, 160)}`)
    } catch (e) { cleanupFailures.push(`${what} → ${e.message}`) }
}

async function waitPort(port, ms) {
    const t0 = Date.now()
    for (;;) {
        const up = await new Promise((res) => {
            const s = createConnection({ port, host: '127.0.0.1' })
            s.on('connect', () => { s.destroy(); res(true) })
            s.on('error', () => res(false))
        })
        if (up) return true
        if (Date.now() - t0 > ms) return false
        await sleep(300)
    }
}

async function main() {
    acquireOrExit('scripts/probe-avatar.mjs')
    if (!existsSync(join(ROOT, '.next/BUILD_ID')))
        throw new Error('.next/BUILD_ID 不在 —— 这一支要跑在【生产构建】上。先 npm run build。')
    if (!existsSync(CHROME)) throw new Error('chrome-headless-shell not at ' + CHROME)

    try { execSync(`lsof -ti tcp:${PORT} | xargs -r kill -9`, { stdio: 'ignore' }) } catch {}

    // ── 一次性 admin ────────────────────────────────────────────────────────
    const email = `avatarprobe-${Date.now()}@test.local`
    const cu = await (await rest('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email, password: 'avatar-probe-1', email_confirm: true }) })).json()
    accountId = cu.id
    if (!accountId) throw new Error('账号建不出来: ' + JSON.stringify(cu).slice(0, 300))
    avatarPath = `${accountId}.webp`
    const roles = await (await rest('/rest/v1/roles?select=id&code=eq.admin')).json()
    await rest('/rest/v1/user_roles', { method: 'POST', body: JSON.stringify({ user_id: accountId, role_id: roles[0].id }) })
    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', { method: 'POST',
        headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 'avatar-probe-1' }) })).json()
    if (!sess?.access_token) throw new Error('登录失败: ' + JSON.stringify(sess).slice(0, 200))
    const cookieName = 'sb-' + URL_.split('//')[1].split('.')[0] + '-auth-token'
    const cookieValue = 'base64-' + Buffer.from(JSON.stringify(sess)).toString('base64url')
    // 这个账号【没有员工档案】—— 于是它同时也是"没建档的人也换得了头像"那一条的证人。
    console.log(`· 一次性 admin ${accountId}(没有员工档案)`)

    const publicUrl = `${URL_}/storage/v1/object/public/avatars/${avatarPath}`

    // ── next start ──────────────────────────────────────────────────────────
    server = spawn('npx', ['next', 'start', '-p', String(PORT)], { cwd: ROOT, detached: true, stdio: ['ignore', 'pipe', 'pipe'] })
    server.stderr.on('data', () => {})
    if (!await waitPort(PORT, 60000)) throw new Error(`next start 没在 :${PORT} 起来`)
    console.log(`· next start :${PORT}`)

    chrome = spawn(CHROME, [`--remote-debugging-port=${CDP_PORT}`, '--headless', '--disable-gpu',
        '--no-sandbox', '--hide-scrollbars', 'about:blank'], { detached: true, stdio: ['ignore', 'pipe', 'pipe'] })
    if (!await waitPort(CDP_PORT, 30000)) throw new Error('chrome CDP 没起来')

    const { webSocketDebuggerUrl } = await (await fetch(`http://127.0.0.1:${CDP_PORT}/json/version`)).json()
    // 极简 CDP 客户端 —— Node 自带 WebSocket,不引第三方依赖
    const sock = new WebSocket(webSocketDebuggerUrl)
    await new Promise((res, rej) => { sock.onopen = res; sock.onerror = rej })
    let msgId = 0
    const pending = new Map()
    const events = []
    sock.onmessage = (m) => {
        const d = JSON.parse(m.data)
        if (d.id && pending.has(d.id)) { const { res, rej } = pending.get(d.id); pending.delete(d.id)
            d.error ? rej(new Error(JSON.stringify(d.error))) : res(d.result) }
        else if (d.method) events.push(d)
    }
    const send = (method, params = {}, sessionId) => new Promise((res, rej) => {
        const id = ++msgId; pending.set(id, { res, rej })
        sock.send(JSON.stringify({ id, method, params, sessionId }))
    })

    const { targetId } = await send('Target.createTarget', { url: 'about:blank' })
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true })
    const S = (m, p) => send(m, p, sessionId)
    await S('Page.enable'); await S('Runtime.enable'); await S('DOM.enable'); await S('Network.enable')
    await S('Emulation.setDeviceMetricsOverride', { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false })
    await S('Network.setCookies', { cookies: [{ name: cookieName, value: cookieValue,
        domain: 'localhost', path: '/', httpOnly: false, secure: false }] })

    const evalJs = async (expr) => {
        const r = await S('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })
        if (r.exceptionDetails) throw new Error(expr.slice(0, 80) + ' → ' + JSON.stringify(r.exceptionDetails).slice(0, 300))
        return r.result.value
    }
    const goto = async (path) => {
        await S('Page.navigate', { url: `http://localhost:${PORT}${path}` })
        await sleep(2500)
        // 等 hydration:React 挂上之后 body 上会有交互监听;用一个稳的判据 ——
        // 等到 AvatarPanel 的按钮真的可点(onClick 已绑定)。
        for (let i = 0; i < 40; i++) {
            const ready = await evalJs(`!!document.querySelector('[data-panel="avatar"] button')`)
            if (ready) break
            await sleep(300)
        }
    }
    // ★【问"对象还在不在"必须绕开 CDN】★ 实测踩过:移除之后拿【裸地址】去问,
    //   拿回来的是 200 —— 那不是对象还在,是 CDN 里那份 max-age=60 的副本还在。
    //   (而屏幕上是对的:移除会换一个新的 ?v=,那是另一个缓存键,直接落到源站。)
    //   所以问源站要挂一个每次都不同的参数;这一格问的是【源站】,
    //   而"别人最长看见 60 秒旧图"是本刀刻意收下的那条,由 P2.cache-bounded 管。
    let cb = 0
    const httpStatus = async (u) => { try {
        const r = await fetch(u + (u.includes('?') ? '&' : '?') + 'cb=' + (++cb), { redirect: 'manual', cache: 'no-store' })
        return r.status } catch { return -1 } }

    // ════════════════════════════════════════════════════════════════════════
    // P1 · 渲染期回落:对象不在 → 首字母,不是破图、不是空圆
    // ════════════════════════════════════════════════════════════════════════
    probe('P0.object-absent', await httpStatus(publicUrl) >= 400, `上传前 ${publicUrl.slice(-46)} → HTTP ${await httpStatus(publicUrl)}`)
    await goto('/me')
    const s1 = await evalJs(`(() => {
        const btn = document.querySelector('[data-nav="avatar-menu"] button')
        const img = document.querySelector('[data-nav="avatar-image"]')
        const circle = btn && btn.querySelector('span')
        return { initials: circle ? circle.textContent.trim() : null,
                 imgInDom: !!img,
                 panel: !!document.querySelector('[data-panel="avatar"]'),
                 status: document.querySelector('[data-nav="avatar-menu"] button') ? 'ok' : 'no-topbar' }
    })()`)
    probe('P1.fallback-initials', s1.initials === 'A' && !s1.imgInDom,
        `顶栏画的是首字母 "${s1.initials}"(邮箱首字母),404 的 <img> 已被 onError 摘掉(imgInDom=${s1.imgInDom})`)
    probe('P1.panel-without-employee', s1.panel === true,
        `没有员工档案的账号在 /me 上【看得见】换头像那一段(panel=${s1.panel})`)

    // ════════════════════════════════════════════════════════════════════════
    // P4 · 坏文件先做(它必须【不】在桶里留下任何东西)
    // ════════════════════════════════════════════════════════════════════════
    const { root } = await S('DOM.getDocument')
    const badNode = await S('DOM.querySelector', { nodeId: root.nodeId, selector: '#avatar-file' })
    const { writeFileSync } = await import('node:fs')
    const badFile = '/tmp/ui1d-not-an-image.png'
    writeFileSync(badFile, 'this is plain text wearing a .png extension, nothing more\n')
    await S('DOM.setFileInputFiles', { nodeId: badNode.nodeId, files: [badFile] })
    await evalJs(`document.querySelector('[data-panel="avatar"] form button[type=submit]').click()`)
    await sleep(4000)
    const bad = await evalJs(`(() => {
        const e = document.querySelector('[data-avatar-error]')
        return { msg: e ? e.textContent.trim().slice(0,70) : null }
    })()`)
    const afterBad = await httpStatus(publicUrl)
    probe('P4.decode-error-shown', !!bad.msg, `人看到的话:「${bad.msg ?? '(没有错误框)'}…」`)
    probe('P4.nothing-stored', afterBad >= 400, `桶里仍然没有对象 → HTTP ${afterBad}(绝不留 0 字节对象)`)

    // ════════════════════════════════════════════════════════════════════════
    // P2 · 走产品的门传一张【非方 + 带透明】的 PNG
    // ════════════════════════════════════════════════════════════════════════
    const srcFile = '/tmp/ui1d-source.png'
    writeFileSync(srcFile, await sharp({ create: { width: 900, height: 300, channels: 4,
        background: { r: 20, g: 120, b: 200, alpha: 0.35 } } }).png().toBuffer())
    await goto('/me')
    const { root: root2 } = await S('DOM.getDocument')
    const okNode = await S('DOM.querySelector', { nodeId: root2.nodeId, selector: '#avatar-file' })
    await S('DOM.setFileInputFiles', { nodeId: okNode.nodeId, files: [srcFile] })
    await evalJs(`document.querySelector('[data-panel="avatar"] form button[type=submit]').click()`)
    await sleep(6000)

    const headers = await (async () => { const r = await fetch(publicUrl); return {
        status: r.status, ct: r.headers.get('content-type'), cc: r.headers.get('cache-control'),
        bytes: (await r.arrayBuffer()).byteLength } })()
    probe('P2.stored-200', headers.status === 200, `公开地址 → HTTP ${headers.status}`)
    probe('P2.content-type', headers.ct === 'image/webp', `content-type=${headers.ct}`)
    probe('P2.cache-bounded', /max-age=60\b/.test(headers.cc || ''), `cache-control=${headers.cc}(有界,不是默认的 3600)`)

    const meta = await sharp(Buffer.from(await (await fetch(publicUrl)).arrayBuffer())).metadata()
    probe('P2.square-256', meta.width === 256 && meta.height === 256 && meta.format === 'webp',
        `服务端产出 ${meta.width}×${meta.height} ${meta.format},${headers.bytes} 字节(源图 900×300 带 alpha)`)
    probe('P2.alpha-flattened', meta.hasAlpha === false, `透明底已压白(hasAlpha=${meta.hasAlpha})`)

    // ★★【原地重画,**不跳转**】★★ 这一格是本刀实测到的那个缺陷的守卫:
    //   AvatarImage 早先用一个光秃秃的布尔记"失败过吗",于是一个没有头像的人
    //   打开页面(图 404 → 摘掉 <img>)之后上传成功,组件【没有卸载】,
    //   那个布尔还是 true —— 上传成功而屏幕上还是首字母。
    //   **整页跳转会把它藏起来**(重新挂载就清干净了),所以这一格【不跳转】。
    const s2 = await evalJs(`(() => {
        const img = document.querySelector('[data-nav="avatar-image"]')
        return { inDom: !!img, complete: img ? img.complete : null, nw: img ? img.naturalWidth : null,
                 v: img ? /[?&]v=/.test(img.src) : null }
    })()`)
    probe('P2.rendered-in-place', s2.inDom && s2.complete && s2.nw === 256,
        `**没有跳转**,上传后原地就画出来了(naturalWidth=${s2.nw})`)
    probe('P2.cache-buster', s2.v === true, `本人这一次的地址带 ?v=(其他人靠 60 秒 max-age 收敛)`)

    // ════════════════════════════════════════════════════════════════════════
    // P3 · 移除 → 404 → 屏幕回到首字母
    // ════════════════════════════════════════════════════════════════════════
    await evalJs(`[...document.querySelectorAll('[data-panel="avatar"] form button')].find(b => b.type !== 'submit').click()`)
    await sleep(5000)
    // 同样【不跳转】先量一次:移除之后原地就该回到首字母。
    const s3a = await evalJs(`(() => {
        const btn = document.querySelector('[data-nav="avatar-menu"] button')
        const img = document.querySelector('[data-nav="avatar-image"]')
        return { initials: btn ? btn.querySelector('span').textContent.trim() : null,
                 imgBroken: img ? (img.complete && img.naturalWidth === 0) : false,
                 imgInDom: !!img }
    })()`)
    probe('P3.in-place-fallback', s3a.initials === 'A' && !s3a.imgBroken,
        `**没有跳转**,移除后原地回到首字母 "${s3a.initials}"(没有留下一张画不出来的图)`)
    const afterRemove = await httpStatus(publicUrl)
    probe('P3.object-gone', afterRemove >= 400, `移除后 → HTTP ${afterRemove}(删的是对象,不是一个指针)`)
    await goto('/me')
    const s3 = await evalJs(`(() => {
        const btn = document.querySelector('[data-nav="avatar-menu"] button')
        return { initials: btn ? btn.querySelector('span').textContent.trim() : null,
                 imgInDom: !!document.querySelector('[data-nav="avatar-image"]') }
    })()`)
    probe('P3.back-to-initials', s3.initials === 'A' && !s3.imgInDom,
        `屏幕回到首字母 "${s3.initials}" —— 与"从来没传过"是同一条回落路径`)
}

main().catch((e) => { fail.push('probe crashed: ' + e.message); console.error('\n✗ ' + e.message) })
    .finally(async () => {
        // ── 清理。**承诺没兑现要让退出码说出来**(PRE-ACCOUNT-1)──────────
        if (avatarPath) {
            // 404/NoSuchKey 是【期望的常态】—— 产品自己的移除按钮已经删掉了它。
            const del = await restNoJson(`/storage/v1/object/avatars/${avatarPath}`, { method: 'DELETE' })
            const delBody = await del.text()
            if (!del.ok && !/NoSuchKey|not_found/.test(delBody))
                cleanupFailures.push(`delete avatar object ${avatarPath} → HTTP ${del.status} ${delBody.slice(0, 160)}`)
            // 判据问【源站】,不问 CDN(见 httpStatus 的抬头)
            const still = await fetch(`${URL_}/storage/v1/object/public/avatars/${avatarPath}?cb=final`, { cache: 'no-store' })
            if (still.status < 400) cleanupFailures.push(`avatar object ${avatarPath} 还在(源站 HTTP ${still.status})`)
        }
        if (accountId) {
            await restCleanup(`/rest/v1/user_roles?user_id=eq.${accountId}`, { method: 'DELETE' }, `revoke grant ${accountId}`)
            await restCleanup(`/auth/v1/admin/users/${accountId}`, { method: 'DELETE' }, `delete account ${accountId}`)
            const chk = await rest(`/rest/v1/user_roles?select=user_id&user_id=eq.${accountId}`)
            const left = await chk.json()
            if (Array.isArray(left) && left.length) cleanupFailures.push(`DANGLING ADMIN GRANT for ${accountId}`)
        }
        try { if (server) process.kill(-server.pid, 'SIGKILL') } catch {}
        try { if (chrome) process.kill(-chrome.pid, 'SIGKILL') } catch {}
        try { release('scripts/probe-avatar.mjs') } catch {}
        if (cleanupFailures.length) {
            console.error('\n✗ 清理没做干净:')
            for (const c of cleanupFailures) console.error('   ' + c)
        }
        const bad = fail.length + cleanupFailures.length
        console.log(`\n${bad ? '✗' : '✓'} probe-avatar:${results.length} 格,${fail.length} 红,清理失败 ${cleanupFailures.length}`)
        process.exit(bad ? 1 : 0)
    })
