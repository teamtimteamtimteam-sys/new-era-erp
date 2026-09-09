// scripts/lib/selfproof.mjs —— 一支量具怎么证明【它自己没瞎】。
//
// ════════════════════════════════════════════════════════════════════════════
// NARROW-COVERAGE-1(2026-09-09)· 「名字对,覆盖窄」的解药,做成一个机制
// ════════════════════════════════════════════════════════════════════════════
// 【为什么是一个模块,不是二十一份注释】本仓库对这件事有明文门槛:
// check-auth-error-swallowing 的抬头写着「**一条被破了 51 次的规矩不再是一条规矩,
// 是一个机制**」。而「每支检查都该证明自己没瞎」此前是一条**靠人记住**的规矩 ——
// 实测 31 支里 23 支一条都没有,3 支两向、1 支单向、4 支只有空总体。
// 那个分布就是「靠人记住」的成绩单,所以这里换成一个机制。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【它证的是【灵敏度】,不是【瞄准】—— 这条区别是本刀的全部要点】★★
// ════════════════════════════════════════════════════════════════════════════
// 下面这三条断言回答的是:**我看的那个东西变了,我发得出声吗?**
// 它们回答不了:**我看的是不是我声称在管的那个东西?**
//
// 已登记的五条「名字对覆盖窄」实例里,**只有一条**是这些断言治得了的:
//   实例 4(check-confirm-subject 数出一处幽灵主语)—— 覆盖失效,治得了。
//   实例 2(STATE_FIELD 词边界漏 retention_state)—— **词汇表太窄**,站点看见了、
//          判错了。覆盖断言全绿。
//   实例 3(按钮分类器报 43、真值 2)—— **判据错**。覆盖断言全绿。
//   实例 5(CONSEQ-1 拿 `body=` 这个 prop 当「说不说后果」,35/22)—— **看的是
//          另一个对象**。覆盖断言全绿。
//   CHECKER-BLIND-SPOTS ④(字体守卫读 coverage.json、文档写 Helvetica)—— 同上,
//          而且更坏:**一次致盲注入会让它照常变红,于是发一张它不够格发的合格证。**
//
// ☞ 所以瞄准那一半【不在这个模块里】,它在每支脚本的抬头上,写成一行字:
//     【瞄准 · AIM】 我读的是 ______ / 我声称管的是 ______
//   两者不是同一个东西时就地说明白。scripts/check-instrument-selfproof.mjs
//   守着「每一支都写了这一行」。一个字都不能自动生成 —— 能自动生成的话,
//   它就抓不住字体守卫那一类了。
//
// ════════════════════════════════════════════════════════════════════════════
// 【退出码:沿用本仓库既有的三档,不新开一档】
//   0 = 干净        1 = 找到了违规        2 = **量具坏了**
// 覆盖断言失败属于第三档:它说的不是"代码有问题",是"这一次读数不作数"。
// 仓库里已经这么用了(check-masked-reads 的「解析出 0 个不是空集合」就是 exit 2),
// 所以这里不发明新语义。
// ════════════════════════════════════════════════════════════════════════════

const BLIND = 2

function die(script, lines) {
    console.error(`✗ ${script}:**覆盖断言失败 —— 这一次读数不作数。**`)
    for (const l of lines) console.error(`    ${l}`)
    console.error(`  ☞ 这【不是】"代码有问题"(那是 exit 1)。这是量具自己说它没量准。`)
    process.exit(BLIND)
}

/**
 * ① 空总体断言 —— 【零必须是一次测量,不是一次缺席】。
 *
 * 扫到 0 个目标时报绿,与"每一处都合规"在屏幕上长得一模一样。
 * 本仓库为这一族付过账不止一次(check_xmodule_views 的 return-count、
 * check-i18n 的零后缀、check-pdf-font-stack 的 scanned===0)。
 *
 * ★【门槛默认是 1,而不是一个"看起来够大"的数】★
 *   AGENTS.md 的「健康检查的阈值默认应当是零」那一条(ALERT-1 第五次学到的):
 *   **要设一个非零门槛,先得说出"为什么这个数量的坏是可以接受的"** ——
 *   说不出来,那个门槛就是为了让检查过关而设的。
 *   这里的对偶是:**要设一个大于 1 的下界,先得说出那个数是从哪来的。**
 *   说不出来就用 1 —— 「零必须是一次测量」这条法则只要求区分【0】与【非 0】,
 *   而一个凭感觉写下的 500 会在树缩小的那天变成一次误报,
 *   而误报的闸最后一定被绕过。
 *
 * @param {string} script  脚本名,进错误消息
 * @param {string} what    这个总体是什么(人话)
 * @param {number} n       实测到的个数
 * @param {number} [min=1] 下界。**大于 1 时必须在调用处写明它是怎么来的。**
 */
