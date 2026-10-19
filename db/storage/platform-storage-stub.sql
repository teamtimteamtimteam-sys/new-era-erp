-- db/storage/platform-storage-stub.sql —— a STAND-IN for the Supabase storage schema, for a LOCAL rebuild only (NOROLE-SURFACE, 2026-10-19).
--
-- ★ NEVER run this against a Supabase project. The platform owns the storage schema (owner supabase_storage_admin); this file would fail
--   there with "schema storage already exists" — and it should.
--
-- Why it exists: db/storage/buckets-and-policies.sql is the repo mirror of the 19 buckets and 52 storage.objects policies (Q11). A mirror
-- that can only be READ is not a mirror anybody has checked, so db/gate.py installs this stub into its throwaway local rebuild, then the
-- mirror on top of it, and:
--   · db/check_norole.py (verdict 7) compares the result with live — bucket columns and every policy's name, command, roles and expression;
--   · db/fixtures/274 exercises the policies as real RLS on real rows (read / upload / update / delete by code, refused without it,
--     delete refused for a file a record points at and allowed for an orphan).
-- The prelude (db/platform-prelude.sql) is unchanged: the rebuild proper still does not model storage. Only the columns the policies and
-- the fixtures touch are here, in the platform's names and types (measured on live 2026-10-19: storage.objects / storage.buckets).
-- What it does NOT model: the Storage API itself (bytes, signed URLs, upsert), storage.protect_delete (the platform refuses a direct SQL
-- DELETE unless storage.allow_delete_query is set — the API sets it), and the platform's own grants beyond the arwd that live gives
-- authenticated. Those are proved only on live (the HTTP proof in docs/handbacks/NOROLE-SURFACE.md).
CREATE SCHEMA storage;
GRANT USAGE ON SCHEMA storage TO authenticated, anon;

CREATE TABLE storage.buckets (
    id                 text PRIMARY KEY,
    name               text NOT NULL,
    owner              uuid,
    created_at         timestamptz DEFAULT now(),
    updated_at         timestamptz DEFAULT now(),
    public             boolean DEFAULT false,
    avif_autodetection boolean DEFAULT false,
    file_size_limit    bigint,
    allowed_mime_types text[],
    owner_id           text
);

CREATE TABLE storage.objects (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    bucket_id        text REFERENCES storage.buckets (id),
    name             text,
    owner            uuid,
    created_at       timestamptz DEFAULT now(),
    updated_at       timestamptz DEFAULT now(),
    last_accessed_at timestamptz DEFAULT now(),
    metadata         jsonb,
    version          text,
    owner_id         text,
    user_metadata    jsonb,
    UNIQUE (bucket_id, name)
);

ALTER TABLE storage.buckets ENABLE ROW LEVEL SECURITY;
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
-- live: authenticated = arwd on both (supabase_storage_admin grants it); RLS decides
GRANT SELECT, INSERT, UPDATE, DELETE ON storage.buckets, storage.objects TO authenticated, anon;


