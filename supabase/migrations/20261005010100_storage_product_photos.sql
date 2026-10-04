-- =====================================================================
-- Mika Shop: migration 2, storage bucket for product photos.
-- Public read (photos are shown on the shop); upload/replace/delete for
-- ADMIN only. Files are web-size copies; the masters live in Google Drive.
-- =====================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-photos', 'product-photos', true, 5242880,  -- 5 MB per file
        array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy "product-photos: admin upload"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'product-photos' and public.my_role() = 'ADMIN');

create policy "product-photos: admin update"
  on storage.objects for update to authenticated
  using (bucket_id = 'product-photos' and public.my_role() = 'ADMIN')
  with check (bucket_id = 'product-photos' and public.my_role() = 'ADMIN');

create policy "product-photos: admin delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'product-photos' and public.my_role() = 'ADMIN');

-- Staff can list the bucket (admin photo picker). Public viewing works
-- through the public URL and needs no select policy.
create policy "product-photos: staff list"
  on storage.objects for select to authenticated
  using (bucket_id = 'product-photos' and public.my_role() is not null);
