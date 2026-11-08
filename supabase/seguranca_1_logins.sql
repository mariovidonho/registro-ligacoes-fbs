-- Segurança, etapa 1: logins e papéis (não tranca nada; o site antigo segue funcionando).
-- Representante: e-mail e senha. Coordenador e vendedor: nome e PIN.
-- O PIN vira a senha do login como 'fbs-' || pin, guardada criptografada pelo Supabase Auth.

alter table public.vendedores add column if not exists equipe text references public.equipes (nome) on update cascade;
update public.vendedores set equipe = 'Gaviões' where equipe is null;
alter table public.vendedores alter column pin drop not null;

create table if not exists public.perfis (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  papel      text not null check (papel in ('representante', 'coordenador', 'vendedor')),
  nome       text not null,
  equipe     text references public.equipes (nome) on update cascade,
  trocar_pin boolean not null default false
);
create unique index if not exists perfis_nome_papel_uk on public.perfis (papel, nome);
alter table public.perfis enable row level security;   -- sem policies: só as funções abaixo acessam

create or replace function public.meu_papel() returns text
language sql stable security definer set search_path = public as $$
  select papel from public.perfis where user_id = auth.uid()
$$;
create or replace function public.meu_nome() returns text
language sql stable security definer set search_path = public as $$
  select nome from public.perfis where user_id = auth.uid()
$$;
create or replace function public.eh_rep() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select papel = 'representante' from public.perfis where user_id = auth.uid()), false)
$$;
-- representante vê todos; coordenador, a equipe dele; vendedor, só ele mesmo
create or replace function public.pode_ver(p_vendedor text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.perfis p
    where p.user_id = auth.uid()
      and (p.papel = 'representante'
           or (p.papel = 'vendedor' and p.nome = p_vendedor)
           or (p.papel = 'coordenador' and exists (
                 select 1 from public.vendedores v where v.nome = p_vendedor and v.equipe = p.equipe)))
  )
$$;

create or replace function public.email_login(p_nome text) returns text
language sql immutable as $$
  select regexp_replace(lower(translate(p_nome, 'áàãâéêíóôõúçÁÀÃÂÉÊÍÓÔÕÚÇ', 'aaaaeeioooucAAAAEEIOOOUC')), '[^a-z0-9]+', '-', 'g')
         || '@acesso.fbsprime.com.br'
$$;

-- cria o usuário no Auth (uso interno das funções abaixo)
create or replace function public.criar_login(p_email text, p_senha text) returns uuid
language plpgsql security definer set search_path = public, extensions, auth as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', lower(p_email),
          extensions.crypt(p_senha, extensions.gen_salt('bf')), now(),
          '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), v_id, v_id::text, 'email',
          jsonb_build_object('sub', v_id::text, 'email', lower(p_email), 'email_verified', true), now(), now(), now());
  return v_id;
end
$$;
revoke all on function public.criar_login(text, text) from public, anon, authenticated;

-- nomes da tela de login (sem PIN)
create or replace function public.nomes_login()
returns table (nome text, papel text, foto_url text, login text)
language sql stable security definer set search_path = public as $$
  select p.nome, p.papel, v.foto_url, public.email_login(p.nome)
  from public.perfis p
  left join public.vendedores v on v.nome = p.nome
  where p.papel in ('vendedor', 'coordenador')
  order by p.nome
$$;
grant execute on function public.nomes_login() to anon;

create or replace function public.meu_perfil() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('papel', papel, 'nome', nome, 'equipe', equipe, 'trocar_pin', trocar_pin)
  from public.perfis where user_id = auth.uid()
$$;

create or replace function public.trocar_meu_pin(p_novo text) returns void
language plpgsql security definer set search_path = public, extensions, auth as $$
begin
  if p_novo !~ '^[0-9]{6}$' then raise exception 'O PIN precisa ter 6 números'; end if;
  update auth.users set encrypted_password = extensions.crypt('fbs-' || p_novo, extensions.gen_salt('bf')), updated_at = now()
   where id = auth.uid();
  update public.perfis set trocar_pin = false where user_id = auth.uid();
end
$$;

-- ---- Só o representante ----
create or replace function public.exigir_rep() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.eh_rep() then raise exception 'Sem permissão'; end if;
end
$$;