-- ── MES-9b(2026-10-19):storage 架构里【对 PUBLIC 开着 EXECUTE】的 19 支平台函数的同名替身 ─────────────────────────────
-- 为什么要它们:MES-9b 给 supplier_portal 授了 storage 架构的 USAGE(门户会话要经 Storage API 读它自己的签发档),于是判词八
--   (db/check_portal.py)从目录里列出这个角色够得着的东西时,线上会列出这 19 支(PostgreSQL 默认对 PUBLIC 开 EXECUTE,平台没有收回);
--   重建侧必须列出同样的 19 支,两侧才能与 db/portal-grants-baseline.tsv 逐条相等。这里只复刻【签名】(名字 · 参数 · 返回类型,
--   2026-10-19 从线上 pg_get_function_arguments / pg_get_function_result 读来),函数体一律按名抛 —— 重建库上没有人会真的调它们。
--   平台升级 storage 改了其中一支的签名,判词八线上那一侧会红:那是门户角色够得着的东西变了,照它改这里与基线(docs/known-issues.md
--   MES9B-STORAGE-FUNCTIONS-FOLLOW-THE-PLATFORM)。
CREATE FUNCTION storage.allow_any_operation(expected_operations text[]) RETURNS boolean
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'storage stub: storage.allow_any_operation is a platform function, not modelled locally'; END $$;
CREATE FUNCTION storage.allow_only_operation(expected_operation text) RETURNS boolean
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'storage stub: storage.allow_only_operation is a platform function, not modelled locally'; END $$;
CREATE FUNCTION storage.can_insert_object(bucketid text, name text, owner uuid, metadata jsonb) RETURNS void
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'storage stub: storage.can_insert_object is a platform function, not modelled locally'; END $$;
CREATE FUNCTION storage.enforce_bucket_lifecycle_service_role() RETURNS trigger
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'storage stub: storage.enforce_bucket_lifecycle_service_role is a platform function, not modelled locally'; END $$;
CREATE FUNCTION storage.enforce_bucket_name_length() RETURNS trigger
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'storage stub: storage.enforce_bucket_name_length is a platform function, not modelled locally'; END $$;
CREATE FUNCTION storage.extension(name text) RETURNS text
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'storage stub: storage.extension is a platform function, not modelled locally'; END $$;
CREATE FUNCTION storage.filename(name text) RETURNS text
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'storage stub: storage.filename is a platform function, not modelled locally'; END $$;
CREATE FUNCTION storage.foldername(name text) RETURNS text[]
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'storage stub: storage.foldername is a platform function, not modelled locally'; END $$;
CREATE FUNCTION storage.get_common_prefix(p_key text, p_prefix text, p_delimiter text) RETURNS text
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'storage stub: storage.get_common_prefix is a platform function, not modelled locally'; END $$;
CREATE FUNCTION storage.get_size_by_bucket(noncurrent_versions text DEFAULT 'include'::text, delete_markers text DEFAULT 'include'::text) RETURNS TABLE(size bigint, bucket_id text)
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'storage stub: storage.get_size_by_bucket is a platform function, not modelled locally'; END $$;
CREATE FUNCTION storage.list_multipart_uploads_with_delimiter(bucket_id text, prefix_param text, delimiter_param text, max_keys integer DEFAULT 100, next_key_token text DEFAULT ''::text, next_upload_token text DEFAULT ''::text, raw_prefix_param text DEFAULT NULL::text) RETURNS TABLE(key text, id text, created_at timestamp with time zone)
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'storage stub: storage.list_multipart_uploads_with_delimiter is a platform function, not modelled locally'; END $$;
CREATE FUNCTION storage.list_objects_with_delimiter(_bucket_id text, prefix_param text, delimiter_param text, max_keys integer DEFAULT 100, start_after text DEFAULT ''::text, next_token text DEFAULT ''::text, sort_order text DEFAULT 'asc'::text, noncurrent_versions text DEFAULT 'exclude'::text, delete_markers text DEFAULT 'exclude'::text, next_token_archived_at timestamp with time zone DEFAULT NULL::timestamp with time zone, next_token_version text DEFAULT ''::text) RETURNS TABLE(name text, id uuid, metadata jsonb, updated_at timestamp with time zone, created_at timestamp with time zone, last_accessed_at timestamp with time zone, version text, archived_at timestamp with time zone, is_delete_marker boolean, is_versioned boolean)
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'storage stub: storage.list_objects_with_delimiter is a platform function, not modelled locally'; END $$;
CREATE FUNCTION storage.operation() RETURNS text
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'storage stub: storage.operation is a platform function, not modelled locally'; END $$;
CREATE FUNCTION storage.protect_bucket_control_columns() RETURNS trigger
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'storage stub: storage.protect_bucket_control_columns is a platform function, not modelled locally'; END $$;
CREATE FUNCTION storage.protect_delete() RETURNS trigger
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'storage stub: storage.protect_delete is a platform function, not modelled locally'; END $$;
CREATE FUNCTION storage.search(prefix text, bucketname text, limits integer DEFAULT 100, levels integer DEFAULT 1, offsets integer DEFAULT 0, search text DEFAULT ''::text, sortcolumn text DEFAULT 'name'::text, sortorder text DEFAULT 'asc'::text, noncurrent_versions text DEFAULT 'exclude'::text, delete_markers text DEFAULT 'exclude'::text) RETURNS TABLE(name text, id uuid, updated_at timestamp with time zone, created_at timestamp with time zone, last_accessed_at timestamp with time zone, metadata jsonb, version text, archived_at timestamp with time zone, is_delete_marker boolean, is_versioned boolean)
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'storage stub: storage.search is a platform function, not modelled locally'; END $$;
CREATE FUNCTION storage.search_by_timestamp(p_prefix text, p_bucket_id text, p_limit integer, p_level integer, p_start_after text, p_sort_order text, p_sort_column text, p_sort_column_after text, noncurrent_versions text DEFAULT 'exclude'::text, delete_markers text DEFAULT 'exclude'::text, p_start_after_version text DEFAULT ''::text) RETURNS TABLE(key text, name text, id uuid, updated_at timestamp with time zone, created_at timestamp with time zone, last_accessed_at timestamp with time zone, metadata jsonb, version text, archived_at timestamp with time zone, is_delete_marker boolean, is_versioned boolean)
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'storage stub: storage.search_by_timestamp is a platform function, not modelled locally'; END $$;
CREATE FUNCTION storage.search_v2(prefix text, bucket_name text, limits integer DEFAULT 100, levels integer DEFAULT 1, start_after text DEFAULT ''::text, sort_order text DEFAULT 'asc'::text, sort_column text DEFAULT 'name'::text, sort_column_after text DEFAULT ''::text, noncurrent_versions text DEFAULT 'exclude'::text, delete_markers text DEFAULT 'exclude'::text, start_after_archived_at timestamp with time zone DEFAULT NULL::timestamp with time zone, start_after_version text DEFAULT ''::text, start_after_is_continuation boolean DEFAULT false) RETURNS TABLE(key text, name text, id uuid, updated_at timestamp with time zone, created_at timestamp with time zone, last_accessed_at timestamp with time zone, metadata jsonb, version text, archived_at timestamp with time zone, is_delete_marker boolean, is_versioned boolean)
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'storage stub: storage.search_v2 is a platform function, not modelled locally'; END $$;
CREATE FUNCTION storage.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'storage stub: storage.update_updated_at_column is a platform function, not modelled locally'; END $$;