export function assertPopulation(script, what, n, min = 1) {
    if (Number.isInteger(n) && n >= min) return n
    die(script, [
        `${what}:实测 ${n} 个,而 ${min} 是下界。`,
        `0 个【不是】"没有问题",是**没有测量** —— 判据多半失效了。`,
    ])
}

/**
 * ② 双向钉住 —— 【两个方向都要拦】。
 *
 * 一个只拦得住"少"的断言,拦不住"多"。check-confirm-subject:253 的
 * `subjects.length < openings` 正是这个形状:它拦得住解析器漏抓,
 * 拦不住它凭空多抓 —— 而线上今天它就多抓了一处(实例 4)。
 *
 * 用法是拿【两条互相独立的路】数同一个总体:一条走判据,一条走一个
 * 不经过判据的粗计数。两个数不等就红,**不管是哪个方向**。
 *
 * @param {string} script
 * @param {string} what
 * @param {number} got     判据数出来的
 * @param {number} want    独立的粗计数
 * @param {string} [hint]  差额意味着什么
 */
export function assertPinned(script, what, got, want, hint = '') {
    if (got === want) return got
    die(script, [
        `${what}:判据数出 ${got},独立计数是 ${want} —— 差 ${got - want}。`,
        got < want
            ? `**判据漏抓了。** 一支会漏抓而不吭声的量具比没有量具更坏,因为它还发一张"干净"的证明。`
            : `**判据凭空多抓了。** 多出来的那些不是真的目标,而它们会被当成真的算进数里。`,
        ...(hint ? [hint] : []),
    ])
}

/**
 * ③ 名单必须是活的 —— 【一条命不中任何东西的豁免,与一支瞎掉的量具分不开】。
 *
 * 这一条是把 check-base-isolation:160 那个已经上线的做法推广开来:
 * 它拿 `known !== KNOWN_CONVERSIONS.size` 守着自己,于是【顺带】守住了
 * "扫描器还看得见东西"这件事 —— walk() 返回空数组时 known 掉到 0,当场 EXIT 1。
 *
 * 反过来说:一份豁免名单本身就是一组【已知必然命中】的探针。
 * 它们不再命中,只有两种可能:名单过期了,或者量具瞎了。**两种都要红。**
 *
 * @param {string} script
 * @param {string} what
 * @param {Array} entries      名单
 * @param {(e:any)=>boolean} hit  这一条今天还命中吗
 * @param {(e:any)=>string} label 怎么把一条打印出来
 */
export function assertAllowlistLive(script, what, entries, hit, label = (e) => JSON.stringify(e)) {
    const dead = entries.filter((e) => !hit(e))
    if (dead.length === 0) return entries.length
    die(script, [
        `${what}:名单 ${entries.length} 条,其中 ${dead.length} 条今天【一处都命不中】:`,
        ...dead.map((e) => `  · ${label(e)}`),
        `**只有两种可能,而它们在输出上分不开:**`,
        `  ① 名单过期了 —— 那一处代码已经改好或没了,请把这一条删掉;`,
        `  ② 扫描器瞎了 —— 判据失效,于是它连【已知会命中】的探针都抓不到。`,
        `☞ 不要为了让门变绿就删条目。先确认是哪一种。`,
    ])
}

/**
 * ④ 断言真的跑了 —— 给【单元测试形状】的脚本用。
 *
 * check-pmap / check-org-tree / check-near-duplicate 是一串手写断言。
 * 它们的失效方式不是"漏抓",是**根本没跑到**:一个 early return、
 * 一个被注释掉的块、一个 `if (false)`,`failures` 仍然是 0,于是印一个绿勾。
 * 所以数一遍【真的求值过的断言条数】,并把那个数钉死。
 *
 * @param {string} script
 * @param {number} ran   实际跑过的断言条数
 * @param {number} want  应当跑多少条(改断言就改这个数,这是刻意的摩擦)
 */
export function assertAssertionsRan(script, ran, want) {
    if (ran === want) return ran
    die(script, [
        `断言条数:真的求值过 ${ran} 条,而本文件声明应当有 ${want} 条。`,
        ran < want
            ? `**有断言没跑到** —— early return / 被注释掉的块 / if (false) 都是这个形状,而 failures 仍然是 0。`
            : `**多跑了** —— 加了断言就把声明的数一起改掉,这个摩擦是刻意的。`,
    ])
}
