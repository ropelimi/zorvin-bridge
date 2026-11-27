-- ============================================================
--  079. AS SIGLAS E OS NOMES NAS ETIQUETAS (27/11)
--
--  >>> A PONTE APLICA SOZINHA (sql/automaticos). <<<
--  Pode rodar de novo sem medo — a pasta inteira, na ordem (regra 5).
--
--  ------------------------------------------------------------
--  O PEDIDO
--
--  O 078 deixou só a primeira letra maiúscula em toda etiqueta, e as siglas e
--  os nomes foram junto ("Subsídio ccr", "Sac", "Falar com dr. max"). O
--  Rodrigo: "Podemos sim abrir exceções para siglas: CCR, SAC." E: "max" vira
--  "Max" por ser um nome próprio. (27/11)
--
--  ------------------------------------------------------------
--  O QUE ESTE SCRIPT FAZ
--
--    zorvin_etiqueta_palavras        as exceções: cada palavra, e como ela
--                                    se escreve ("CCR", "SAC", "Max").
--                                    Nasce com essas três, uma vez só (na
--                                    rodada que cria a tabela): tirada
--                                    depois, rodar de novo não a traz.
--    zorvin_nome_da_etiqueta(texto)  a regra do 078 e, depois dela, cada
--                                    palavra da lista INTEIRA (sem olhar
--                                    maiúscula) trocada pela forma dela.
--                                    "subsídio ccr" vira "Subsídio CCR";
--                                    "maxwell" não muda (não é a palavra).
--
--  As etiquetas que já existem são refeitas pela regra nova.
--
--  A função passa a ler uma tabela: deixa de ser `immutable` (nenhum índice
--  a usa) e roda com o poder do dono (`security definer`): o gatilho do 078
--  dispara no papel de quem grava pelo painel, e a tabela das exceções é só
--  da ponte e do editor (RLS ligada, sem política). Sem o poder do dono, pelo
--  painel a lista viria vazia, calada, e a sigla sairia minúscula.
--
--  Pela regra 5, a versão de referência de `zorvin_nome_da_etiqueta` passa a
--  ser esta: o 078 rodado sozinho depois dela tira as exceções.
--
--  Trocar uma exceção, por enquanto, é pelo editor ou pelo conector:
--    insert into zorvin_etiqueta_palavras values ('danilo', 'Danilo');
--    update tags set nome = nome;   -- refaz os nomes que já existem
--
--  DEPENDE DE: o 078 (o gatilho e a função).
-- ============================================================

do $etq$
declare
  v_n integer := 0;
begin
  drop table if exists zorvin_conferencia_079;
  create temp table zorvin_conferencia_079 (item text, resposta text);

  if to_regclass('public.tags') is null
     or to_regprocedure('public.zorvin_nome_da_etiqueta(text)') is null then
    insert into zorvin_conferencia_079 values ('sem as etiquetas do 078', 'nada a fazer aqui');
    raise notice 'Zorvin: sem a tabela tags ou sem o 078 — script 079 não fez nada.';
    return;
  end if;

  if to_regclass('public.zorvin_etiqueta_palavras') is null then
    create table public.zorvin_etiqueta_palavras (
      palavra text primary key check (palavra = lower(palavra) and palavra ~ '^[[:alpha:]]+$'),
      forma   text not null check (lower(forma) = palavra)
    );
    comment on table public.zorvin_etiqueta_palavras is
      'Zorvin (079): as siglas e os nomes que o nome das etiquetas escreve do jeito deles.';
    insert into public.zorvin_etiqueta_palavras values ('ccr', 'CCR'), ('sac', 'SAC'), ('max', 'Max');
  end if;

  alter table public.zorvin_etiqueta_palavras enable row level security;
  revoke all on public.zorvin_etiqueta_palavras from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on public.zorvin_etiqueta_palavras from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on public.zorvin_etiqueta_palavras from authenticated';
  end if;

  create or replace function public.zorvin_nome_da_etiqueta(p_nome text)
  returns text language plpgsql stable security definer set search_path = public as $f$
  declare
    v text;
    r record;
  begin
    if p_nome is null then return null; end if;
    v := upper(left(btrim(p_nome), 1)) || lower(substr(btrim(p_nome), 2));
    for r in select palavra, forma from public.zorvin_etiqueta_palavras loop
      v := regexp_replace(v, '\m' || r.palavra || '\M', r.forma, 'gi');
    end loop;
    return v;
  end $f$;

  -- O gatilho do 078 a chama no papel de quem grava: quem entrou continua
  -- podendo executá-la (é uma conta de texto); quem não entrou, não.
  revoke all on function public.zorvin_nome_da_etiqueta(text) from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.zorvin_nome_da_etiqueta(text) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.zorvin_nome_da_etiqueta(text) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.zorvin_nome_da_etiqueta(text) to service_role';
  end if;

  update public.tags set nome = public.zorvin_nome_da_etiqueta(nome)
   where nome is distinct from public.zorvin_nome_da_etiqueta(nome);
  get diagnostics v_n = row_count;

  insert into zorvin_conferencia_079 values ('etiquetas refeitas nesta rodada', v_n::text);
end $etq$;

do $conf$
begin
  if to_regclass('public.zorvin_etiqueta_palavras') is null then return; end if;
  insert into zorvin_conferencia_079
  select 'as exceções', coalesce(string_agg(forma, ', ' order by forma), '(nenhuma)')
    from public.zorvin_etiqueta_palavras;
  insert into zorvin_conferencia_079
  select 'etiquetas fora da regra (tem de ser 0)', count(*)::text
    from public.tags where nome is distinct from public.zorvin_nome_da_etiqueta(nome);
  insert into zorvin_conferencia_079
  select 'quem entrou não lê as exceções',
         case when not exists (select 1 from pg_roles where rolname = 'authenticated') then 'true'
              else (not has_table_privilege('authenticated', 'public.zorvin_etiqueta_palavras', 'select'))::text end;
end $conf$;

select * from zorvin_conferencia_079;
