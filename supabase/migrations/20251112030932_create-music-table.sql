-- 1. Create table if not exists
create table if not exists public.music (
  id uuid primary key default gen_random_uuid (),
  title text not null,
  artist text,
  album text,
  genre text,
  release_year int,
  created_by uuid references auth.users (id) not null,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

-- 2. Create or replace the updated_at function
create or replace function public.handle_updated_at () returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql security definer;

-- 3. Create trigger if not exists
do $$
begin
  if not exists (
    select 1
    from pg_trigger
    where tgname = 'handle_updated_at'
      and tgrelid = 'public.music'::regclass
  ) then
    create trigger handle_updated_at
    before update on public.music
    for each row
    execute function public.handle_updated_at();
  end if;
end $$;

-- 4. Enable RLS
alter table public.music enable row level security;

-- 5. Policies (check existence first)
-- Authenticated users can SELECT
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

-- Authenticated users can INSERT their own records
do $$
begin
  if not exists (
    select 1 from pg_policies
    where policyname = 'Allow authenticated users to insert own music'
      and tablename = 'music'
  ) then
    create policy "Allow authenticated users to insert own music"
    on public.music
    for insert
    with check (auth.uid() = created_by);
  end if;
end $$;

-- Owners can UPDATE/DELETE their own records
do $$
begin
  if not exists (
    select 1 from pg_policies
    where policyname = 'Allow owners to manage own music'
      and tablename = 'music'
  ) then
    create policy "Allow owners to manage own music"
    on public.music
    for all
    using (auth.uid() = created_by)
    with check (auth.uid() = created_by);
  end if;
end $$;

-- Admins can manage everything
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