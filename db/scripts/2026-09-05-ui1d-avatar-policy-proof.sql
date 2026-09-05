-- db/scripts/2026-09-05-ui1d-avatar-policy-proof.sql
-- UI-1d:头像存储策略的【双向证明】—— 整支回滚,一行都不留。
--
-- 跑法(ON_ERROR_STOP=1 是判据的一半,不能省):
--     psql "$DSN" -X -v ON_ERROR_STOP=1 -f db/scripts/2026-09-05-ui1d-avatar-policy-proof.sql
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★【为什么它不住在 db/fixtures/】★
-- ════════════════════════════════════════════════════════════════════════════
-- db/fixtures 是"第三个判词",由 db/gate.py 在【本地重建库】上逐个跑。
-- 而重建库【没有 storage 架构】—— db/platform-prelude.sql 造的是 auth.users、
-- auth.uid() 与 authenticated/anon 两个角色,storage.buckets / storage.objects
-- 一个都不造(实测:prelude 里 "storage" 零次出现)。既有的 13 个桶也从来
-- 没有进过镜像:check_mirrors.py 与 gate.py 里同样零次出现 "storage"。
-- 所以把这份断言放进 fixtures,只会让门对着一件【重建库里不存在的东西】变红。
--
-- 改成:**对着线上跑,整支包在一个回滚掉的事务里。** 被测的因此是真正在
-- 保护这六个人的那份策略,而不是一份复制品。用的两个 uuid 是【凭空造的】,
-- 不是任何真人的账号 —— auth.uid() 读的是 request.jwt.claims,谓词求值
-- 不需要 auth.users 里真有这一行。
-- ★ Tim 的裁定(UI-1d Q7):**不许为了这个证明去线上建一次性账号。**
--   PRE-ACCOUNT-1 整整一刀在收拾四个活了 17.5 小时的一次性 admin 账号 ——
--   那扇门不为一条多余的链路重新打开。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★【断言一律 RAISE,绝不"返回一个值让人去看"】★
-- ════════════════════════════════════════════════════════════════════════════
-- RLS 的坑正在这里:被策略挡住的读【不报错,只是少了几行】,于是一个
-- 「SELECT ... INTO」式的断言拿到的是 NULL,而 NULL 与"通过"在肉眼下一样。
-- 下面每一格失败都 RAISE EXCEPTION,ON_ERROR_STOP 让 psql 退非零 ——
-- 判词是退出码,不是屏幕上的一段字。

\set ON_ERROR_STOP on

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- ★【为什么这里要 session_replication_role = replica —— 实测出来的,不是抄的】★
-- ════════════════════════════════════════════════════════════════════════════
-- 第一版的 B3(第二个账号删别人的对象)不是变红,是【报了一个与策略无关的错】:
--
--     ERROR: Direct deletion from storage tables is not allowed. Use the Storage API instead.
--     CONTEXT: PL/pgSQL function storage.protect_delete()
--
-- 查了一下:storage.objects 上挂着 **protect_objects_delete**,
-- `BEFORE DELETE ... FOR EACH STATEMENT` —— **语句级**。语句级的意思是
-- 它在"有没有行可删"之前就开火,所以哪怕 RLS 让 B 一行都看不见,
-- 这条 DELETE 也走不到策略那一步。**它挡的是所有人,与本刀的策略无关。**
--
-- `session_replication_role = replica` 关掉用户触发器,**而 RLS 照常生效**
-- (RLS 不是触发器也不是规则)。它是 SET LOCAL:只在本事务里,而且【不取任何锁】——
-- 相比 `ALTER TABLE ... DISABLE TRIGGER` 要 ACCESS EXCLUSIVE、会挡住线上正在
-- 传附件的人,这一条是免费的。
--
-- ★【"RLS 会不会也被一起关掉"这个疑问,由脚本自己回答】★ 不用相信上面那句话:
--   B1 / B4 / C1 这几格【期望被拒】,而且它们跑在同一个 replica 设置下。
--   RLS 真被关掉的话,它们会当场变红。**绿的那一刻,这个疑问就被证伪了。**
SET LOCAL session_replication_role = replica;

