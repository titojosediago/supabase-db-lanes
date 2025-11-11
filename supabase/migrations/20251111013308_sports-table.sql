-- 1. Create the sports table if it doesn't exist
create table if not exists public.sports (
  id uuid primary key default gen_random_uuid (),
  name text not null unique,
  description text,
  category text, -- e.g., 'team', 'individual', 'water', 'winter'
  origin_country text,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

-- 2. Create the "handle_updated_at" function if it doesn't exist
do $$
begin
  if not exists (
    select 1 from pg_proc where proname = 'handle_updated_at'
  ) then
    execute $func$
      create function public.handle_updated_at()
      returns trigger as $body$
      begin
        new.updated_at = now();
        return new;
      end;
      $body$ language plpgsql security definer;
    $func$;
  end if;
end $$;

-- 3. Create trigger only if it doesn't exist
do $$
begin
  if not exists (
    select 1
    from pg_trigger
    where tgname = 'handle_updated_at'
      and tgrelid = 'public.sports'::regclass
  ) then
    create trigger handle_updated_at
    before update on public.sports
    for each row
    execute function public.handle_updated_at();
  end if;
end $$;

-- 4. Enable RLS (only if not already enabled)
do $$
begin
  if not exists (
    select 1 from pg_tables
    where schemaname = 'public'
      and tablename = 'sports'
      and rowsecurity = true
  ) then
    alter table public.sports enable row level security;
  end if;
end $$;

-- 5. Create SELECT policy for authenticated users if not exists
do $$
begin
  if not exists (
    select 1 from pg_policies
    where policyname = 'Allow authenticated users to read sports'
      and tablename = 'sports'
  ) then
    create policy "Allow authenticated users to read sports"
    on public.sports
    for select
    using (auth.role() = 'authenticated');
  end if;
end $$;

-- 6. Create ADMIN policy for full access if not exists
do $$
begin
  if not exists (
    select 1 from pg_policies
    where policyname = 'Allow admins to manage sports'
      and tablename = 'sports'
  ) then
    create policy "Allow admins to manage sports"
    on public.sports
    for all
    using ((auth.jwt() ->> 'role') = 'admin')
    with check ((auth.jwt() ->> 'role') = 'admin');
  end if;
end $$;