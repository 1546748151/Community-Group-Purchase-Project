-- ============================================================================
-- 社区团购二维码下单工具 - Supabase 数据库初始化脚本
-- 使用方法：复制到 Supabase SQL Editor 中执行
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 1. 商品表
CREATE TABLE IF NOT EXISTS products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  image TEXT,
  specs JSONB NOT NULL DEFAULT '[]'::jsonb,
  tags JSONB NOT NULL DEFAULT '[]'::jsonb,
  stock NUMERIC(10,3),
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 兼容已创建过的旧表：CREATE TABLE IF NOT EXISTS 不会自动补列。
ALTER TABLE products ADD COLUMN IF NOT EXISTS image TEXT;
ALTER TABLE products ADD COLUMN IF NOT EXISTS specs JSONB NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE products ADD COLUMN IF NOT EXISTS tags JSONB NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE products ADD COLUMN IF NOT EXISTS stock NUMERIC(10,3);
ALTER TABLE products ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE products ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE products ADD COLUMN IF NOT EXISTS is_weighted BOOLEAN DEFAULT false;
ALTER TABLE products ADD COLUMN IF NOT EXISTS weight_estimate TEXT;
ALTER TABLE products ADD COLUMN IF NOT EXISTS weight_unit TEXT DEFAULT 'kg';
ALTER TABLE products ADD COLUMN IF NOT EXISTS round_id UUID REFERENCES rounds(id);
ALTER TABLE products ALTER COLUMN stock TYPE NUMERIC(10,3) USING stock::numeric;

COMMENT ON TABLE products IS '商品表';
COMMENT ON COLUMN products.specs IS '规格数组，如 [{"name":"500g","price":15},{"name":"1kg","price":28}]';
COMMENT ON COLUMN products.tags IS '商品标签数组，如 ["蛋糕","冷藏","山姆"]';
COMMENT ON COLUMN products.stock IS '库存数量，NULL 表示不限库存';
COMMENT ON COLUMN products.is_active IS '是否上架，false 为下架';

-- 2. 订单表
CREATE TABLE IF NOT EXISTS orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_name TEXT NOT NULL,
  items JSONB NOT NULL DEFAULT '[]'::jsonb,
  note TEXT DEFAULT '',
  total_amount NUMERIC(10,2) NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'cancelled')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE orders ADD COLUMN IF NOT EXISTS customer_name TEXT;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS items JSONB NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS note TEXT DEFAULT '';
ALTER TABLE orders ADD COLUMN IF NOT EXISTS total_amount NUMERIC(10,2) NOT NULL DEFAULT 0;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'active';
ALTER TABLE orders ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE orders ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
-- 添加 pending_weight 状态支持
ALTER TABLE orders DROP CONSTRAINT IF EXISTS orders_status_check;
ALTER TABLE orders ADD CONSTRAINT orders_status_check CHECK (status IN ('active', 'cancelled', 'pending_weight'));

COMMENT ON TABLE orders IS '订单表';
COMMENT ON COLUMN orders.items IS '购买明细 [{product_id, product_name, spec_name, spec_price, quantity, unit_qty, purchase_qty, subtotal}]，quantity 为购买次数，purchase_qty 为按规格折算后的采购/扣库存份量';
COMMENT ON COLUMN orders.status IS 'active=有效, cancelled=已取消';

-- 3. 设置表
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

COMMENT ON TABLE settings IS '系统设置键值表';

-- 预置默认设置
ALTER TABLE orders ADD COLUMN IF NOT EXISTS customer_group TEXT DEFAULT '';

INSERT INTO settings (key, value) VALUES
  ('admin_password', ''),
  ('round_fees', '{}'),
  ('group_names', '山姆群,美食群'),
  ('site_title', '美好小区团购群')
ON CONFLICT (key) DO NOTHING;