-- ════════════════════════════════════════════════════════════════════════════
-- ★【故障注入 —— 同一个文件、同一批行号,靠一个 psql 变量切换】★
-- ════════════════════════════════════════════════════════════════════════════
--     绿:psql … -f 本文件
--     红:psql … -v inject=1 -f 本文件
--
-- 注入把 "own avatar upload" 换成【放行版】(只看桶,不看名字)——
-- 也就是委托书原本描述的那种松判据再松一档。于是 B1(第二个账号写别人的头像)
-- 应当【成功】,而那一格的断言应当当场 RAISE 并点名 file:line。
--
-- ★【为什么注入也包在这个回滚事务里,而不是"改完再改回来"】★
--   db/injection_probe.py 的抬头写着这套东西存在的理由:**restore() 是手写的,
--   漏一句,后面每一格都跑在一个被污染的库上,而且不会有任何东西报错。**
--   包进事务之后,还原不再由"我记得改回去"负责,而是由数据库负责 ——
--   **机制,不是清单。** 这条策略是【线上六个人正在用的】那一条,
--   它一秒都不该处在放行状态。
\if :{?inject}
DROP POLICY "own avatar upload" ON storage.objects;
CREATE POLICY "own avatar upload"
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'avatars');   -- ← 名字判据被拿掉了,这就是注入
\echo '★★ 注入已生效:own avatar upload = 放行版(只看桶,不看名字)★★'
\endif

DO $proof$
DECLARE
    -- 凭空造的两个 uuid。不是任何人的账号,事务回滚后不留痕。
    a  uuid := '00000000-0000-4000-8000-0000000000aa';
    b  uuid := '00000000-0000-4000-8000-0000000000bb';
    -- ★ 第三个人:**他的头像还不存在**。B1 拿他当靶子,理由见 B1 那一格。
    c  uuid := '00000000-0000-4000-8000-0000000000cc';
    n  integer;
