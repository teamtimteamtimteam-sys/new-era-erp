# 手走清单 —— 只有人点得到的那些断言

`db/fixtures` 问"建出来的库跑起来对不对";`scripts/smoke-routes.mjs` 问"每条路由渲不渲得出来"。
**这份清单问第三个问题:操作员在屏幕上【读到的那句话】是不是人话。**

没有任何自动化跑得到它,原因是具体的而不是懒:

* 冒烟只发 **GET**,它断言 2xx —— 它从不提交任何表单;
* 表单用 `useActionState`(客户端组件),**没有渐进增强的隐藏字段**,所以
  无 JS 的 POST 根本到不了 action;走 Next 的 action 线格式需要客户端 bundle 里的
  action id,而那正是浏览器才有的东西;
* fixture 是 SQL,它够得到 RPC,**够不到 action 与 locale 文件**。

于是"数据库那侧完全正确、而屏幕上是一串机器码"这件事,**只有人点得出来**。
IOD-1b 与 IOD-2 各付过一次账,两次都是人点出来的。

## 什么时候跑

改动了 **action 的错误分支、`*ErrorCodes.ts` 的集合、`messages/*` 里的错误/告警句子**,
或者新加了一个会抛到界面上的 RPC 错误码 —— 跑与之相关的那几条。不必每次全跑。

## 怎么起

```bash
npx next dev -p 3000
```
临时管理员账号自己建(参照 `scripts/smoke-routes.mjs` 的 `signIn`),或用一个真账号。
**被拒的走法不写任何流水**,可以放心在 live 上点;标着【会写库】的那几条会留下
**永久的 `inventory_movements` 行**(台账只进不出,`BEFORE DELETE` 抛 `MOVEMENT_IMMUTABLE`),
所以那几条要么别在 live 上点,要么接受它留下来。

---

## 1 · 库位分类落闸:明确排除 → 拒绝(IOD-2)

**前提**:一个在用库位配了 allowed_classes(例如只允许 `focused`);一个物料的分类
**不在**其中(例如 `non_focused`)。

**走**:`/inbound/new` → 选那个物料、那个库位 → 保存。
**期望**:红条是一句话,并且**说得出三条出路**(换库位 / 把这一类加进该库位 / 改物料分类):

> Location SG… is configured to hold specific material classes, and non_focused is not one of
> them — so nothing was saved. Pick another location, add non_focused to that location under
> Inventory → Storage Locations, or correct this material's classification in the material dictionary.

**不期望**:`IOD_CLASS_EXCLUDED|SG…|non_focused`(机器码原样)。

**为什么在这份清单里**:拒绝由 RPC 抛出(fixture 59 B3/E/F1/F2 已经钉住"抛得对"),
**但"抛完之后有没有被翻成人话"住在 action 的错误分支 + `messages/*` 里** —— fixture 是
SQL,够不到那两处。这一条 2026-08-13 手走时是红的:action 那时用一句手抄的正则挑
错误码,新码没被挑中,于是走了 `saveError` 分支把机器码端了出去。
现在判据改成 `isStockErrorCode()`(与 `STOCK_ERROR_CODES` 同一份),漂开的那条路没有了,
但**"句子长什么样"仍然只有人看得见**。

其余三个落地点同理,改了任何一处错误分支就顺带走一遍:
`/inbound/receive`、`/output/new`、以及批次页上的**转移**面板(它不重定向,告警直接回到面板)。

## 2 · 日期必填:说人话,不说约束名(IOD-2-fu1 / FIN-32)

**走**:`/output/new` → 填物料与数量,**产出日留空** → 保存钮应当是灰的、下面有一句
琥珀色说明;再想办法提交一次(绕过界面那道守卫)。
**期望**:

> Output date is required — the stock movement records the day the goods were actually produced

**不期望**:`new row for relation "inventory_movements" violates check constraint
"inventory_movements_business_date_required"`(约束原文)。

到货日在 `/inbound/new` 与 `/inbound/receive` 上同理。

**为什么在这份清单里**:这一条现在**有一半是自动的** —— fixture 25 H 臂断言三个 RPC
少了日期会**按名**拒绝(`ARRIVAL_DATE_REQUIRED` / `OUTPUT_DATE_REQUIRED`),那是
2026-08-13 手走之后补上的:当时 RPC 自己一道守卫都没有,只有 app 那一层有,
于是任何不经过表单的调用者都会撞到 FIN-32 的 CHECK 并拿到约束原文。
**剩下的一半仍然只有人点得到**:那个名字有没有在两个 locale 里接成句子、
以及界面那道守卫(禁用提交 + 说明)是不是真的在。

## 3 · 落地告警:琥珀、成句、一条一行(IOD-2)

**走**:把货收进一个**没配过 allowed_classes** 的库位,或收一个**未分类**的物料。
**期望**:落地页(`/inbound`、`/output`、收货完成页)顶部一条**琥珀色**横幅,
一条告警一行,并且**批次确实建出来了** —— 告警不是拒绝。

【**会写库**】这一条的期望结果是"保存成功",所以它会在 live 上留下永久流水。
2026-08-13 的做法是**只走渲染那一半**:直接请求
`/inbound?warn=%5B%22IOD_CLASS_UNCONFIGURED_LOCATION%7CSG…%22%5D`,
真组件、真本地化、不写库。RPC 会不会吐出这两个码,由 fixture 59 B1/C/E/F3 钉住。
两半合起来等于整条路径,而没有任何一行永久流水。

## 4 · 物料表单的【提交】那一半:安全库存阈值真的落库(SS-1)

**两条,新建与编辑各一条 —— 它们是两段不同的代码**:`app/materials/new/actions.ts`
走 `.insert()`,`app/materials/[id]/edit/actions.ts` 走 `.update()`,各有一份取值、
一份校验、一份写入。走通了一条不代表另一条。

**走 A(新建)**:`/materials/new` → 填必填项 + 安全库存填 `500` → 保存 →
回到列表,该物料那一列应当显示 `500 kg`,**而不是「未监控」**。
**走 B(编辑)**:`/materials/<id>/edit` → 把阈值**清空** → 保存 →
列表那一列应当变成**「未监控」**,而不是 `0`。
**走 C(两条表单各一次)**:阈值填 `0` 或 `-5` → 期望是那句话:
「安全库存必须是大于 0 的数字 —— 不想监控这个物料就留空」,
**不期望**约束原文 `materials_safety_stock_qty_positive`。

**为什么在这份清单里 —— 与前三条同一个理由,而且是同一堵墙**:表单用
`useActionState`(客户端组件),**没有渐进增强的隐藏字段**,所以无 JS 的 POST
到不了 action;走 Next 的 action 线格式又需要客户端 bundle 里的 action id。
冒烟只发 GET,fixture 是 SQL 够不到 action。**2026-08-13 的 SS-1 手走只走到了
渲染那一半**(两张表单的字段与提示句都确认渲染出来了,列表那一列也确认了),
**提交那一半一次都没有人点过** —— 那正是这一条存在的理由,别把它读成"已经走过"。

数据库那一侧不必在这里走:CHECK(NULL 或 > 0)由 fixture 60 F 臂两个方向各拒
一次,告警对 NULL 不响由 D 臂钉死。这一条只问【表单填的值有没有原样落进去】,
以及【拒绝有没有说人话】。
