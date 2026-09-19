// app/components/related/related-records.tsx
// ════════════════════════════════════════════════════════════════════════════
// SEARCH-5 · 关联记录那一页 —— **一个组件,两种形状**
// ════════════════════════════════════════════════════════════════════════════
//
// 【它是什么】搜索面板上那一行「产出批 10」点开之后落的地方。
//   Tim 的裁定(SEARCH-4 Q7)说的是【分组行答得出「这个供应商现在什么情况」】;
//   这一页答的是**下一个问题**:「那十条到底是哪十条」。
//
// ★★【两种形状,而第二种是 Tim 的 W1 折进来的】★★
//   · **有主语**  `/related/<subjectKey>/<subjectId>/<targetKey>`
//                「NMC Cathode Foil 的产出批」—— 关联分组点开的那一页。
//   · **无主语**  `/documents/<typeKey>`
//                「化验单」—— 那 5 种 `link_mode='type_list'` 单据的落点。
//
//   ⚠【为什么是两条地址,而不是一条带哨兵值的】Next 的路由不允许同一层上
//     出现两个【不同名字】的动态段(`[subject]` 与 `[target]` 做兄弟就是一个
//     构建期错误),而往三段地址里塞一个 `none` 哨兵,会让一段【读起来像 id
//     的东西】其实不是 id。**两种形状是两件事,让地址照直说。**
//   ☞ 而它们共用的是【这个组件】,不是一条地址 —— 共用的那一半在这里,
//     分开的那一半在两个 page.tsx 里,各自只做一件事:把参数解析出来。
//
// ════════════════════════════════════════════════════════════════════════════
// ★ 权限:三层,而【第三层不写】——(SEARCH-5 停止闸 §4.4)
// ════════════════════════════════════════════════════════════════════════════
//   ① **目标种类的模块闸** —— `document_types.view_permission`(ANY 语义),
//      交给 `allows()`,**全站唯一的权限谓词求值器**。不持任何一个码 ⇒ 整页拒绝。
//      ☞ 少了这一层,一个没有 finance 的人会在客户的关联页上读到
//        「这个客户没有关联的发票」—— 那是一句**关于数据的断言**,而事实是
//        关于权限的。moduleGuard 存在的理由,换一个地方原样再发一次。
//      ★ 这一层【复用既有文案】(`common.moduleDenied`),一个新键都不加。
//   ② **主语看得见吗** —— 用会话身份读 `subjectTable WHERE id = $1`。
//      读不到 ⇒ 整页拒绝,**不是空列表**。理由:标题里印着主语的标签,
//      「NMC Cathode Foil 的产出批」这句话本身就是一次披露 ——
//      所以这一层不是防御性的,**它是这个地址能不能存在的前提**。
//   ③ **目标行看得见哪些** —— ★ **不写**。`search_related_rows()` 是 INVOKER,
//      RLS 天生回答「你看得见几条」。在这里再判一遍就是把同一条规则写第二遍,
//      而本仓库为那个形状付过四次账。
//      ⚠ 而 ① 与 ③ 不是重复:① 答的是「这一类你能不能看」(整页),
//        ③ 答的是「这一类里的哪几行」(逐行)。两个问题,两个答案。
//
// ════════════════════════════════════════════════════════════════════════════
// ★ 四种零,四句话 ——(停止闸 §4.6)**不许把一次缺席画成一个答案**
// ════════════════════════════════════════════════════════════════════════════
//   主语读不到            → 整页拒绝(见 ②)
//   target_key 不在册      → ★ **响亮报错**:`search_related_rows()` 自己 RAISE,
//                            经 mustRows 抛出去。一个拼错的 key 与一张真的没有
//                            关联的单据,在屏幕上必须分得开。
//   有主语、结构上没有边   → 「这两种单据之间没有关联。」
//   有主语、有边、今天 0 行 → 「这张单据现在没有关联的产出批。」**现在时,肯定句**
//                            (SEARCH-3 为同一条理由删掉过 `recordsNotBuiltYet`)
//   无主语、今天 0 行       → 「没有化验单。」
//
// ★★【页面【不回显】它被点的那个数】★★ 下拉里写着 10,这一页画它**此刻**
//   数出来的行,而那个数由**同一支函数**给出。理由是本仓库自己的(INPUT-2b):
//   **一个面板上的计数是一张快照,一张快照不是一道闸。** 让这一页去核对下拉里
//   那个数,只会造出一个「面板说 10、页面说 9」的假矛盾,而两个都是真的。
//
// ════════════════════════════════════════════════════════════════════════════
// ★ 分页:开着,而今天一次都不会触发 —— **两个数都报**
// ════════════════════════════════════════════════════════════════════════════
//   实测(2026-09-19 线上现读,postgres 身份 ⇒ 上界):
//     一个分组自己最大 **11**(supplier → inbound_batch)· >20 行的分组 **0 个**
//     而**结构上无界的有向表对 140 / 178** —— 79%。
//   ☞ 所以分页不是可选项,只是它今天一次都不会触发。
//     不拿 140/178 吓人,也不拿 11 当上界。
//   ★ keyset(`code < after`)不是 OFFSET:取行那一段是 UNION ALL + DISTINCT,
//     `OFFSET 480` 会把前 480 行算出来再扔掉。**理由是形状,不是一个读数**——
//     这一刀没有量任何毫秒数,也不打算量(第五次拒绝)。
//   ★ 排序键是 `code` 不是 `created_at`(AGING-1:`now()` 记的是事务不是行)。
//
//   ⚠【为什么屏幕上写「显示 n 条,共 T 条」,而不是委托书 Q13 建议的「第 m–n 条」】
//     一份 keyset 的页**知道**自己画了几条、也知道一共有几条(`count(*) OVER ()`
//     在翻页之前求出),**但它不知道自己的偏移量**。要印出 m,只能从 URL 里
//     那个 `after` 反推,或者另外存一个 `from=41` —— 而一个手改过的 `from`
//     会让这一页印出一个它**没法核对**的数。
//     ☞ 这与本仓库那条「不许静默截断」是同一条的另一半:**说得出的才说。**
//
// ════════════════════════════════════════════════════════════════════════════
// ★ 一行画什么:单据号 + 标签,**两列,句号**
// ════════════════════════════════════════════════════════════════════════════
//   实测 40 个种类里 **31 个有 label_column,9 个没有**。对那 9 个只画单据号,
//   **不拿别的东西顶上** —— `records.ts` 的 `toHit` 已经是这条规矩。
//   ⚠ 不按单据种类各写一份列定义:那就是 39 份清单,正是 Tim 否掉小改法的理由。
//
// ★★【单据号什么时候是链接,什么时候不是 —— 这是一次刻意的取舍】★★
//   `type_list` 的那 5 种**没有逐张单据的落点**(那正是它们是 type_list 的原因)。
//   给它们画一个链回本页的链接,就是一条指向自己的链接。**所以它们是文字,不是链接。**
//   ☞ 其余三种 link_mode 照 `documentHref()` 走 —— 与搜索面板**同一支函数**,
//     不是同一段逻辑的第二份。
//
// ★★【任务画成表,而它的自己那一页是一块看板】★★(Tim 的 W3)
//   裁定的理由是:这一页答的是「这个人手上有哪几件事」,不是「哪一件在哪一列」,
//   而一个只读的、按主语筛过的子集里没有"列与列之间的移动"这件事。
//   ⚠ **代价要写下来:任务是唯一一种「共享页的画法与它自己那一页不是同一种画法」
//     的单据。** 一个从 /tools/tasks 走过来的人会看见同一批任务的另一种样子。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows, mustOne } from '@/lib/db-helpers'
import { getMyPermissions } from '@/lib/permissions'
import { allows } from '@/lib/modules'
import { documentHref, type DocumentLinkMode } from '@/lib/search/documentHref'
import { ListPage } from '@/app/components/ui/list-page'
import RelatedTable, { type RelatedRow } from './RelatedTable'