BEGIN
    -- 前置:桶必须已经存在(迁移先跑)。缺了就当场说清楚,别让后面每一格
    -- 都因为一个说不出口的理由变红。
    PERFORM 1 FROM storage.buckets WHERE id = 'avatars';
    IF NOT FOUND THEN
        RAISE EXCEPTION
            '[avatar-policy-proof] 前置不成立:storage.buckets 里没有 avatars 桶。先跑 db/migrations/2026-09-05-ui1d-avatar-bucket.sql。';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- 方向一:**本人写得进自己的那一个**
    -- ══════════════════════════════════════════════════════════════════════
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a::text, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    BEGIN
        INSERT INTO storage.objects (bucket_id, name, owner, owner_id, metadata)
        VALUES ('avatars', a::text || '.webp', a, a::text, '{"mimetype":"image/webp","size":188}'::jsonb);
    EXCEPTION WHEN insufficient_privilege THEN
        RESET ROLE;
        RAISE EXCEPTION
            '[avatar-policy-proof · A1] 方向一失败:本人写不进【自己的】头像(avatars/%.webp)。own avatar upload 策略把该放行的挡住了。', a;
    END;

    RESET ROLE;

    -- 控制格:第二个人写【自己的】也必须成功。少了它,下面那些"被拒"可能
    -- 只是因为策略把所有人都挡住了 —— 那样的绿是假的。
    PERFORM set_config('request.jwt.claims', json_build_object('sub', b::text, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
        INSERT INTO storage.objects (bucket_id, name, owner, owner_id, metadata)
        VALUES ('avatars', b::text || '.webp', b, b::text, '{"mimetype":"image/webp","size":188}'::jsonb);
    EXCEPTION WHEN insufficient_privilege THEN
        RESET ROLE;
        RAISE EXCEPTION
            '[avatar-policy-proof · A2] 控制格失败:第二个人连【自己的】都写不进,于是方向二的每一个"被拒"都说明不了任何事。';
    END;

    -- ══════════════════════════════════════════════════════════════════════
    -- 方向二:**第二个账号动不了第一个人的那一个**(角色仍然是 B)
    -- ══════════════════════════════════════════════════════════════════════

    -- B2-1:B 想写【别人的】头像 → 必须被 WITH CHECK 挡住。
    --
    -- ★【靶子是 C,不是 A —— 这是注入那一轮实测出来的】★
    --   第一版拿 A 当靶子,而 A1 已经把 avatars/<A>.webp 建出来了。注入之后
    --   RLS 确实放行了,可这条 INSERT 撞在 bucketid_objname 的唯一约束上:
    --   **门是红的,但它喊的是「duplicate key」,不是「第二个账号写进了别人的头像」。**
    --   一次说不出【自己抓到了什么】的红,与一次没抓到,在下一个人眼里差不多 ——
    --   而故障注入的全部意义就是确认"断言在被违反时会点名它"。
    --   换成 C(他的对象还不存在)之后,注入这一轮走的就是下面那句 RAISE。
    --   顺带把 unique_violation 也接住并另行点名,免得它哪天再冒充一次判词。
    BEGIN
        INSERT INTO storage.objects (bucket_id, name, owner, owner_id, metadata)
        VALUES ('avatars', c::text || '.webp', b, b::text, '{"mimetype":"image/webp","size":1}'::jsonb);
        RESET ROLE;
        RAISE EXCEPTION
            '[avatar-policy-proof · B1] 方向二失败:第二个账号【写进了】别人的头像 avatars/%.webp。own avatar upload 的 WITH CHECK 没有起作用。', c;
    EXCEPTION
        WHEN insufficient_privilege THEN NULL;   -- 期望的那一条
        WHEN unique_violation THEN
            RESET ROLE;
            RAISE EXCEPTION
                '[avatar-policy-proof · B1] 判不出来:靶子 avatars/%.webp 已经存在,于是这一格撞的是唯一约束而不是策略。换一个不存在的靶子。', c;
    END;

    -- B2-2:B 想改 A 的对象 → 连看都看不见,受影响行数必须是 0
    UPDATE storage.objects
       SET metadata = '{"mimetype":"image/webp","size":2}'::jsonb
     WHERE bucket_id = 'avatars' AND name = a::text || '.webp';
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n <> 0 THEN
        RESET ROLE;
        RAISE EXCEPTION
            '[avatar-policy-proof · B2] 方向二失败:第二个账号 UPDATE 到了别人的头像,受影响 % 行(应为 0)。', n;
    END IF;

    -- B2-3:B 想删 A 的对象 → 同样必须是 0 行。
    --      (平台那条语句级 protect_delete 已由本事务的 replica 设置让开,
    --       所以这一格量到的是【我们的策略】,不是平台的防呆。)
    DELETE FROM storage.objects
     WHERE bucket_id = 'avatars' AND name = a::text || '.webp';
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n <> 0 THEN
        RESET ROLE;
        RAISE EXCEPTION
            '[avatar-policy-proof · B3] 方向二失败:第二个账号 DELETE 掉了别人的头像,受影响 % 行(应为 0)。', n;
    END IF;

    -- B2-4:B 想把【自己的】那一行改名成 A 的名字 —— 这是"改别人头像"的
    --       另一条路,而且不那么显眼。UPDATE 的 WITH CHECK 就是为它写的。
    BEGIN
        UPDATE storage.objects
           SET name = a::text || '.webp'
         WHERE bucket_id = 'avatars' AND name = b::text || '.webp';
        RESET ROLE;
        RAISE EXCEPTION
            '[avatar-policy-proof · B4] 方向二失败:第二个账号把自己那一行【改名】成了别人的头像。own avatar update 缺 WITH CHECK。';
    EXCEPTION
        WHEN insufficient_privilege THEN NULL;  -- 期望的那一条
    END;

    -- ══════════════════════════════════════════════════════════════════════
    -- ★ 方向三:**全等判据,不是前缀判据**(Tim 推翻委托书的那一条,Q2)
    --   前缀判据下这三个名字都会被放行,而它们住在一个全世界可读的桶里、
    --   没有任何读者、也没有任何东西会去清。
    -- ══════════════════════════════════════════════════════════════════════
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a::text, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    DECLARE
        junk text;
    BEGIN
        FOREACH junk IN ARRAY ARRAY[a::text || '-evil.webp', a::text || '.html', a::text || '/deep/path.webp']
        LOOP
            BEGIN
                INSERT INTO storage.objects (bucket_id, name, owner, owner_id, metadata)
                VALUES ('avatars', junk, a, a::text, '{"mimetype":"image/webp","size":1}'::jsonb);
                RESET ROLE;
                RAISE EXCEPTION
                    '[avatar-policy-proof · C1] 全等判据失败:% 被放行了。这正是前缀判据会漏进来的那一类对象。', junk;
            EXCEPTION
                WHEN insufficient_privilege THEN NULL;  -- 期望的那一条
            END;
        END LOOP;
    END;

    RESET ROLE;
    RAISE NOTICE '[avatar-policy-proof] 全部通过:A1 A2 · B1 B2 B3 B4 · C1(三个名字)';
END
$proof$;

-- ★ 整支回滚 —— 上面插进去的两行对象一行都不留。
ROLLBACK;