-- 4. 团购轮次表
CREATE TABLE IF NOT EXISTS rounds (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  cutoff_time TIMESTAMPTZ,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 团长账号表
CREATE TABLE IF NOT EXISTS leaders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  username TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'leader' CHECK (role IN ('leader', 'super_admin')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE leaders ENABLE ROW LEVEL SECURITY;
ALTER TABLE leaders ADD COLUMN IF NOT EXISTS password_plain TEXT;

DROP POLICY IF EXISTS "Anyone can read leaders" ON leaders;
CREATE POLICY "Anyone can read leaders" ON leaders FOR SELECT USING (true);

ALTER TABLE rounds ADD COLUMN IF NOT EXISTS name TEXT;
ALTER TABLE rounds ADD COLUMN IF NOT EXISTS cutoff_time TIMESTAMPTZ;
ALTER TABLE rounds ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE rounds ADD COLUMN IF NOT EXISTS leader_name TEXT;
ALTER TABLE rounds ADD COLUMN IF NOT EXISTS leader_id UUID REFERENCES leaders(id);
ALTER TABLE rounds ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();

COMMENT ON TABLE rounds IS '团购轮次表，每次团购为一个轮次';
COMMENT ON COLUMN rounds.is_active IS '是否为活跃轮次，允许多轮次同时 active';

-- 为 orders 表增加轮次关联（如果列不存在）
DO $$ BEGIN
  ALTER TABLE orders ADD COLUMN round_id UUID REFERENCES rounds(id);
EXCEPTION WHEN duplicate_column THEN NULL;
END $$;

CREATE INDEX IF NOT EXISTS idx_orders_round ON orders (round_id);

-- ============================================================================
-- Row Level Security (RLS) 策略
-- ============================================================================

-- 启用 RLS
ALTER TABLE products ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE rounds ENABLE ROW LEVEL SECURITY;

-- --- 删除已有策略（确保可重复执行）---
DROP POLICY IF EXISTS "Anyone can read active products" ON products;
DROP POLICY IF EXISTS "Allow all read products" ON products;
DROP POLICY IF EXISTS "Allow read all products" ON products;
DROP POLICY IF EXISTS "Allow insert products" ON products;
DROP POLICY IF EXISTS "Allow update products" ON products;
DROP POLICY IF EXISTS "Allow delete products" ON products;
DROP POLICY IF EXISTS "Anyone can read orders" ON orders;
DROP POLICY IF EXISTS "Anyone can insert orders" ON orders;
DROP POLICY IF EXISTS "Anyone can update orders" ON orders;
DROP POLICY IF EXISTS "Anyone can read settings" ON settings;
DROP POLICY IF EXISTS "Allow update settings" ON settings;
DROP POLICY IF EXISTS "Allow insert settings" ON settings;

-- --- Products 策略 ---
CREATE POLICY "Anyone can read active products"
  ON products FOR SELECT
  USING (is_active = true);

-- orders 不创建公开读写策略；顾客查询和管理员查看都通过 RPC。

-- --- Rounds 策略 ---
DROP POLICY IF EXISTS "Anyone can read rounds" ON rounds;
DROP POLICY IF EXISTS "Allow insert rounds" ON rounds;
DROP POLICY IF EXISTS "Allow update rounds" ON rounds;
DROP POLICY IF EXISTS "Allow delete rounds" ON rounds;

CREATE POLICY "Anyone can read rounds"
  ON rounds FOR SELECT
  USING (true);

-- settings 不创建公开策略；通过 RPC 读取必要状态、修改管理员配置。

-- ============================================================================
-- 索引
-- ============================================================================
CREATE INDEX IF NOT EXISTS idx_products_active ON products (is_active);
CREATE INDEX IF NOT EXISTS idx_products_round ON products (round_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders (status);
CREATE INDEX IF NOT EXISTS idx_orders_customer ON orders (customer_name);
CREATE INDEX IF NOT EXISTS idx_orders_created ON orders (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_rounds_active ON rounds (is_active);

-- ============================================================================
-- 自动更新 updated_at 触发器
-- ============================================================================
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_orders_updated_at ON orders;
CREATE TRIGGER trg_orders_updated_at
  BEFORE UPDATE ON orders
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at();

-- ============================================================================
-- 原子库存操作函数（防止并发超卖）
-- ============================================================================
CREATE OR REPLACE FUNCTION deduct_stock(p_id UUID, qty NUMERIC)
RETURNS BOOLEAN AS $$
  WITH updated AS (
  UPDATE products
     SET stock = stock - qty
   WHERE id = p_id
     AND stock IS NOT NULL
     AND stock >= qty
     AND is_active = true
   RETURNING 1
  )
  SELECT EXISTS(SELECT 1 FROM updated);
$$ LANGUAGE sql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION restore_stock(p_id UUID, qty NUMERIC)
RETURNS VOID AS $$
  UPDATE products SET stock = stock + qty
   WHERE id = p_id AND stock IS NOT NULL;
$$ LANGUAGE sql SECURITY DEFINER;

-- ============================================================================
-- 管理员认证（服务端 session token）
-- ============================================================================
CREATE TABLE IF NOT EXISTS admin_sessions (
  token TEXT PRIMARY KEY,
  expires_at TIMESTAMPTZ NOT NULL
);

COMMENT ON TABLE admin_sessions IS '管理员会话表，token 为登录凭证';

ALTER TABLE admin_sessions ADD COLUMN IF NOT EXISTS leader_id UUID REFERENCES leaders(id);

-- RLS 启用但不创建任何策略 → 普通客户端无法直接读写
-- 只能通过下面的 SECURITY DEFINER 函数操作
ALTER TABLE admin_sessions ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_sessions_expires ON admin_sessions (expires_at);

-- 登录验证 + 生成 session token
DROP FUNCTION IF EXISTS admin_login(TEXT);
CREATE OR REPLACE FUNCTION admin_login(p_username TEXT, p_password_hash TEXT)
RETURNS JSONB AS $$
DECLARE
  v_leader leaders%ROWTYPE;
  v_token TEXT;
BEGIN
  -- 兼容迁移：如果 leaders 表为空，使用旧 settings.admin_password 校验并自动创建超管
  IF NOT EXISTS (SELECT 1 FROM leaders LIMIT 1) THEN
    IF EXISTS (SELECT 1 FROM settings WHERE key = 'admin_password' AND value = p_password_hash) THEN
      INSERT INTO leaders (username, password_hash, role)
      VALUES (p_username, p_password_hash, 'super_admin') RETURNING * INTO v_leader;
    ELSE
      RETURN jsonb_build_object('error', '系统未初始化，请使用旧密码登录完成迁移');
    END IF;
  ELSE
    SELECT * INTO v_leader FROM leaders
    WHERE username = p_username AND password_hash = p_password_hash;
    IF v_leader.id IS NULL THEN
      RETURN jsonb_build_object('error', '用户名或密码错误');
    END IF;
  END IF;

  v_token := encode(gen_random_bytes(32), 'hex');
  INSERT INTO admin_sessions (token, expires_at, leader_id)
  VALUES (v_token, now() + INTERVAL '24 hours', v_leader.id);

  RETURN jsonb_build_object(
    'token', v_token,
    'role', v_leader.role,
    'username', v_leader.username,
    'leader_id', v_leader.id
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 验证 session token 是否有效
CREATE OR REPLACE FUNCTION validate_session(p_token TEXT)
RETURNS BOOLEAN AS $$
  SELECT EXISTS(
    SELECT 1 FROM admin_sessions
    WHERE token = p_token AND expires_at > now()
  );
$$ LANGUAGE sql SECURITY DEFINER;

-- 清除 session（退出登录）
CREATE OR REPLACE FUNCTION clear_session(p_token TEXT)
RETURNS VOID AS $$
  DELETE FROM admin_sessions WHERE token = p_token;
$$ LANGUAGE sql SECURITY DEFINER;

-- 自动清理过期 session
CREATE OR REPLACE FUNCTION cleanup_sessions()
RETURNS VOID AS $$
  DELETE FROM admin_sessions WHERE expires_at < now();
$$ LANGUAGE sql SECURITY DEFINER;

DROP FUNCTION IF EXISTS require_admin(TEXT);
CREATE OR REPLACE FUNCTION require_admin(p_token TEXT)
RETURNS TABLE(leader_id UUID, role TEXT) AS $$
BEGIN
  SELECT s.leader_id, l.role INTO require_admin.leader_id, require_admin.role
  FROM admin_sessions s
  JOIN leaders l ON l.id = s.leader_id
  WHERE s.token = p_token AND s.expires_at > now();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid admin session';
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION check_round_owner(p_leader_id UUID, p_role TEXT, p_round_id UUID)
RETURNS VOID AS $$
DECLARE
  v_owner_id UUID;
BEGIN
  IF p_role = 'super_admin' THEN RETURN; END IF;
  SELECT leader_id INTO v_owner_id FROM rounds WHERE id = p_round_id;
  IF v_owner_id IS NOT NULL AND v_owner_id <> p_leader_id THEN
    RAISE EXCEPTION 'permission denied: you are not the owner of this round';
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION check_super_admin(p_role TEXT)
RETURNS VOID AS $$
BEGIN
  IF p_role <> 'super_admin' THEN
    RAISE EXCEPTION 'permission denied: super admin only';
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_create_leader(p_token TEXT, p_username TEXT, p_password_hash TEXT, p_plain_password TEXT)
RETURNS UUID AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
  v_new_id UUID;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  PERFORM check_super_admin(v_role);
  INSERT INTO leaders (username, password_hash, password_plain) VALUES (p_username, p_password_hash, p_plain_password) RETURNING id INTO v_new_id;
  RETURN v_new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_delete_leader(p_token TEXT, p_leader_id UUID)
RETURNS BOOLEAN AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  PERFORM check_super_admin(v_role);
  -- 先解除该团长关联的所有轮次
  UPDATE rounds SET leader_id = NULL WHERE leader_id = p_leader_id;
  DELETE FROM leaders WHERE id = p_leader_id AND role <> 'super_admin';
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP FUNCTION IF EXISTS admin_list_leaders(TEXT);
CREATE OR REPLACE FUNCTION admin_list_leaders(p_token TEXT)
RETURNS TABLE(id UUID, username TEXT, role TEXT, password_plain TEXT, created_at TIMESTAMPTZ) AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  PERFORM check_super_admin(v_role);
  RETURN QUERY SELECT l.id, l.username, l.role, l.password_plain, l.created_at FROM leaders l ORDER BY l.created_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_reset_leader_password(p_token TEXT, p_leader_id UUID, p_password_hash TEXT, p_plain_password TEXT)
RETURNS BOOLEAN AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  PERFORM check_super_admin(v_role);
  UPDATE leaders SET password_hash = p_password_hash, password_plain = p_plain_password WHERE id = p_leader_id;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION register_leader(p_username TEXT, p_password_hash TEXT, p_plain_password TEXT)
RETURNS UUID AS $$
DECLARE
  v_new_id UUID;
BEGIN
  IF EXISTS (SELECT 1 FROM leaders WHERE username = p_username) THEN
    RAISE EXCEPTION 'username already exists';
  END IF;
  INSERT INTO leaders (username, password_hash, password_plain) VALUES (p_username, p_password_hash, p_plain_password) RETURNING id INTO v_new_id;
  RETURN v_new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_transfer_round(p_token TEXT, p_round_id UUID, p_leader_id UUID)
RETURNS BOOLEAN AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  PERFORM check_super_admin(v_role);
  UPDATE rounds SET leader_id = p_leader_id WHERE id = p_round_id;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION needs_admin_password()
RETURNS BOOLEAN AS $$
  SELECT NOT EXISTS (
    SELECT 1 FROM settings
    WHERE key = 'admin_password' AND value <> ''
  );
$$ LANGUAGE sql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION get_group_names()
RETURNS TEXT AS $$
  SELECT COALESCE((SELECT value FROM settings WHERE key = 'group_names'), '山姆群,美食群');
$$ LANGUAGE sql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION get_site_title()
RETURNS TEXT AS $$
  SELECT COALESCE((SELECT value FROM settings WHERE key = 'site_title'), '美好小区团购群');
$$ LANGUAGE sql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_get_products(p_token TEXT, p_round_id UUID DEFAULT NULL)
RETURNS SETOF products AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  RETURN QUERY SELECT * FROM products
    WHERE (p_round_id IS NULL OR round_id = p_round_id)
    ORDER BY created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_get_product(p_token TEXT, p_id UUID)
RETURNS products AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
  row products;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  SELECT * INTO row FROM products WHERE id = p_id;
  RETURN row;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_get_orders(p_token TEXT, p_round_id UUID)
RETURNS SETOF orders AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  RETURN QUERY
    SELECT * FROM orders
     WHERE status IN ('active', 'pending_weight')
       AND (p_round_id IS NULL OR round_id = p_round_id)
     ORDER BY created_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION lookup_orders(p_customer_name TEXT, p_round_id UUID)
RETURNS SETOF orders AS $$
BEGIN
  RETURN QUERY
    SELECT * FROM orders
     WHERE (p_customer_name IS NULL OR customer_name = p_customer_name)
       AND (p_round_id IS NULL OR round_id = p_round_id)
     ORDER BY created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 公开：返回某轮次各商品的汇总数量（用于前端显示"已拼满/未拼满"）
CREATE OR REPLACE FUNCTION get_round_order_stats(p_round_id UUID)
RETURNS JSONB AS $$
SELECT COALESCE(jsonb_agg(s), '[]'::jsonb) FROM (
  SELECT it->>'product_id' as product_id,
    SUM(COALESCE((it->>'purchase_qty')::numeric, (it->>'quantity')::numeric, 0)) as qty,
    SUM(COALESCE((it->>'share')::numeric, null)) as share_total,
    COUNT(*)::int as order_count
  FROM orders o, jsonb_array_elements(COALESCE(o.items, '[]'::jsonb)) it
  WHERE o.round_id = p_round_id AND o.status IN ('active', 'pending_weight')
    AND (it->>'deleted') IS DISTINCT FROM 'true'
    AND (it->>'product_id') IS NOT NULL
  GROUP BY it->>'product_id'
) s;
$$ LANGUAGE sql SECURITY DEFINER;

-- 清理旧版本避免重载冲突
DROP FUNCTION IF EXISTS admin_save_product(p_token TEXT, p_id UUID, p_name TEXT, p_image TEXT, p_specs JSONB, p_tags JSONB, p_stock NUMERIC, p_is_active BOOLEAN);
DROP FUNCTION IF EXISTS admin_save_product(p_token TEXT, p_id UUID, p_name TEXT, p_image TEXT, p_specs JSONB, p_tags JSONB, p_stock NUMERIC, p_is_active BOOLEAN, p_round_id UUID);
DROP FUNCTION IF EXISTS admin_save_product(p_token TEXT, p_id UUID, p_name TEXT, p_image TEXT, p_specs JSONB, p_tags JSONB, p_stock NUMERIC, p_is_active BOOLEAN, p_round_id UUID, p_is_weighted BOOLEAN);
CREATE OR REPLACE FUNCTION admin_save_product(
  p_token TEXT,
  p_id UUID,
  p_name TEXT,
  p_image TEXT,
  p_specs JSONB,
  p_tags JSONB,
  p_stock NUMERIC,
  p_is_active BOOLEAN,
  p_round_id UUID DEFAULT NULL,
  p_is_weighted BOOLEAN DEFAULT false,
  p_weight_estimate TEXT DEFAULT NULL,
  p_weight_unit TEXT DEFAULT 'kg'
)
RETURNS UUID AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
  new_id UUID;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  PERFORM check_round_owner(v_leader_id, v_role, p_round_id);
  -- 服务端校验
  IF p_stock IS NOT NULL AND p_stock < 0 THEN
    RAISE EXCEPTION 'stock cannot be negative';
  END IF;
  IF p_specs IS NULL OR jsonb_array_length(p_specs) = 0 THEN
    RAISE EXCEPTION 'specs cannot be empty';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_specs) AS s WHERE (s->>'price')::numeric <= 0 OR (s->>'name') IS NULL OR trim(s->>'name') = '') THEN
    RAISE EXCEPTION 'each spec must have a name and a positive price';
  END IF;
  IF p_id IS NULL THEN
    INSERT INTO products (name, image, specs, tags, stock, is_active, round_id, is_weighted, weight_estimate, weight_unit)
    VALUES (p_name, p_image, COALESCE(p_specs, '[]'::jsonb), COALESCE(p_tags, '[]'::jsonb), p_stock, COALESCE(p_is_active, true), p_round_id, COALESCE(p_is_weighted, false), NULLIF(p_weight_estimate, ''), COALESCE(p_weight_unit, 'kg'))
    RETURNING id INTO new_id;
  ELSE
    UPDATE products
       SET name = p_name,
           image = p_image,
           specs = COALESCE(p_specs, '[]'::jsonb),
           tags = COALESCE(p_tags, '[]'::jsonb),
           stock = p_stock,
           is_active = COALESCE(p_is_active, true),
           round_id = COALESCE(p_round_id, round_id),
           is_weighted = COALESCE(p_is_weighted, false),
           weight_estimate = NULLIF(p_weight_estimate, ''),
           weight_unit = COALESCE(p_weight_unit, 'kg')
     WHERE id = p_id
    RETURNING id INTO new_id;
  END IF;
  RETURN new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_toggle_product(p_token TEXT, p_id UUID, p_is_active BOOLEAN)
RETURNS VOID AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  PERFORM check_round_owner(v_leader_id, v_role, (SELECT round_id FROM products WHERE id = p_id));
  UPDATE products SET is_active = p_is_active WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_delete_product(p_token TEXT, p_id UUID)
RETURNS VOID AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
  active_round_id UUID;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  PERFORM check_round_owner(v_leader_id, v_role, (SELECT round_id FROM products WHERE id = p_id));
  -- 解散该商品上所有活跃队伍（归还库存）
  PERFORM cancel_team(t.id) FROM teams t WHERE t.product_id = p_id AND t.status = 'active';
  -- 标记所有活动订单中该商品的记录为已删除（跨所有轮次）
  WITH rebuilt AS (
    SELECT
      o.id,
      jsonb_agg(
        CASE
          WHEN item->>'product_id' = p_id::text THEN
            item
            || jsonb_build_object(
              'product_name', '商品已删除',
              'spec_price', 0,
              'subtotal', 0,
              'purchase_qty', 0,
              'deleted', true
            )
          ELSE item
        END
      ) AS new_items,
      COALESCE(
        SUM(
          CASE
            WHEN item->>'product_id' <> p_id::text
            THEN COALESCE((item->>'subtotal')::numeric, 0)
            ELSE 0
          END
        ),
        0
      ) AS new_total
    FROM orders o
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(o.items, '[]'::jsonb)) AS item
    WHERE o.status IN ('active', 'pending_weight')
      AND EXISTS (
        SELECT 1
          FROM jsonb_array_elements(COALESCE(o.items, '[]'::jsonb)) AS existing_item
         WHERE existing_item->>'product_id' = p_id::text
      )
    GROUP BY o.id
  )
  UPDATE orders o
     SET items = rebuilt.new_items,
         total_amount = ROUND(rebuilt.new_total, 2),
         updated_at = now()
    FROM rebuilt
   WHERE o.id = rebuilt.id;

  DELETE FROM products WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION mark_missing_order_products_deleted()
RETURNS VOID AS $$
BEGIN
  WITH rebuilt AS (
    SELECT
      o.id,
      jsonb_agg(
        CASE
          WHEN COALESCE(item.value->>'product_id', item.value->>'productId') IS NOT NULL
            AND item.value->>'deleted' IS DISTINCT FROM 'true'
            AND NOT EXISTS (
              SELECT 1 FROM products p WHERE p.id::text = COALESCE(item.value->>'product_id', item.value->>'productId')
            )
          THEN
            item.value
            || jsonb_build_object(
              'product_name', '商品已删除',
              'spec_price', 0,
              'subtotal', 0,
              'purchase_qty', 0,
              'deleted', true
            )
          ELSE item.value
        END
        ORDER BY item.ordinality
      ) AS new_items,
      COALESCE(
        SUM(
          CASE
            WHEN item.value->>'deleted' = 'true'
              OR (
                COALESCE(item.value->>'product_id', item.value->>'productId') IS NOT NULL
                AND NOT EXISTS (
                  SELECT 1 FROM products p WHERE p.id::text = COALESCE(item.value->>'product_id', item.value->>'productId')
                )
              )
            THEN 0
            ELSE COALESCE((item.value->>'subtotal')::numeric, 0)
          END
        ),
        0
      ) AS new_total,
      BOOL_OR(
        COALESCE(item.value->>'product_id', item.value->>'productId') IS NOT NULL
        AND item.value->>'deleted' IS DISTINCT FROM 'true'
        AND NOT EXISTS (
          SELECT 1 FROM products p WHERE p.id::text = COALESCE(item.value->>'product_id', item.value->>'productId')
        )
      ) AS has_missing_product,
      BOOL_OR(item.value->>'deleted' = 'true') AS has_deleted_product
    FROM orders o
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(o.items, '[]'::jsonb)) WITH ORDINALITY AS item(value, ordinality)
    WHERE o.status IN ('active', 'pending_weight')
    GROUP BY o.id
  )
  UPDATE orders o
     SET items = rebuilt.new_items,
         total_amount = ROUND(rebuilt.new_total, 2),
         updated_at = now()
    FROM rebuilt
   WHERE o.id = rebuilt.id
     AND (rebuilt.has_missing_product OR rebuilt.has_deleted_product);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

SELECT mark_missing_order_products_deleted();

CREATE OR REPLACE FUNCTION admin_set_password(p_token TEXT, p_pw_hash TEXT)
RETURNS VOID AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  PERFORM check_super_admin(v_role);
  UPDATE settings SET value = p_pw_hash WHERE key = 'admin_password';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_set_group_names(p_token TEXT, p_names TEXT)
RETURNS VOID AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  PERFORM check_super_admin(v_role);
  INSERT INTO settings (key, value) VALUES ('group_names', p_names)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_set_site_title(p_token TEXT, p_title TEXT)
RETURNS VOID AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  PERFORM check_super_admin(v_role);
  INSERT INTO settings (key, value)
  VALUES ('site_title', NULLIF(TRIM(p_title), ''))
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_get_round_fee_map(p_token TEXT)
RETURNS JSONB AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
  raw_value TEXT;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  SELECT value INTO raw_value FROM settings WHERE key = 'round_fees';
  RETURN COALESCE(raw_value, '{}')::jsonb;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_save_round_fees(p_token TEXT, p_round_id UUID, p_fees JSONB)
RETURNS VOID AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
  fee_map JSONB;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  PERFORM check_round_owner(v_leader_id, v_role, p_round_id);
  SELECT COALESCE(value, '{}')::jsonb INTO fee_map FROM settings WHERE key = 'round_fees';
  UPDATE settings
     SET value = jsonb_set(COALESCE(fee_map, '{}'::jsonb), ARRAY[p_round_id::text], COALESCE(p_fees, '{}'::jsonb), true)::text
   WHERE key = 'round_fees';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_create_round(p_token TEXT, p_name TEXT, p_cutoff_time TIMESTAMPTZ, p_leader_name TEXT DEFAULT NULL)
RETURNS UUID AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
  new_id UUID;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  INSERT INTO rounds (name, cutoff_time, is_active, leader_name, leader_id)
  VALUES (p_name, p_cutoff_time, false, NULLIF(p_leader_name, ''), v_leader_id)
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_update_round(p_token TEXT, p_id UUID, p_name TEXT, p_cutoff_time TIMESTAMPTZ, p_leader_name TEXT DEFAULT NULL)
RETURNS VOID AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  PERFORM check_round_owner(v_leader_id, v_role, p_id);
  UPDATE rounds SET name = p_name, cutoff_time = p_cutoff_time, leader_name = NULLIF(p_leader_name, '') WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_activate_round(p_token TEXT, p_id UUID)
RETURNS VOID AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  PERFORM check_round_owner(v_leader_id, v_role, p_id);
  UPDATE rounds SET is_active = true WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 管理员砍单（不受截止时间限制，支持备注砍单原因）
CREATE OR REPLACE FUNCTION admin_cancel_order(p_token TEXT, p_order_id UUID, p_note TEXT DEFAULT NULL)
RETURNS BOOLEAN AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
  order_row orders;
  item JSONB;
  qty NUMERIC;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  PERFORM check_round_owner(v_leader_id, v_role, (SELECT round_id FROM orders WHERE id = p_order_id));
  SELECT * INTO order_row FROM orders WHERE id = p_order_id AND status IN ('active', 'pending_weight') FOR UPDATE;
  IF order_row.id IS NULL THEN RETURN false; END IF;
  UPDATE orders SET
    status = 'cancelled',
    note = CASE
      WHEN p_note IS NOT NULL AND p_note <> '' THEN
        CASE WHEN COALESCE(note, '') <> '' THEN note || ' | ' || p_note ELSE p_note END
      ELSE note
    END
  WHERE id = p_order_id;
  FOR item IN SELECT * FROM jsonb_array_elements(COALESCE(order_row.items, '[]'::jsonb))
  LOOP
    qty := COALESCE((item->>'purchase_qty')::numeric, (item->>'quantity')::numeric, 0);
    IF qty > 0 THEN
      UPDATE products SET stock = stock + qty
       WHERE id = (item->>'product_id')::uuid AND stock IS NOT NULL;
    END IF;
  END LOOP;
  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_stop_round(p_token TEXT, p_id UUID)
RETURNS VOID AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  PERFORM check_round_owner(v_leader_id, v_role, p_id);
  UPDATE rounds SET is_active = false, cutoff_time = now() WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_delete_round(p_token TEXT, p_id UUID)
RETURNS VOID AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  PERFORM check_round_owner(v_leader_id, v_role, p_id);
  IF EXISTS (SELECT 1 FROM rounds WHERE id = p_id AND is_active = true AND (cutoff_time IS NULL OR cutoff_time > now())) THEN
    RAISE EXCEPTION 'cannot delete active round';
  END IF;
  DELETE FROM orders WHERE round_id = p_id;
  DELETE FROM products WHERE round_id = p_id;
  DELETE FROM rounds WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP FUNCTION IF EXISTS create_order(TEXT, JSONB, TEXT, NUMERIC, UUID);
CREATE OR REPLACE FUNCTION create_order(
  p_customer_name TEXT,
  p_items JSONB,
  p_note TEXT,
  p_total_amount NUMERIC,
  p_round_id UUID,
  p_created_at TIMESTAMPTZ DEFAULT NULL,
  p_customer_group TEXT DEFAULT ''
)
RETURNS UUID AS $$
DECLARE
  item JSONB;
  checked_items JSONB := '[]'::jsonb;
  product_row products;
  spec_row JSONB;
  product_id UUID;
  qty NUMERIC;
  count_qty NUMERIC;
  unit_qty NUMERIC;
  price NUMERIC;
  line_total NUMERIC;
  server_total NUMERIC := 0;
  new_id UUID;
  round_row rounds;
BEGIN
  SELECT * INTO round_row FROM rounds WHERE id = p_round_id AND is_active = true;
  IF round_row.id IS NULL THEN
    RAISE EXCEPTION 'round is not active';
  END IF;
  IF round_row.cutoff_time IS NOT NULL AND round_row.cutoff_time <= now() THEN
    RAISE EXCEPTION 'round is closed';
  END IF;

  -- 幂等保护：同一顾客 5 秒内在同一轮次重复提交视为重放
  -- 互斥规则已移除：允许同一顾客在同一商品有活跃队伍的同时独立下单

  IF EXISTS (
    SELECT 1 FROM orders
    WHERE customer_name = p_customer_name
      AND round_id = p_round_id
      AND status IN ('active', 'pending_weight')
      AND note IS NOT DISTINCT FROM p_note
      AND created_at > now() - INTERVAL '5 seconds'
  ) THEN
    RAISE EXCEPTION 'duplicate order within 5s, please wait';
  END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb))
  LOOP
    product_id := (item->>'product_id')::uuid;
    SELECT * INTO product_row FROM products WHERE id = product_id AND round_id = p_round_id AND is_active = true FOR UPDATE;
    IF product_row.id IS NULL THEN
      RAISE EXCEPTION 'product is not in this round or not active';
    END IF;
    SELECT spec.value INTO spec_row
      FROM jsonb_array_elements(product_row.specs) AS spec(value)
     WHERE spec.value->>'name' = item->>'spec_name'
     LIMIT 1;
    IF spec_row IS NULL THEN
      RAISE EXCEPTION 'invalid product spec';
    END IF;

    count_qty := COALESCE((item->>'quantity')::numeric, 0);
    IF count_qty <= 0 THEN
      RAISE EXCEPTION 'invalid quantity';
    END IF;
    unit_qty := COALESCE((item->>'unit_qty')::numeric, 1);
    qty := COALESCE((item->>'purchase_qty')::numeric, unit_qty * count_qty);
    price := (spec_row->>'price')::numeric;
    line_total := ROUND(price * count_qty, 2);

    IF qty > 0 AND product_row.is_weighted IS NOT TRUE THEN
      UPDATE products
         SET stock = stock - qty
       WHERE id = product_id
         AND is_active = true
         AND stock IS NOT NULL
         AND stock >= qty;
      IF NOT FOUND AND EXISTS (SELECT 1 FROM products WHERE id = product_id AND stock IS NOT NULL) THEN
        RAISE EXCEPTION 'insufficient stock';
      END IF;
    END IF;

    checked_items := checked_items || jsonb_build_array(jsonb_build_object(
      'product_id', product_row.id,
      'product_name', product_row.name,
      'spec_name', spec_row->>'name',
      'spec_price', price,
      'quantity', count_qty,
      'unit_qty', unit_qty,
      'purchase_qty', qty,
      'subtotal', line_total,
      'share', COALESCE((item->>'share')::numeric, null),
      '_orig_time', item->>'_orig_time'
    ));
    server_total := server_total + line_total;
  END LOOP;

  INSERT INTO orders (customer_name, items, note, total_amount, status, round_id, created_at, customer_group)
  VALUES (p_customer_name, checked_items, COALESCE(p_note, ''), ROUND(server_total, 2),
    CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(checked_items) AS ci WHERE EXISTS (SELECT 1 FROM products WHERE id = (ci->>'product_id')::uuid AND is_weighted = true))
      THEN 'pending_weight' ELSE 'active' END,
    p_round_id,
    COALESCE(p_created_at, now()),
    NULLIF(p_customer_group, ''))
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 称重商品确认：录入实际重量后确认订单
CREATE OR REPLACE FUNCTION admin_confirm_order_weight(p_token TEXT, p_order_id UUID, p_weights JSONB)
RETURNS BOOLEAN AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
  order_row orders;
  item JSONB;
  new_items JSONB := '[]'::jsonb;
  new_total NUMERIC := 0;
  product_row products;
  actual_weight NUMERIC;
  share_pct NUMERIC;
  new_subtotal NUMERIC;
  spec_price NUMERIC;
  product_id UUID;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  PERFORM check_round_owner(v_leader_id, v_role, (SELECT round_id FROM orders WHERE id = p_order_id));
  SELECT * INTO order_row FROM orders WHERE id = p_order_id AND status = 'pending_weight' FOR UPDATE;
  IF order_row.id IS NULL THEN RETURN false; END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(COALESCE(order_row.items, '[]'::jsonb))
  LOOP
    product_id := (item->>'product_id')::uuid;
    SELECT * INTO product_row FROM products WHERE id = product_id;
    spec_price := (item->>'spec_price')::numeric;
    share_pct := COALESCE((item->>'share')::numeric, 1);

    IF product_row.is_weighted = true AND p_weights ? product_id::text THEN
      actual_weight := (p_weights->>product_id::text)::numeric;
      new_subtotal := ROUND(spec_price * actual_weight * share_pct, 2);
      new_items := new_items || jsonb_build_array(item || jsonb_build_object(
        'subtotal', new_subtotal,
        'actual_weight', actual_weight
      ));
      new_total := new_total + new_subtotal;
    ELSE
      new_items := new_items || jsonb_build_array(item);
      new_total := new_total + COALESCE((item->>'subtotal')::numeric, 0);
    END IF;
  END LOOP;

  UPDATE orders SET items = new_items, total_amount = ROUND(new_total, 2), status = 'active' WHERE id = p_order_id;
  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION cancel_order(p_order_id UUID, p_customer_name TEXT)