create or replace function public.admin_criar_vendedor(p_nome text, p_pin text, p_equipe text) returns void
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform public.exigir_rep();
  if p_pin !~ '^[0-9]{4,6}$' then raise exception 'O PIN provisório precisa ter de 4 a 6 números'; end if;
  insert into public.vendedores (nome, equipe) values (trim(p_nome), p_equipe);
  v_id := public.criar_login(public.email_login(trim(p_nome)), 'fbs-' || p_pin);
  insert into public.perfis (user_id, papel, nome, equipe, trocar_pin) values (v_id, 'vendedor', trim(p_nome), p_equipe, true);
end
$$;

create or replace function public.admin_criar_coordenador(p_nome text, p_pin text, p_equipe text) returns void
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform public.exigir_rep();
  if p_pin !~ '^[0-9]{4,6}$' then raise exception 'O PIN provisório precisa ter de 4 a 6 números'; end if;
  v_id := public.criar_login(public.email_login(trim(p_nome)), 'fbs-' || p_pin);
  insert into public.perfis (user_id, papel, nome, equipe, trocar_pin) values (v_id, 'coordenador', trim(p_nome), p_equipe, true);
end
$$;

create or replace function public.admin_redefinir_pin(p_nome text, p_pin text) returns void
language plpgsql security definer set search_path = public, extensions, auth as $$
begin
  perform public.exigir_rep();
  if p_pin !~ '^[0-9]{4,6}$' then raise exception 'O PIN provisório precisa ter de 4 a 6 números'; end if;
  update auth.users set encrypted_password = extensions.crypt('fbs-' || p_pin, extensions.gen_salt('bf')), updated_at = now()
   where id in (select user_id from public.perfis where nome = p_nome and papel in ('vendedor', 'coordenador'));
  update public.perfis set trocar_pin = true where nome = p_nome and papel in ('vendedor', 'coordenador');
end
$$;

create or replace function public.admin_remover_acesso(p_nome text, p_papel text) returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  perform public.exigir_rep();
  if p_papel not in ('vendedor', 'coordenador') then raise exception 'Papel inválido'; end if;
  delete from auth.users where id in (select user_id from public.perfis where nome = p_nome and papel = p_papel);
  if p_papel = 'vendedor' then delete from public.vendedores where nome = p_nome; end if;
end
$$;

create or replace function public.admin_definir_equipe(p_nome text, p_equipe text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.exigir_rep();
  update public.vendedores set equipe = p_equipe where nome = p_nome;
  update public.perfis set equipe = p_equipe where nome = p_nome and papel = 'vendedor';
end
$$;

create or replace function public.admin_coordenadores()
returns table (nome text, equipe text, trocar_pin boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.exigir_rep();
  return query select p.nome, p.equipe, p.trocar_pin from public.perfis p where p.papel = 'coordenador' order by p.nome;
end
$$;

-- valores de venda para ranking/campanhas/desempenho, sem o nome do cliente
create or replace function public.vendas_resumo()
returns table (vendedor text, data date, valor numeric, canal text)
language sql stable security definer set search_path = public as $$
  select v.vendedor, v.data, v.valor, v.canal from public.vendas v where auth.uid() is not null
$$;

-- metas fixas combinadas: 150 ligações, 5 agendamentos, 2 comparecimentos e 1 venda por semana
do $$
declare d text;
begin
  select pg_get_functiondef('public.get_metas(text)'::regprocedure) into d;
  d := replace(d, 'ag_ant + 1,', '5,');
  d := replace(d, 'coalesce(ant.progresso_comparecimentos, 0) + 1,', '2,');
  d := replace(d, 'coalesce(ant.progresso_vendas, 0) + 1,', '1,');
  d := replace(d, 'lig_ant + 1)', '150)');
  execute d;
end
$$;

-- cria o login de cada vendedor atual com o PIN de hoje (troca obrigatória para 6 dígitos no 1º acesso)
do $$
declare r record; v_id uuid;
begin
  for r in select nome, pin, equipe from public.vendedores v
            where pin is not null and not exists (select 1 from public.perfis p where p.nome = v.nome and p.papel = 'vendedor') loop
    v_id := public.criar_login(public.email_login(r.nome), 'fbs-' || r.pin);
    insert into public.perfis (user_id, papel, nome, equipe, trocar_pin) values (v_id, 'vendedor', r.nome, r.equipe, true);
  end loop;
end
$$;

select papel, count(*) from public.perfis group by 1;
