-- 1. Drop policies that reference created_by
do $$
begin
  if exists (
    select 1 from pg_policies
    where policyname = 'Allow authenticated users to insert own music'
      and tablename = 'music'
  ) then
    drop policy "Allow authenticated users to insert own music" on public.music;
  end if;

  if exists (
    select 1 from pg_policies
    where policyname = 'Allow owners to manage own music'
      and tablename = 'music'
  ) then
    drop policy "Allow owners to manage own music" on public.music;
  end if;
end $$;

-- 2. Drop the created_by column if it exists
alter table public.music
drop column if exists created_by;

-- 3. Update RLS policies
-- 3a. Authenticated users can SELECT
do $$
begin
  if not exists (
    select 1 from pg_policies
    where policyname = 'Allow authenticated users to read music'
      and tablename = 'music'
  ) then
    create policy "Allow authenticated users to read music"
    on public.music
    for select
    using (auth.role() = 'authenticated');
  end if;
end $$;

-- 3b. Admins can manage everything
do $$
begin
  if not exists (
    select 1 from pg_policies
    where policyname = 'Allow admins to manage all music'
      and tablename = 'music'
  ) then
    create policy "Allow admins to manage all music"
    on public.music
    for all
    using ((auth.jwt() ->> 'role') = 'admin')
    with check ((auth.jwt() ->> 'role') = 'admin');
  end if;
end $$;