RETURNS BOOLEAN AS $$
DECLARE
  order_row orders;
  round_row rounds;
  item JSONB;
  qty NUMERIC;
BEGIN
  SELECT * INTO order_row
    FROM orders
   WHERE id = p_order_id
     AND customer_name = p_customer_name
     AND status = 'active'
   FOR UPDATE;
  IF order_row.id IS NULL THEN
    RETURN false;
  END IF;

  IF order_row.round_id IS NOT NULL THEN
    SELECT * INTO round_row FROM rounds WHERE id = order_row.round_id;
    IF round_row.cutoff_time IS NOT NULL AND round_row.cutoff_time <= now() THEN
      RAISE EXCEPTION 'round is closed';
    END IF;
  END IF;

  UPDATE orders SET status = 'cancelled' WHERE id = p_order_id;

  FOR item IN SELECT * FROM jsonb_array_elements(COALESCE(order_row.items, '[]'::jsonb))
  LOOP
    qty := COALESCE((item->>'purchase_qty')::numeric, (item->>'quantity')::numeric, 0);
    IF qty > 0 THEN
      UPDATE products SET stock = stock + qty
       WHERE id = (item->>'product_id')::uuid AND stock IS NOT NULL;
    END IF;
  END LOOP;
  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION deduct_stock(UUID, NUMERIC) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION restore_stock(UUID, NUMERIC) FROM PUBLIC, anon, authenticated;

