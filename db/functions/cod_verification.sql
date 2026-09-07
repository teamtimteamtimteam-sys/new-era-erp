CREATE OR REPLACE FUNCTION public.cod_verification(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    -- ★★【限流:滚动 10 分钟里 30 次【失败】,而有效令牌永不被限流】★★
    --
    -- 【依据,写在数字旁边而不只写在报告里】
    --   ① 真正挡住枚举的【不是这个数】,是令牌本身:它是 122 位随机的 UUID,
    --      猜中一次的概率是 2^-122。任何限流都只是在一个 5.3×10^36 的空间上
    --      少数几个数量级的差别 —— 说这个数字"防住了猜测"是不诚实的。
    --      它真正的差事有两件:控制成本与噪声;以及万一哪天令牌从别处漏成了
    --      可猜的形状,留一道纵深。
    --   ② 预算只算【失败】。一个拿着二维码扫进来的持有人产生【零次】失败;
    --      一个把网址敲错、抄漏一段的人产生一两次。6 个员工加少量供应商,
    --      合理的失败率远在个位数/10 分钟。30 次是它的约五十倍。
    --   ③ 而对探测方:30 次/10 分钟 ≈ 每年 158 万次,对着 5.3×10^36 的空间。
    --   ④ ★【有效令牌永不被限流】★ —— 这一条是这个设计能成立的关键:
    --      攻击者【拿不出】有效令牌,所以他【限不掉任何一个真实持有人】。
    --      一个"全局失败预算"若也拦有效令牌,就成了一个人人可用的拒绝服务开关。
    c_budget   constant integer  := 30;
    c_window   constant interval := interval '10 minutes';
    v_tok      uuid;
    v_found    boolean := false;
    v_status   text;
    v_snap     jsonb;
    v_repl     uuid;
    v_repl_code text;
    v_n        integer;
    v_retry    integer;
BEGIN
    -- 【格式判据自己做】—— 见抬头:收 uuid 会让"格式不对"在 PostgREST 那层
    -- 就变成一个不一样的答案。NULL 走同一条路(NULL ~* … 是 NULL,不是真)。
    IF p_token ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        v_tok := p_token::uuid;
        SELECT c.status, c.snapshot, c.replaced_by_cod_id
          INTO v_status, v_snap, v_repl
          FROM certificates_of_destruction c
         WHERE c.verification_token = v_tok;
        -- 【没有快照的行等于查不到】—— pending 行拿不到令牌(表上的 CHECK 钉着),
        -- 但这里不靠那条约束活着:渲染不出来的东西一律走同一句话。
        v_found := FOUND AND v_snap IS NOT NULL;
    END IF;

    IF NOT v_found THEN
        -- 【一把锁,免得并发探测把预算冲过去】与 next_cod_code 同一个习惯:
        -- 事务级顾问锁,便宜、自动释放,而且它让"30"真的是 30。
        PERFORM pg_advisory_xact_lock(hashtext('cod_verification_failures')::bigint);
        DELETE FROM cod_verification_failures WHERE failed_at < clock_timestamp() - c_window;
        SELECT count(*) INTO v_n FROM cod_verification_failures;
        IF v_n >= c_budget THEN
            -- 【超了预算就不再插入】—— 否则探测会把窗口无限往后推,
            -- 那是把限流变成永久封锁。窗口自己滴干。
            SELECT GREATEST(1, ceil(EXTRACT(EPOCH FROM
                       (min(f.failed_at) + c_window - clock_timestamp()))))::integer
              INTO v_retry FROM cod_verification_failures f;
            RETURN jsonb_build_object('result', 'throttled',
                                      'retry_after_seconds', COALESCE(v_retry, 60));
        END IF;
        INSERT INTO cod_verification_failures DEFAULT VALUES;
        -- ★【不认识 / 格式不对 —— 同一句话,不带任何区别】★
        RETURN jsonb_build_object('result', 'not_found');
    END IF;

    -- 【作废之后顶上来的那一张:只回它的【号】】—— 不回 id,也不回它的令牌。
    -- 没顶上来的(冲销那一种)是 NULL,页面照直说"没有替代品,请联系我们"。
    IF v_status = 'void' AND v_repl IS NOT NULL THEN
        SELECT c.code INTO v_repl_code
          FROM certificates_of_destruction c
         WHERE c.id = v_repl AND c.status = 'issued';
    END IF;

    RETURN jsonb_build_object(
        'result', 'ok',
        -- ★【状态读的是【活行】,不是快照】★ 快照冻在签发那一刻,而作废发生在
        -- 之后 —— 拿快照里的 status 渲染,一张已经作废的证书会永远显示"有效"。
        'status', v_status,
        'certificate', jsonb_build_object(
            'code',      v_snap->'certificate'->>'code',
            'issued_at', v_snap->'certificate'->>'issued_at'),
        'processing', jsonb_build_object(
            'completed_on', v_snap->'processing'->>'completed_on'),
        'inbound_batch', jsonb_build_object(
            'code',                v_snap->'inbound_batch'->>'code',
            'material_code',       v_snap->'inbound_batch'->>'material_code',
            'material_name',       v_snap->'inbound_batch'->>'material_name',
            'quantity',            v_snap->'inbound_batch'->'quantity',
            'unit',                v_snap->'inbound_batch'->>'unit',
            'arrival_date',        v_snap->'inbound_batch'->>'arrival_date',
            'purchase_order_code', v_snap->'inbound_batch'->>'purchase_order_code'),
        'supplier', jsonb_build_object(
            'name', v_snap->'supplier'->>'name',
            'code', v_snap->'supplier'->>'code'),
        -- 【公司:正好是纸上抬头印的那几格】电话/邮箱/网址【不在纸上】,
        -- 所以也不在这里 —— "页上显示纸上有的,不多一格"。
        'company', jsonb_build_object(
            'legal_name',      v_snap->'company'->>'legal_name',
            'registration_no', v_snap->'company'->>'registration_no',
            'address_lines',   v_snap->'company'->>'address_lines',
            'city',            v_snap->'company'->>'city',
            'postal_code',     v_snap->'company'->>'postal_code',
            'country',         v_snap->'company'->>'country'),
        'licence', CASE WHEN v_snap->'licence' IS NULL OR v_snap->'licence' = 'null'::jsonb
                        THEN NULL ELSE jsonb_build_object(
            'cert_no',      v_snap->'licence'->>'cert_no',
            'issuing_body', v_snap->'licence'->>'issuing_body',
            'valid_from',   v_snap->'licence'->>'valid_from',
            'valid_until',  v_snap->'licence'->>'valid_until') END,
        -- 【作废那一格:只有"顶上来的是哪一号",没有原因】
        'void', CASE WHEN v_status = 'void'
                     THEN jsonb_build_object('replaced_by_code', v_repl_code)
                     ELSE NULL END);
END;
$function$;