/** 房子的分页常量。★ 树里 17 处 `PAGE_SIZE` 全是 20 —— 照抄,不新造一个数。 */
export const PAGE_SIZE = 20

type DocType = {
    key: string
    table_name: string
    route: string
    link_mode: string
    label_column: string | null
    view_permission: string[]
}

type RowsRow = { id: string; code: string; label: string | null; total: number }

async function docType(
    supabase: Awaited<ReturnType<typeof createClient>>, key: string,
): Promise<DocType | null> {
    return mustOne(
        await supabase.from('document_types')
            .select('key, table_name, route, link_mode, label_column, view_permission')
            .eq('key', key).maybeSingle() as { data: DocType | null; error: { message: string; code?: string } | null },
        'document_types')
}

/**
 * 主语那一行 —— **用会话身份读,所以 RLS 就是判据**(权限层 ②)。
 *
 * ★★【为什么这里有一个 cast,以及它【关掉的不是】一条会抓住错误的检查】★★
 *   表名与列名来自 `document_types`,**在运行时才知道** —— 生成的
 *   `Database` 类型按构造管不到一个运行时的表名。这不是"为了让类型过关"
 *   (AGENTS.md 点名的那一种 cast),它是类型系统本来就够不到的一格。
 *   ☞ 而真正盯着这一格的东西**存在,而且有三个**:
 *     · `check-search-registry.mjs` —— 每一条 route / link_mode 都落在真页面上;
 *     · `db/fixtures/101` —— 每个 view_permission 码都真的在该表策略的谓词里;
 *     · `db/fixtures/199` F 臂 —— 每个种类的 `code` 与 `label_column`
 *       对 authenticated **真的读得到**(6 张单据表只有列级授权)。
 */