-- 5. 用户反馈表
CREATE TABLE IF NOT EXISTS feedback (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_name TEXT NOT NULL,
  content TEXT NOT NULL,
  image_url TEXT,
  round_id UUID REFERENCES rounds(id),
  status TEXT NOT NULL DEFAULT 'unread' CHECK (status IN ('unread', 'read')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE feedback ADD COLUMN IF NOT EXISTS customer_name TEXT;
ALTER TABLE feedback ADD COLUMN IF NOT EXISTS content TEXT;
ALTER TABLE feedback ADD COLUMN IF NOT EXISTS image_url TEXT;
ALTER TABLE feedback ADD COLUMN IF NOT EXISTS round_id UUID REFERENCES rounds(id);
ALTER TABLE feedback ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'unread';
ALTER TABLE feedback ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();

ALTER TABLE feedback ENABLE ROW LEVEL SECURITY;

-- 售后反馈表
CREATE TABLE IF NOT EXISTS after_sales (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_name TEXT NOT NULL,
  round_id UUID REFERENCES rounds(id),
  items JSONB NOT NULL DEFAULT '[]'::jsonb,
  reason TEXT DEFAULT '',
  image_url TEXT,
  status TEXT NOT NULL DEFAULT 'unread' CHECK (status IN ('unread', 'read', 'resolved')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE after_sales ADD COLUMN IF NOT EXISTS customer_name TEXT;
ALTER TABLE after_sales ADD COLUMN IF NOT EXISTS round_id UUID;
ALTER TABLE after_sales ADD COLUMN IF NOT EXISTS items JSONB NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE after_sales ADD COLUMN IF NOT EXISTS reason TEXT DEFAULT '';
ALTER TABLE after_sales ADD COLUMN IF NOT EXISTS image_url TEXT;
ALTER TABLE after_sales ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'unread';
ALTER TABLE after_sales ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();

ALTER TABLE after_sales ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Anyone can insert after_sales" ON after_sales;
DROP POLICY IF EXISTS "Anyone can insert after_sales" ON after_sales;
CREATE POLICY "Anyone can insert after_sales" ON after_sales FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS "Anyone can read own after_sales" ON after_sales;
CREATE POLICY "Anyone can read own after_sales" ON after_sales FOR SELECT USING (true);

-- 售后查询/状态更新
CREATE OR REPLACE FUNCTION admin_get_after_sales(p_token TEXT, p_round_id UUID DEFAULT NULL)
RETURNS SETOF after_sales AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  RETURN QUERY SELECT * FROM after_sales
    WHERE (p_round_id IS NULL OR round_id = p_round_id)
    ORDER BY created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_update_after_sales_status(p_token TEXT, p_id UUID, p_status TEXT)
RETURNS VOID AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  PERFORM check_round_owner(v_leader_id, v_role, (SELECT round_id FROM after_sales WHERE id = p_id));
  UPDATE after_sales SET status = p_status WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
DROP POLICY IF EXISTS "Anyone can insert feedback" ON feedback;
CREATE POLICY "Anyone can insert feedback" ON feedback FOR INSERT WITH CHECK (true);

-- 管理员查看
CREATE OR REPLACE FUNCTION admin_get_feedback(p_token TEXT)
RETURNS SETOF feedback AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  RETURN QUERY SELECT * FROM feedback ORDER BY created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 标记已读
CREATE OR REPLACE FUNCTION admin_mark_feedback_read(p_token TEXT, p_id UUID)
RETURNS VOID AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  PERFORM check_round_owner(v_leader_id, v_role, (SELECT round_id FROM feedback WHERE id = p_id));
  UPDATE feedback SET status = 'read' WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- Storage Bucket: 商品图片存储
-- ============================================================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('product-images', 'product-images', true, 5242880, ARRAY['image/jpeg','image/png','image/gif','image/webp'])
ON CONFLICT (id) DO UPDATE SET public = true;

DROP POLICY IF EXISTS "Anyone can view product images" ON storage.objects;
CREATE POLICY "Anyone can view product images"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'product-images');

DROP POLICY IF EXISTS "Anyone can upload product images" ON storage.objects;
CREATE POLICY "Anyone can upload product images"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'product-images'
    AND (storage.foldername(name))[1] = 'products'
  );

-- ============================================================================
-- 获取已取消订单（用于展示砍单记录等）
-- ============================================================================
CREATE OR REPLACE FUNCTION admin_get_cancelled_orders(p_token TEXT, p_round_id UUID)
RETURNS SETOF orders AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  RETURN QUERY
    SELECT * FROM orders
     WHERE status = 'cancelled'
       AND round_id = p_round_id
     ORDER BY updated_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- 原子砍单：在原订单上直接移除/减少商品项，更新金额
-- ============================================================================
CREATE OR REPLACE FUNCTION admin_remove_order_items(
  p_token TEXT,
  p_customer_name TEXT,
  p_round_id UUID,
  p_items_to_cancel JSONB,
  p_note TEXT DEFAULT ''
)
RETURNS INTEGER AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
  order_row orders;
  cancel_item JSONB;
  new_items JSONB;
  new_total NUMERIC;
  item_count INT := 0;
  affected_orders INTEGER := 0;
  item_rec JSONB;
  cancel_product_id TEXT;
  cancel_spec_name TEXT;
  cancel_qty NUMERIC;
  orig_qty NUMERIC;
  orig_subtotal NUMERIC;
  orig_price NUMERIC;
  remaining_qty NUMERIC;
  ratio NUMERIC;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  PERFORM check_round_owner(v_leader_id, v_role, p_round_id);

  -- 遍历该顾客的活跃订单
  FOR order_row IN
    SELECT * FROM orders
    WHERE customer_name = p_customer_name
      AND round_id = p_round_id
      AND status IN ('active', 'pending_weight')
    ORDER BY created_at
    FOR UPDATE
  LOOP
    new_items := '[]'::jsonb;
    new_total := 0;
    item_count := 0;

    FOR item_rec IN SELECT * FROM jsonb_array_elements(COALESCE(order_row.items, '[]'::jsonb))
    LOOP
      IF (item_rec->>'deleted') = 'true' THEN
        new_items := new_items || item_rec;
        CONTINUE;
      END IF;

      -- 检查是否需要从该商品中扣减
      cancel_qty := 0;
      FOR cancel_item IN SELECT * FROM jsonb_array_elements(p_items_to_cancel)
      LOOP
        IF (cancel_item->>'product_id') = (item_rec->>'product_id')
           AND (cancel_item->>'spec_name') = (item_rec->>'spec_name') THEN
          cancel_qty := COALESCE((cancel_item->>'cancel_qty')::numeric, 0);
          EXIT;
        END IF;
      END LOOP;

      IF cancel_qty <= 0 THEN
        -- 不砍该商品，保留原样
        new_items := new_items || item_rec;
        new_total := new_total + COALESCE((item_rec->>'subtotal')::numeric, 0);
        CONTINUE;
      END IF;

      orig_qty := COALESCE((item_rec->>'quantity')::numeric, 0);
      orig_subtotal := COALESCE((item_rec->>'subtotal')::numeric, 0);
      orig_price := COALESCE((item_rec->>'spec_price')::numeric, 0);

      remaining_qty := GREATEST(orig_qty - cancel_qty, 0);

      IF remaining_qty <= 0 THEN
        -- 全部取消：标记为 deleted
        new_items := new_items || (item_rec || jsonb_build_object(
          'quantity', 0,
          'purchase_qty', 0,
          'subtotal', 0,
          'deleted', true
        ));
        -- 恢复库存
        UPDATE products SET stock = stock + COALESCE((item_rec->>'purchase_qty')::numeric, 0)
         WHERE id = (item_rec->>'product_id')::uuid AND stock IS NOT NULL;
      ELSE
        -- 部分取消
        ratio := remaining_qty / orig_qty;
        new_items := new_items || jsonb_build_object(
          'product_id', item_rec->>'product_id',
          'product_name', item_rec->>'product_name',
          'spec_name', item_rec->>'spec_name',
          'spec_price', orig_price,
          'quantity', remaining_qty,
          'unit_qty', COALESCE((item_rec->>'unit_qty')::numeric, 1),
          'purchase_qty', ROUND(COALESCE((item_rec->>'purchase_qty')::numeric, orig_qty) * ratio, 6),
          'subtotal', ROUND(orig_price * remaining_qty, 2),
          'share', COALESCE((item_rec->>'share')::numeric, null),
          '_orig_time', COALESCE(item_rec->>'_orig_time', order_row.created_at::text)
        );
        -- 恢复部分库存
        UPDATE products SET stock = stock + ROUND(COALESCE((item_rec->>'purchase_qty')::numeric, orig_qty) * (1 - ratio), 6)
         WHERE id = (item_rec->>'product_id')::uuid AND stock IS NOT NULL;
      END IF;

      item_count := item_count + 1;
    END LOOP;

    -- 更新订单
    UPDATE orders
       SET items = new_items,
           total_amount = ROUND(new_total, 2),
           note = CASE
             WHEN COALESCE(p_note, '') <> '' THEN
               CASE WHEN COALESCE(order_row.note, '') <> '' THEN order_row.note || ' | ' || p_note ELSE p_note END
             ELSE order_row.note
           END
     WHERE id = order_row.id;

    affected_orders := affected_orders + 1;
  END LOOP;

  RETURN affected_orders;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- 拼单组队
-- ============================================================================

CREATE TABLE IF NOT EXISTS teams (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  round_id UUID NOT NULL REFERENCES rounds(id),
  product_id UUID NOT NULL REFERENCES products(id),
  initiator_name TEXT NOT NULL,
  target_qty NUMERIC(10,3) NOT NULL,
  split_count INT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'filled', 'cancelled')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS team_members (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  customer_name TEXT NOT NULL,
  spec_name TEXT NOT NULL,
  spec_price NUMERIC(10,2) NOT NULL,
  share_qty NUMERIC(10,8) NOT NULL,
  reserved_qty NUMERIC(10,8) NOT NULL DEFAULT 0,
  joined_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE teams ENABLE ROW LEVEL SECURITY;
ALTER TABLE team_members ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Anyone can read teams" ON teams;
CREATE POLICY "Anyone can read teams" ON teams FOR SELECT USING (true);
DROP POLICY IF EXISTS "Anyone can read team_members" ON team_members;
CREATE POLICY "Anyone can read team_members" ON team_members FOR SELECT USING (true);

-- 防止同一顾客在同一队伍重复加入
CREATE UNIQUE INDEX IF NOT EXISTS idx_team_member_unique ON team_members (team_id, customer_name);

CREATE OR REPLACE FUNCTION create_team(
  p_round_id UUID, p_product_id UUID, p_initiator_name TEXT,
  p_target_qty NUMERIC, p_split_count INT,
  p_spec_name TEXT, p_spec_price NUMERIC, p_share_qty NUMERIC
) RETURNS UUID AS $$
DECLARE
  v_team_id UUID;
  v_product products%ROWTYPE;
BEGIN
  -- 互斥规则已移除：允许同一顾客在同一商品加入多个队伍、同时独立下单

  SELECT * INTO v_product FROM products WHERE id = p_product_id FOR UPDATE;
  IF v_product.stock IS NOT NULL AND v_product.stock < p_share_qty THEN
    RAISE EXCEPTION 'insufficient stock: requested %, available %', p_share_qty, v_product.stock;
  END IF;

  INSERT INTO teams (round_id, product_id, initiator_name, target_qty, split_count)
  VALUES (p_round_id, p_product_id, p_initiator_name, p_target_qty, p_split_count)
  RETURNING id INTO v_team_id;

  INSERT INTO team_members (team_id, customer_name, spec_name, spec_price, share_qty, reserved_qty)
  VALUES (v_team_id, p_initiator_name, p_spec_name, p_spec_price,
    ROUND(p_share_qty, 8), ROUND(p_share_qty, 8));

  IF v_product.stock IS NOT NULL THEN
    UPDATE products SET stock = stock - p_share_qty WHERE id = p_product_id;
  END IF;
  RETURN v_team_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION join_team(
  p_team_id UUID, p_customer_name TEXT,
  p_spec_name TEXT, p_spec_price NUMERIC, p_share_qty NUMERIC
) RETURNS TEXT AS $$
DECLARE
  v_team teams%ROWTYPE;
  v_product products%ROWTYPE;
  v_current NUMERIC;
BEGIN
  SELECT * INTO v_team FROM teams WHERE id = p_team_id AND status = 'active' FOR UPDATE;
  IF v_team.id IS NULL THEN RAISE EXCEPTION 'team not found or not active'; END IF;

  -- 互斥规则已移除：允许同一顾客在同一商品加入多个队伍、同时独立下单

  SELECT COALESCE(SUM(share_qty), 0) INTO v_current FROM team_members WHERE team_id = p_team_id;
  IF ROUND(v_current + p_share_qty, 3) > v_team.target_qty THEN
    RAISE EXCEPTION 'share would exceed target: current %, adding %, target %', v_current, p_share_qty, v_team.target_qty;
  END IF;

  SELECT * INTO v_product FROM products WHERE id = v_team.product_id FOR UPDATE;
  IF v_product.stock IS NOT NULL AND v_product.stock < p_share_qty THEN
    RAISE EXCEPTION 'insufficient stock';
  END IF;

  INSERT INTO team_members (team_id, customer_name, spec_name, spec_price, share_qty, reserved_qty)
  VALUES (p_team_id, p_customer_name, p_spec_name, p_spec_price, ROUND(p_share_qty, 8), ROUND(p_share_qty, 8));

  IF v_product.stock IS NOT NULL THEN
    UPDATE products SET stock = stock - p_share_qty WHERE id = v_team.product_id;
  END IF;

  SELECT COALESCE(SUM(share_qty), 0) INTO v_current FROM team_members WHERE team_id = p_team_id;
  IF ROUND(v_current, 3) >= v_team.target_qty THEN
    PERFORM create_team_orders(p_team_id);
    RETURN 'filled';
  END IF;
  RETURN 'joined';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION leave_team(p_team_id UUID, p_customer_name TEXT)
RETURNS BOOLEAN AS $$
DECLARE
  v_team teams%ROWTYPE;
  v_member team_members%ROWTYPE;
BEGIN
  SELECT * INTO v_team FROM teams WHERE id = p_team_id AND status = 'active' FOR UPDATE;
  IF v_team.id IS NULL THEN RAISE EXCEPTION 'team not found or not active'; END IF;

  SELECT * INTO v_member FROM team_members WHERE team_id = p_team_id AND customer_name = p_customer_name;
  IF v_member.id IS NULL THEN RAISE EXCEPTION 'member not found'; END IF;

  UPDATE products SET stock = stock + v_member.reserved_qty
  WHERE id = v_team.product_id AND stock IS NOT NULL;

  DELETE FROM team_members WHERE id = v_member.id;

  IF NOT EXISTS (SELECT 1 FROM team_members WHERE team_id = p_team_id) THEN
    UPDATE teams SET status = 'cancelled' WHERE id = p_team_id;
  END IF;
  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION cancel_team(p_team_id UUID)
RETURNS BOOLEAN AS $$
DECLARE
  v_member RECORD;
  v_status TEXT;
BEGIN
  SELECT status INTO v_status FROM teams WHERE id = p_team_id FOR UPDATE;
  -- 未满员的队伍解散需归还库存
  IF v_status = 'active' THEN
    FOR v_member IN SELECT * FROM team_members WHERE team_id = p_team_id LOOP
      UPDATE products SET stock = stock + v_member.reserved_qty
      WHERE id = (SELECT product_id FROM teams WHERE id = p_team_id) AND stock IS NOT NULL;
    END LOOP;
  END IF;
  -- 已满员队伍解散时，也取消关联的订单
  IF v_status = 'filled' THEN
    UPDATE orders SET status = 'cancelled', note = COALESCE(note, '') || ' | [组队已解散]'
    WHERE round_id = (SELECT round_id FROM teams WHERE id = p_team_id)
      AND customer_name IN (SELECT customer_name FROM team_members WHERE team_id = p_team_id)
      AND status = 'active'
      AND note = '[组队]';
  END IF;
  DELETE FROM team_members WHERE team_id = p_team_id;
  UPDATE teams SET status = 'cancelled' WHERE id = p_team_id;
  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION create_team_orders(p_team_id UUID)
RETURNS INT AS $$
DECLARE
  v_team teams%ROWTYPE;
  v_member team_members%ROWTYPE;
  v_order_id UUID;
  v_orders INT := 0;
  v_items JSONB;
  v_round rounds%ROWTYPE;
BEGIN
  SELECT * INTO v_team FROM teams WHERE id = p_team_id AND status = 'active' FOR UPDATE;
  IF v_team.id IS NULL THEN RAISE EXCEPTION 'team not found or not active'; END IF;

  SELECT * INTO v_round FROM rounds WHERE id = v_team.round_id FOR UPDATE;
  IF NOT v_round.is_active THEN RAISE EXCEPTION 'round is not active'; END IF;
  IF v_round.cutoff_time IS NOT NULL AND v_round.cutoff_time <= now() THEN
    RAISE EXCEPTION 'round is closed';
  END IF;

  FOR v_member IN SELECT * FROM team_members WHERE team_id = p_team_id
  LOOP
    v_items := jsonb_build_array(jsonb_build_object(
      'product_id', v_team.product_id,
      'product_name', (SELECT name FROM products WHERE id = v_team.product_id),
      'spec_name', REGEXP_REPLACE(v_member.spec_name, '^(\d+(?:\.\d+)?)', (ROUND((REGEXP_MATCH(v_member.spec_name, '^(\d+(?:\.\d+)?)'))[1]::numeric / v_team.split_count, 2))::text),
      'spec_price', ROUND(v_member.spec_price / v_team.split_count, 2),
      'quantity', ROUND(v_member.share_qty / (v_team.target_qty / v_team.split_count))::int,
      'unit_qty', v_team.target_qty / v_team.split_count,
      'purchase_qty', v_member.share_qty,
      'subtotal', ROUND(v_member.spec_price * v_member.share_qty / v_team.target_qty, 2),
      'share', v_member.share_qty,
      '_orig_time', now()::text
    ));

    INSERT INTO orders (customer_name, items, note, total_amount, status, round_id, created_at, customer_group)
    VALUES (v_member.customer_name, v_items, '[组队]',
      ROUND(v_member.spec_price * v_member.share_qty / v_team.target_qty, 2),
      'active', v_team.round_id, now(), '')
    RETURNING id INTO v_order_id;
    v_orders := v_orders + 1;
  END LOOP;

  UPDATE teams SET status = 'filled' WHERE id = p_team_id;
  RETURN v_orders;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION get_product_teams(p_product_id UUID, p_round_id UUID)
RETURNS TABLE (
  team_id UUID, initiator TEXT, target_qty NUMERIC, split_count INT,
  current_qty NUMERIC, status TEXT, members JSONB
) AS $$
BEGIN
  RETURN QUERY
  SELECT t.id, t.initiator_name, t.target_qty, t.split_count,
    COALESCE(m.total_qty, 0), t.status, COALESCE(m.members_json, '[]'::jsonb)
  FROM teams t
  LEFT JOIN LATERAL (
    SELECT ROUND(SUM(tm.share_qty), 4) AS total_qty,
      jsonb_agg(jsonb_build_object('customer_name', tm.customer_name, 'spec_name', tm.spec_name, 'share_qty', tm.share_qty)) AS members_json
    FROM team_members tm WHERE tm.team_id = t.id
  ) m ON true
  WHERE t.product_id = p_product_id AND t.round_id = p_round_id AND t.status IN ('active', 'filled')
  ORDER BY t.created_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_get_teams(p_token TEXT, p_round_id UUID)
RETURNS TABLE (
  team_id UUID, product_name TEXT, initiator TEXT, target_qty NUMERIC, split_count INT,
  current_qty NUMERIC, status TEXT, created_at TIMESTAMPTZ, members JSONB
) AS $$
DECLARE
  v_leader_id UUID;
  v_role TEXT;
BEGIN
  SELECT * INTO v_leader_id, v_role FROM require_admin(p_token);
  RETURN QUERY
  SELECT t.id, p.name, t.initiator_name, t.target_qty, t.split_count,
    COALESCE(m.total_qty, 0), t.status, t.created_at, COALESCE(m.members_json, '[]'::jsonb)
  FROM teams t
  JOIN products p ON p.id = t.product_id
  LEFT JOIN LATERAL (
    SELECT ROUND(SUM(tm.share_qty), 4) AS total_qty,
      jsonb_agg(jsonb_build_object('customer_name', tm.customer_name, 'spec_name', tm.spec_name, 'share_qty', tm.share_qty)) AS members_json
    FROM team_members tm WHERE tm.team_id = t.id
  ) m ON true
  WHERE (p_round_id IS NULL OR t.round_id = p_round_id) AND t.status IN ('active', 'filled')
  ORDER BY t.created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION auto_dissolve_expired_teams()
RETURNS INT AS $$
DECLARE v_count INT := 0; v_team RECORD;
BEGIN
  FOR v_team IN
    SELECT t.id FROM teams t JOIN rounds r ON r.id = t.round_id
    WHERE t.status = 'active' AND (r.is_active = false OR (r.cutoff_time IS NOT NULL AND r.cutoff_time <= now()))
  LOOP
    PERFORM cancel_team(v_team.id);
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION get_customer_teams(p_round_id UUID, p_customer_name TEXT)
RETURNS TABLE (
  team_id UUID, product_id UUID, initiator TEXT, target_qty NUMERIC,
  split_count INT, status TEXT, members JSONB
) AS $$
BEGIN
  RETURN QUERY
  SELECT t.id, t.product_id, t.initiator_name, t.target_qty, t.split_count, t.status,
    COALESCE(m.members_json, '[]'::jsonb)
  FROM teams t
  JOIN team_members cu ON cu.team_id = t.id AND cu.customer_name = p_customer_name
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object(
      'customer_name', tm.customer_name,
      'spec_name', tm.spec_name,
      'share_qty', ROUND(tm.share_qty, 4)
    )) AS members_json
    FROM team_members tm WHERE tm.team_id = t.id
  ) m ON true
  WHERE t.round_id = p_round_id AND t.status IN ('active', 'filled');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- Seed 超级管理员（首次部署，密码 hash 对应 'admin123'）
-- ============================================================================
INSERT INTO leaders (username, password_hash, role, password_plain)
SELECT 'admin', '240be518fabd2724ddb6f04eeb1da5967448d7e831c08c8fa822809f74c720a9', 'super_admin', 'admin123'
WHERE NOT EXISTS (SELECT 1 FROM leaders WHERE username = 'admin');
