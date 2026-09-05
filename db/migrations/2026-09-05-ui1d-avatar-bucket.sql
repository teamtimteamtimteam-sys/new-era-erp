-- db/migrations/2026-09-05-ui1d-avatar-bucket.sql
-- UI-1d(v1.3.3):头像 —— 一个公开桶 + 四条【只准动自己那一个对象】的策略。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ① 挂在 auth 账号上,不挂在员工档案上
-- ════════════════════════════════════════════════════════════════════════════
-- 对象名是 <auth.users.id>.webp。**不是 employees.id**,理由是一条已经存在的
-- 刻意处置:UI-1a 的 AvatarMenu 专门接住了「账号还没连上员工档案」这一情形
-- (那时它画邮箱首字母,并且【不画】名字那一行)。把头像挂到 employees 上,
-- 等于对这些账号宣布【它们永远不能有头像】—— 而"HR 还没建档"是一个会过去的
-- 状态,不该在存储布局里被固化成永久的。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ② ★★ 这是本项目【第一个公开桶】,而那件事有后果 —— 记在这里,不只记在报告里 ★★
-- ════════════════════════════════════════════════════════════════════════════
-- 现有 13 个桶全部是私有的(cn-documents … traceability-documents)。这一个不是。
--
-- 【收下的后果,逐条写明】
--   · **任何人猜中一个 user_id,就能不登录取到那个人的脸。** 对象地址是
--     .../storage/v1/object/public/avatars/<user_id>.webp,没有任何认证;
--   · **地址本身把 auth uid 说了出去。** 谁看得见页面,谁就看得见那个 uuid。
--
-- 【为什么仍然收下】(Tim 的裁定,UI-1d Q8)
--   头像不含机密;而私有桶要给【每一次页面加载、每一个人、每一页】加一趟
--   签名 URL 往返 —— 顶栏的头像画在所有页面上,那是全系统最热的一处渲染。
--   为一件装饰品付这笔钱,今天(6 个使用者、一家公司内部)不值。
--
-- 【被否掉的替代方案,写下来是为了让将来重开这个决定的人知道自己在重开什么】
--   (a) 私有桶 + 每次加载签一个 60 秒 URL —— 每页一趟往返,被否;
--   (b) 私有桶 + 一个 Next 路由把字节代理出来(自带缓存头,地址里不出现 uid)
--       —— **这是人变多之后该走的那条路**:它把 uid 从公开地址里拿掉,
--       代价是每张头像一次服务端跳转。今天不做,不是因为它不对,
--       是因为 6 个人不值这一跳。
--   人一多、或者哪天有了对外的门户,就重开这一条,并照 (b) 改。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ③ ★★ 判据是【全等】,不是【前缀】★★
-- ════════════════════════════════════════════════════════════════════════════
-- 委托书原文写的是 "the object name starts with the caller's own uid"。
-- **那一条被推翻了**(Tim 的裁定,UI-1d Q2)。前缀判据会把
--     <uid>-evil.webp · <uid>.html · <uid>/任意/深/路径
-- 一并放进一个【全世界可读】的桶:没有任何代码会去读它们,也没有任何东西
-- 会去清它们,而它们的地址是可以被猜到并直接分发的。
-- 全等判据没有这个尾巴,而且不更难写:
--     name = auth.uid()::text || '.webp'
--
-- ★【own-avatar-only 由这四条策略强制,不由"上传按钮放在哪一页"强制】★
--   上传控件住在 /me。那【不是】强制手段 —— server action 是可以被直接调的。
--   真正拦住"改别人的头像"的是下面 WITH CHECK / USING 里的 auth.uid():
--   写谁,由 JWT 说了算,与请求从哪一页发出来毫无关系。
--   本刀对着线上双向证过:本人写得进自己的;第二个账号写不进第一个人的。
--   并把判据注入成放行版,确认断言变红点名 file:line,再还原。
--
-- ★【一处诚实的残余:策略保证"只能动自己那一个",不保证"里面是服务端产的字节"】★
--   authenticated 拿着 INSERT/UPDATE,所以一个人【绕开应用、直接调存储 API】
--   可以往自己那一个对象里放任意字节。应用这一侧 Step 1 的重编码仍然成立
--   (走 /me 的每一张图都是服务端解码后重新编出来的),而绕过去的那条路由
--   下面两个桶级限制兜住:allowed_mime_types 只收 image/webp,
--   file_size_limit 256KB(服务端产出实测 3–6KB)。
--   **爆炸半径是他自己的那个圆**:画不出来时 AvatarImage 的 onError 回落成首字母。
--   要把这一条也堵死,只能收回 authenticated 的写权限、改由 service_role 代写 ——
--   但那样"只能动自己的"就【不再由策略回答】,而那正是本刀要的性质。
--   两者取其一,取了策略。

BEGIN;

-- ── 桶 ──────────────────────────────────────────────────────────────────────
-- file_size_limit / allowed_mime_types:桶级的第二道闸。应用侧已经拦了
-- 2MB + 三种输入格式,但那是【输入】侧;这两个数管的是【落桶】侧,
-- 于是绕开应用的那条路也有上限。256KB 对一张 256×256 q82 的 WebP
-- 是宽出两个数量级的余量(实测纯色 188 字节、照片 3–6KB)。
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('avatars', 'avatars', true, 262144, ARRAY['image/webp']);

-- ── 四条策略。**每一条都是同一个全等判据** ─────────────────────────────────
--
-- 【为什么 SELECT 也收窄到自己】公开读走的是 /object/public/... 那条路,
--   **它不过 RLS** —— 所以把 SELECT 收窄【不影响任何人看见任何人的头像】。
--   它管的是另一件事:带着 JWT 调 API 时能不能列出/看见别人那一行元数据。
--   upsert 与 remove 需要看得见【自己】那一行,所以这一条不能没有;
--   而放宽到整个桶只会多送出一份别人对象的元数据,没有读者。
CREATE POLICY "own avatar read"
    ON storage.objects FOR SELECT TO authenticated
    USING (bucket_id = 'avatars' AND name = auth.uid()::text || '.webp');

CREATE POLICY "own avatar upload"
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'avatars' AND name = auth.uid()::text || '.webp');

-- UPDATE 两侧都要写:USING 决定【看得见哪一行去改】,WITH CHECK 决定
-- 【改完之后允许长成什么样】。只写 USING 的话,一个人可以把自己那一行的
-- name 改成别人的 —— 那正是"改别人头像"的另一条路,而且不那么显眼。
CREATE POLICY "own avatar update"
    ON storage.objects FOR UPDATE TO authenticated
    USING (bucket_id = 'avatars' AND name = auth.uid()::text || '.webp')
    WITH CHECK (bucket_id = 'avatars' AND name = auth.uid()::text || '.webp');

CREATE POLICY "own avatar delete"
    ON storage.objects FOR DELETE TO authenticated
    USING (bucket_id = 'avatars' AND name = auth.uid()::text || '.webp');

COMMIT;