type LooseFrom = {
    from: (table: string) => {
        select: (cols: string) => {
            eq: (col: string, val: string) => {
                maybeSingle: () => Promise<{
                    data: Record<string, unknown> | null
                    error: { message: string; code?: string } | null
                }>
            }
        }
    }
}

async function subjectRow(
    supabase: Awaited<ReturnType<typeof createClient>>, type: DocType, id: string,
): Promise<{ code: string; label: string | null } | null> {
    const cols = type.label_column ? `code, ${type.label_column}` : 'code'
    const res = await (supabase as unknown as LooseFrom)
        .from(type.table_name).select(cols).eq('id', id).maybeSingle()
    // ★ 失败即抛。一次失败若被读成"主语看不见",屏幕上会画一块整页拒绝 ——
    //   而那是一句【关于权限的断言】,不是一句关于查询的断言。两者必须分开。
    const row = mustOne(res, `subject ${type.table_name}`)
    if (!row) return null
    return {
        code: String(row.code ?? ''),
        label: type.label_column && row[type.label_column] != null
            ? String(row[type.label_column]) : null,
    }
}

export default async function RelatedRecords({
    subjectKey, subjectId, targetKey, after,
}: {
    /** 有主语时两个都给;无主语时两个都不给。**半个主语由函数按名拒绝。** */
    subjectKey?: string
    subjectId?: string
    targetKey: string
    /** keyset 游标:上一页最后一个单据号。 */
    after?: string
}) {
    const t = await getTranslations()
    const supabase = await createClient()

    const target = await docType(supabase, targetKey)
    // ★ 不在册的 key:**响亮**。一个空列表读起来是「这张单据没有关联记录」,
    //   而那是一句关于数据的断言。与 search_related() 的 RAISE 同一条理由。
    if (!target) {
        throw new Error(
            `SEARCH_UNKNOWN_DOCUMENT_TYPE|${targetKey} —— 它不在 document_types 里,`
            + '而一次拼错的 key 与一张真的没有关联的单据在屏幕上分不开')
    }
    const targetName = t(`search.docType.${target.key}`)

    // ── 权限 ① 目标种类的模块闸 ────────────────────────────────────────────
    //    ANY 语义,交给全站唯一的求值器。不自己拿权限码去比对一份清单。
    const perms = await getMyPermissions()
    if (!allows({ all: [], any: target.view_permission }, perms)) {
        return (
            <ListPage
                title={targetName}
                state={{
                    kind: 'restricted',
                    title: targetName,
                    statement: t('common.moduleDenied'),
                    hint: t('common.moduleDeniedHint'),
                    backHomeLabel: t('common.backHome'),
                }}
            />
        )
    }

    // ── 权限 ② 主语看得见吗(有主语时)────────────────────────────────────
    let subject: { type: DocType; id: string; code: string; label: string | null } | null = null
    if (subjectKey && subjectId) {
        const subjType = await docType(supabase, subjectKey)
        if (!subjType) {
            throw new Error(
                `SEARCH_UNKNOWN_DOCUMENT_TYPE|${subjectKey} —— 主语那一边不在 document_types 里`)
        }
        const row = await subjectRow(supabase, subjType, subjectId)
        // ★ 读不到 ⇒ **整页拒绝**,不是空列表。标题里印着主语的标签,
        //   一个空列表读起来是「这个主语没有产出批」—— 那是一句关于数据的断言。
        if (!row) {
            return (
                <ListPage
                    title={targetName}
                    state={{
                        kind: 'restricted',
                        title: targetName,
                        statement: t('related.subjectUnreadable'),
                        hint: t('related.subjectUnreadableHint'),
                        backHomeLabel: t('common.backHome'),
                    }}
                />
            )
        }
        subject = { type: subjType, id: subjectId, code: row.code, label: row.label }
    }

    // ── 取行 ────────────────────────────────────────────────────────────────
    // ★ 要 PAGE_SIZE + 1 条:多出来的那一条只回答「还有没有下一页」。
    //   ⚠ 而「一共有几条」**不由它回答** —— 那个数由函数的 `total`
    //     (`count(*) OVER ()`,在翻页之前求出)给。两个问题,两个来源,
    //     谁都不冒充谁(与 `search_documents` 的 `more` 逐字同一条理由)。
    // ★★【三个可省的参数传的是 `undefined`,不是 `null`,而这【不是】风格】★★
    //   `JSON.stringify` 丢掉 undefined,于是【无主语】那一次调用**根本不发送**
    //   `p_key` / `p_id`,PostgREST 按名调用,SQL 那边的 `DEFAULT NULL` 接住它。
    //   ☞ 传 `null` 在类型上过不去,而**过不去是对的** —— 迁移 -fu1 之前
    //     生成的类型写着 `p_key: string`,也就是「这两个参数永远有值」,
    //     而那句话是假的。**修法是让 SQL 把自己的意思说完整,不是在这里写一句
    //     cast 把整个参数对象的检查关掉**(BUGFIX-1a:6 句 `as never` 挡住了
    //     唯一看得见 `container_no` 不存在的那道闸,一条死查询活了 8 天)。
    const rowsRes = await supabase.rpc('search_related_rows', {
        p_key: subjectKey,
        p_id: subjectId,
        p_target_key: targetKey,
        p_limit: PAGE_SIZE + 1,
        p_after_code: after,
    })
    const fetched = mustRows(
        rowsRes as { data: RowsRow[] | null; error: { message: string; code?: string } | null },
        'search_related_rows')
    const hasNext = fetched.length > PAGE_SIZE
    const page = fetched.slice(0, PAGE_SIZE)
    const total = page.length > 0 ? Number(page[0].total) : 0

    // ── 四种零里的后两种 ────────────────────────────────────────────────────
    if (page.length === 0) {
        let sentence: string
        if (!subject) {
            sentence = t('related.noneOfType', { target: targetName })
        } else {
            // ★ 「结构上没有边」与「有边但今天没有行」是两件事。
            //   这一问是一句 EXISTS,**不是**第二份边→SQL 翻译 —— 翻译那一份
            //   只有一处,在 search_related_rows() 里。
            const edges = mustRows(
                await supabase.from('document_relations').select('to_table')
                    .eq('from_table', subject.type.table_name)
                    .eq('to_table', target.table_name).limit(1),
                'document_relations')
            sentence = edges.length === 0
                ? t('related.noEdge')
                : t('related.noneNow', { target: targetName })
        }
        return (
            <ListPage
                title={titleOf(t, targetName, subject)}
                breadcrumb={backLink(t, subject)}
                maxWidth="max-w-5xl"
                state={{ kind: 'empty', noRows: sentence }}
            />
        )
    }

    // ── 行 ──────────────────────────────────────────────────────────────────
    const rows: RelatedRow[] = page.map((r) => ({
        id: r.id,
        code: r.code,
        label: r.label ?? '',
        // ★ type_list 的那 5 种没有逐张单据的落点 —— 它们是文字,不是链接。
        //   与搜索面板走**同一支** documentHref(),不是第二份实现。
        href: target.link_mode === 'type_list'
            ? null
            : documentHref({
                key: target.key, route: target.route,
                linkMode: target.link_mode as DocumentLinkMode,
                id: r.id, code: r.code,
            }),
    }))

    const base = subject
        ? `/related/${subject.type.key}/${subjectId}/${targetKey}`
        : `/documents/${targetKey}`

    return (
        <ListPage
            title={titleOf(t, targetName, subject)}
            breadcrumb={backLink(t, subject)}
            maxWidth="max-w-5xl"
            state={{ kind: 'ok' }}
        >
            <RelatedTable
                rows={rows}
                showLabel={target.label_column !== null}
                codeHeader={t('related.colCode')}
                labelHeader={t('related.colLabel')}
            />
            <p
                className="mt-3 text-sm text-[color:var(--brand-muted-text)]"
                data-related-showing={String(page.length)}
                data-related-total={String(total)}
            >
                {t('related.showing', { shown: String(page.length), total: String(total) })}
            </p>
            {(hasNext || after) && (
                <div className="mt-2 flex flex-wrap items-center gap-4 text-sm">
                    {after && (
                        <Link href={base} className="app-link hover:underline" data-related-page="first">
                            {t('related.firstPage')}
                        </Link>
                    )}
                    {hasNext && (
                        <Link
                            href={`${base}?after=${encodeURIComponent(page[page.length - 1].code)}`}
                            className="app-link hover:underline"
                            data-related-page="next"
                        >
                            {t('related.nextPage')}
                        </Link>
                    )}
                </div>
            )}
        </ListPage>
    )
}

