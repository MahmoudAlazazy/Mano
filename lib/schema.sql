-- OUTFIT ADVISOR - SUPABASE SCHEMA (CLEAN)
-- Generated: 2026-04-13

-- Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- USERS (profile) table
CREATE TABLE IF NOT EXISTS public.users (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  name text NOT NULL,
  email text,
  image_path text,
  height numeric(5,2) DEFAULT 170 CHECK (height > 0 AND height < 300),
  weight numeric(5,2) DEFAULT 65 CHECK (weight > 0 AND weight < 500),
  skin_tone text DEFAULT 'Medium',
  body_type text DEFAULT 'Regular',
  style_personality text DEFAULT 'Classic',
  is_active boolean DEFAULT true,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own profile" ON public.users
  FOR SELECT USING (auth.uid() = id);

CREATE POLICY "Users can update own profile" ON public.users
  FOR UPDATE USING (auth.uid() = id);

CREATE POLICY "Users can insert own profile" ON public.users
  FOR INSERT WITH CHECK (auth.uid() = id);

CREATE INDEX IF NOT EXISTS idx_users_email ON public.users(email);

-- USER FAVORITE COLORS
CREATE TABLE IF NOT EXISTS public.user_favorite_colors (
  id bigserial PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  color_name text NOT NULL,
  color_hex text,
  created_at timestamptz DEFAULT now(),
  UNIQUE(user_id, color_name)
);

ALTER TABLE public.user_favorite_colors ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can manage own favorite colors" ON public.user_favorite_colors
  FOR ALL USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_user_colors_user_id ON public.user_favorite_colors(user_id);

-- USER OCCASIONS
CREATE TABLE IF NOT EXISTS public.user_occasions (
  id bigserial PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  occasion text NOT NULL,
  created_at timestamptz DEFAULT now(),
  UNIQUE(user_id, occasion)
);

ALTER TABLE public.user_occasions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can manage own occasions" ON public.user_occasions
  FOR ALL USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_user_occasions_user_id ON public.user_occasions(user_id);

-- CLOTHING ITEMS
CREATE TABLE IF NOT EXISTS public.clothing_items (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  name text NOT NULL,
  category text NOT NULL,
  emoji text,
  image_path text,
  image_url text,
  color text,
  brand text,
  size text,
  condition text DEFAULT 'Good',
  is_favorite boolean DEFAULT false,
  wear_count integer DEFAULT 0 CHECK (wear_count >= 0),
  last_worn_at timestamptz,
  added_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE public.clothing_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own clothing" ON public.clothing_items
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own clothing" ON public.clothing_items
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own clothing" ON public.clothing_items
  FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "Users can delete own clothing" ON public.clothing_items
  FOR DELETE USING (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_clothing_user_id ON public.clothing_items(user_id);
CREATE INDEX IF NOT EXISTS idx_clothing_category ON public.clothing_items(user_id, category);
CREATE INDEX IF NOT EXISTS idx_clothing_added_at ON public.clothing_items(added_at DESC);
CREATE INDEX IF NOT EXISTS idx_clothing_favorite ON public.clothing_items(user_id) WHERE is_favorite = true;
CREATE INDEX IF NOT EXISTS idx_clothing_last_worn ON public.clothing_items(last_worn_at DESC);

-- SAVED OUTFITS
CREATE TABLE IF NOT EXISTS public.saved_outfits (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  name text,
  occasion text,
  style_type text,
  notes text,
  image_preview text,
  image_url text,
  rating integer DEFAULT 0 CHECK (rating >= 0 AND rating <= 5),
  wear_count integer DEFAULT 0 CHECK (wear_count >= 0),
  is_favorite boolean DEFAULT false,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE public.saved_outfits ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own outfits" ON public.saved_outfits
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own outfits" ON public.saved_outfits
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own outfits" ON public.saved_outfits
  FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "Users can delete own outfits" ON public.saved_outfits
  FOR DELETE USING (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_outfits_user_id ON public.saved_outfits(user_id);
CREATE INDEX IF NOT EXISTS idx_outfits_created_at ON public.saved_outfits(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_outfits_favorite ON public.saved_outfits(user_id) WHERE is_favorite = true;

-- OUTFIT ITEMS (many-to-many)
CREATE TABLE IF NOT EXISTS public.outfit_items (
  id bigserial PRIMARY KEY,
  outfit_id uuid NOT NULL REFERENCES public.saved_outfits(id) ON DELETE CASCADE,
  clothing_item_id uuid NOT NULL REFERENCES public.clothing_items(id) ON DELETE CASCADE,
  position integer DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  UNIQUE(outfit_id, clothing_item_id)
);

ALTER TABLE public.outfit_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own outfit items" ON public.outfit_items
  FOR SELECT USING (
    outfit_id IN (
      SELECT id FROM public.saved_outfits WHERE user_id = auth.uid()
    )
  );

CREATE POLICY "Users can manage own outfit items" ON public.outfit_items
  FOR ALL USING (
    outfit_id IN (
      SELECT id FROM public.saved_outfits WHERE user_id = auth.uid()
    )
  )
  WITH CHECK (
    outfit_id IN (
      SELECT id FROM public.saved_outfits WHERE user_id = auth.uid()
    )
  );

CREATE INDEX IF NOT EXISTS idx_outfit_items_outfit_id ON public.outfit_items(outfit_id);
CREATE INDEX IF NOT EXISTS idx_outfit_items_clothing_id ON public.outfit_items(clothing_item_id);

-- WEAR HISTORY
CREATE TABLE IF NOT EXISTS public.wear_history (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  clothing_item_id uuid NOT NULL REFERENCES public.clothing_items(id) ON DELETE CASCADE,
  outfit_id uuid REFERENCES public.saved_outfits(id) ON DELETE SET NULL,
  wore_date timestamptz DEFAULT now(),
  created_at timestamptz DEFAULT now()
);

ALTER TABLE public.wear_history ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own wear history" ON public.wear_history
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own wear history" ON public.wear_history
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_wear_history_user_id ON public.wear_history(user_id);
CREATE INDEX IF NOT EXISTS idx_wear_history_item_id ON public.wear_history(clothing_item_id);
CREATE INDEX IF NOT EXISTS idx_wear_history_date ON public.wear_history(wore_date DESC);
CREATE INDEX IF NOT EXISTS idx_wear_history_user_date ON public.wear_history(user_id, wore_date DESC);

-- WARDROBE STATS
CREATE TABLE IF NOT EXISTS public.wardrobe_stats (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL UNIQUE REFERENCES public.users(id) ON DELETE CASCADE,
  total_items integer DEFAULT 0,
  total_outfits integer DEFAULT 0,
  favorite_color text,
  most_worn_category text,
  avg_items_per_outfit numeric(4,2) DEFAULT 0,
  last_outfit_date timestamptz,
  computed_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE public.wardrobe_stats ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own stats" ON public.wardrobe_stats
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own stats" ON public.wardrobe_stats
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own stats" ON public.wardrobe_stats
  FOR UPDATE USING (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_stats_user_id ON public.wardrobe_stats(user_id);

-- ADMIN RLS HELPERS (OPTIONAL FOR DASHBOARD-WIDE READ ACCESS)
-- NOTE:
-- 1) Set admin role on auth user app_metadata, for example:
--    update auth.users
--    set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"role":"admin"}'::jsonb
--    where email = 'admin2002@gmail.com';
-- 2) User must sign out/in again so JWT includes the new role.
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (auth.jwt() -> 'app_metadata' ->> 'role') IN ('admin', 'super_admin'),
    false
  );
$$;

GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated;

CREATE POLICY "Admins can view all users" ON public.users
  FOR SELECT TO authenticated USING (public.is_admin());

CREATE POLICY "Admins can view all favorite colors" ON public.user_favorite_colors
  FOR SELECT TO authenticated USING (public.is_admin());

CREATE POLICY "Admins can view all occasions" ON public.user_occasions
  FOR SELECT TO authenticated USING (public.is_admin());

CREATE POLICY "Admins can view all clothing" ON public.clothing_items
  FOR SELECT TO authenticated USING (public.is_admin());

CREATE POLICY "Admins can view all outfits" ON public.saved_outfits
  FOR SELECT TO authenticated USING (public.is_admin());

CREATE POLICY "Admins can view all outfit items" ON public.outfit_items
  FOR SELECT TO authenticated USING (public.is_admin());

CREATE POLICY "Admins can view all wear history" ON public.wear_history
  FOR SELECT TO authenticated USING (public.is_admin());

CREATE POLICY "Admins can view all stats" ON public.wardrobe_stats
  FOR SELECT TO authenticated USING (public.is_admin());

-- FUNCTIONS
CREATE OR REPLACE FUNCTION public.handle_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.update_clothing_wear_stats()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE public.clothing_items
  SET 
    wear_count = (SELECT COUNT(*) FROM public.wear_history WHERE clothing_item_id = NEW.clothing_item_id),
    last_worn_at = NEW.wore_date
  WHERE id = NEW.clothing_item_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.update_wardrobe_stats()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.wardrobe_stats (user_id, total_items, total_outfits, computed_at, updated_at)
  VALUES (
    NEW.user_id,
    (SELECT COUNT(*) FROM public.clothing_items WHERE user_id = NEW.user_id),
    (SELECT COUNT(*) FROM public.saved_outfits WHERE user_id = NEW.user_id),
    now(),
    now()
  )
  ON CONFLICT (user_id) DO UPDATE SET
    total_items = EXCLUDED.total_items,
    total_outfits = EXCLUDED.total_outfits,
    updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- TRIGGERS
CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER update_clothing_updated_at BEFORE UPDATE ON public.clothing_items
  FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER update_outfits_updated_at BEFORE UPDATE ON public.saved_outfits
  FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER update_stats_updated_at BEFORE UPDATE ON public.wardrobe_stats
  FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

CREATE TRIGGER sync_wear_stats AFTER INSERT ON public.wear_history
  FOR EACH ROW EXECUTE FUNCTION public.update_clothing_wear_stats();

CREATE TRIGGER update_stats_on_clothing_insert AFTER INSERT ON public.clothing_items
  FOR EACH ROW EXECUTE FUNCTION public.update_wardrobe_stats();

CREATE TRIGGER update_stats_on_clothing_delete AFTER DELETE ON public.clothing_items
  FOR EACH ROW EXECUTE FUNCTION public.update_wardrobe_stats();

CREATE TRIGGER update_stats_on_outfit_insert AFTER INSERT ON public.saved_outfits
  FOR EACH ROW EXECUTE FUNCTION public.update_wardrobe_stats();

CREATE TRIGGER update_stats_on_outfit_delete AFTER DELETE ON public.saved_outfits
  FOR EACH ROW EXECUTE FUNCTION public.update_wardrobe_stats();

-- OPTIONAL VIEWS
CREATE OR REPLACE VIEW public.user_profiles_with_stats AS
SELECT 
  u.id,
  u.name,
  u.email,
  u.height,
  u.weight,
  u.skin_tone,
  u.body_type,
  u.style_personality,
  u.created_at,
  ws.total_items,
  ws.total_outfits,
  ws.favorite_color,
  ws.most_worn_category,
  ws.last_outfit_date
FROM public.users u
LEFT JOIN public.wardrobe_stats ws ON u.id = ws.user_id;

CREATE OR REPLACE VIEW public.clothing_with_wear_stats AS
SELECT 
  ci.id,
  ci.user_id,
  ci.name,
  ci.category,
  ci.emoji,
  ci.color,
  ci.is_favorite,
  ci.wear_count,
  ci.last_worn_at,
  ci.added_at,
  (SELECT COUNT(*) FROM public.wear_history WHERE clothing_item_id = ci.id) as total_wears,
  (SELECT AVG(EXTRACT(DAY FROM (now() - wore_date))) FROM public.wear_history WHERE clothing_item_id = ci.id) as days_since_last_wear
FROM public.clothing_items ci;

CREATE OR REPLACE VIEW public.outfit_details AS
SELECT 
  so.id,
  so.user_id,
  so.name,
  so.occasion,
  so.style_type,
  so.rating,
  so.is_favorite,
  so.wear_count,
  so.created_at,
  json_agg(
    json_build_object(
      'id', ci.id,
      'name', ci.name,
      'category', ci.category,
      'emoji', ci.emoji,
      'color', ci.color
    ) ORDER BY oi.position
  ) as items
FROM public.saved_outfits so
LEFT JOIN public.outfit_items oi ON so.id = oi.outfit_id
LEFT JOIN public.clothing_items ci ON oi.clothing_item_id = ci.id
GROUP BY so.id, so.user_id, so.name, so.occasion, so.style_type, so.rating, so.is_favorite, so.wear_count, so.created_at;

-- STORAGE (avatars)
INSERT INTO storage.buckets (id, name, public)
VALUES ('avatars', 'avatars', true)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Avatar images are publicly readable" ON storage.objects
  FOR SELECT USING (bucket_id = 'avatars');

CREATE POLICY "Users can upload their own avatar" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'avatars'
    AND auth.uid()::text = split_part(name, '/', 1)
  );

CREATE POLICY "Users can update their own avatar" ON storage.objects
  FOR UPDATE USING (
    bucket_id = 'avatars'
    AND auth.uid()::text = split_part(name, '/', 1)
  );

CREATE POLICY "Users can delete their own avatar" ON storage.objects
  FOR DELETE USING (
    bucket_id = 'avatars'
    AND auth.uid()::text = split_part(name, '/', 1)
  );

-- STORAGE (clothing images)
INSERT INTO storage.buckets (id, name, public)
VALUES ('clothing_images', 'clothing_images', true)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "Clothing images are publicly readable" ON storage.objects
  FOR SELECT USING (bucket_id = 'clothing_images');

CREATE POLICY "Users can upload their own clothing images" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'clothing_images'
    AND split_part(name, '/', 1) = 'outfit_advisor'
    AND auth.uid()::text = split_part(name, '/', 2)
  );

CREATE POLICY "Users can update their own clothing images" ON storage.objects
  FOR UPDATE USING (
    bucket_id = 'clothing_images'
    AND split_part(name, '/', 1) = 'outfit_advisor'
    AND auth.uid()::text = split_part(name, '/', 2)
  );

CREATE POLICY "Users can delete their own clothing images" ON storage.objects
  FOR DELETE USING (
    bucket_id = 'clothing_images'
    AND split_part(name, '/', 1) = 'outfit_advisor'
    AND auth.uid()::text = split_part(name, '/', 2)
  );