/** 「NMC Cathode Foil 的产出批」/ 无主语时就是「化验单」。 */
function titleOf(
    t: (k: string, p?: Record<string, string | number>) => string,
    targetName: string,
    subject: { code: string; label: string | null } | null,
): string {
    if (!subject) return targetName
    // ★ 有标签才用标签,没有就用单据号 —— **不拿别的东西顶上**(9 个种类没有
    //   label_column;`toHit` 已经是这条规矩)。
    return t('related.titleOf', {
        target: targetName,
        subject: subject.label && subject.label !== '' ? subject.label : subject.code,
    })
}

/**
 * 返回路(Q11)—— **回到主语的详情页,不放「回到搜索」**。
 * 搜索是一个下拉,它没有一个可以返回的地址。
 *
 * ★ 走 `documentHref()`,不自己拼 —— 主语的落点与命中行的落点是同一个问题。
 * ★ 只有 `link_mode='detail'` 的主语才有一张【属于它自己】的页面。其余三种
 *   的"落点"是一张列表,而一条写着「回到 NMC Cathode Foil」却落在
 *   【全部物料】上的链接,是一句它兑现不了的话。**那时不画链接。**
 *   ⚠ 实测:40 个种类里 22 个是 detail —— 所以这一格【经常】是空的,
 *     而空着是对的,不是漏了。
 */
function backLink(
    t: (k: string, p?: Record<string, string | number>) => string,
    subject: { type: DocType; id: string; code: string; label: string | null } | null,
): React.ReactNode {
    if (!subject || subject.type.link_mode !== 'detail') return undefined
    return (
        <Link
            href={documentHref({
                key: subject.type.key, route: subject.type.route,
                linkMode: subject.type.link_mode, id: subject.id, code: subject.code,
            })}
            className="app-link hover:underline"
            data-related-back="1"
        >
            {t('related.backToSubject', { subject: subject.label || subject.code })}
        </Link>
    )
}
