-- ============================================================
--  O GASTO DO QUAZAR
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  A ponte aplica sozinha ao subir (sql/automaticos). Pode rodar de novo sem
--  medo — na ordem da pasta, como diz a regra 5 do LEIA-ME.
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido do Rodrigo em 08/11, depois de um e-mail da Anthropic sobre o
--  cache: "Veja o que podemos fazer para economizar os gastos". Até aqui o
--  gasto de cada chamada ia só para o log da ponte, que ninguém abre. Daqui
--  para a frente ele fica no banco, uma linha por chamada:
--
--    zorvin_uso_da_ia        a rota (sugerir, ajustar, resumir, aprender,
--                            noite, funil, leitura), o modelo, os quatro
--                            números que a Anthropic devolve (lidos sem
--                            cache, escritos no cache de 5 minutos e no de 1
--                            hora, lidos do cache, escritos na resposta), o
--                            custo estimado em dólares, o tempo e o código da
--                            resposta. Só números: nada do que foi dito
--    zorvin_gasto_da_ia(d)   a soma dos últimos d dias, por dia, rota e
--                            modelo — o que se pergunta para saber onde o
--                            dinheiro vai
--
--  O CUSTO É ESTIMADO PELA PONTE, com a tabela de preços que está no código
--  (`PRECOS_DA_ANTHROPIC`, conferida em 08/11). A conta que vale é a da
--  Anthropic; esta serve para comparar rotas e dias.
--
--  ------------------------------------------------------------
--  QUEM PODE O QUÊ
--
--    - ler: só quem administra (`zorvin_admin()`);
--    - escrever: só a ponte. Ninguém do painel grava, muda ou apaga.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    as tabelas do Zorvin e `zorvin_admin()`. Sem elas, não faz nada, e diz
--    por quê.
-- ============================================================

do $gasto$
declare
  v_anon boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_srv  boolean := exists (select 1 from pg_roles where rolname = 'service_role');
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007:
  -- criada depois, o `select` da última linha estouraria num banco limpo.
  drop table if exists zorvin_conferencia_058;
  create temp table zorvin_conferencia_058 (item text, resposta text);

  if to_regclass('public.usuarios') is null or to_regclass('public.conversas') is null
     or to_regprocedure('public.zorvin_admin()') is null then
    insert into zorvin_conferencia_058 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 058 não fez nada.';
    return;
  end if;

  -- ------------------------------------------------------------
  -- 1. UMA LINHA POR CHAMADA
  -- ------------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_uso_da_ia (
      id                bigint generated always as identity primary key,
      quando            timestamptz not null default now(),
      rota              text not null check (length(rota) <= 40),
      modelo            text not null check (length(modelo) <= 80),
      entrada           integer not null default 0 check (entrada >= 0),
      cache_escrita_5m  integer not null default 0 check (cache_escrita_5m >= 0),
      cache_escrita_1h  integer not null default 0 check (cache_escrita_1h >= 0),
      cache_lida        integer not null default 0 check (cache_lida >= 0),
      saida             integer not null default 0 check (saida >= 0),
      custo_usd         numeric(12, 6),
      ms                integer,
      status            integer
    )
  $x$;
  execute $x$
    comment on table public.zorvin_uso_da_ia is
      'Uma linha por chamada do Quazar à Anthropic: a rota, o modelo, os tokens '
      '(sem cache, escritos no cache, lidos do cache, na resposta) e o custo '
      'estimado. Só números. Só a ponte escreve; quem administra lê.'
  $x$;
  execute 'create index if not exists zorvin_uso_da_ia_quando on public.zorvin_uso_da_ia (quando desc)';

  -- A HERANÇA DA SUPABASE dá tudo a quem entrou e a quem não entrou (a
  -- armadilha nº 5): sai tudo, e volta só a leitura, que a regra de acesso
  -- deixa só para quem administra.
  execute 'alter table public.zorvin_uso_da_ia enable row level security';
  execute 'revoke all on public.zorvin_uso_da_ia from public';
  if v_anon then execute 'revoke all on public.zorvin_uso_da_ia from anon'; end if;
  if v_auth then
    execute 'revoke all on public.zorvin_uso_da_ia from authenticated';
    execute 'grant select on public.zorvin_uso_da_ia to authenticated';
    execute 'drop policy if exists zorvin_uso_da_ia_leitura on public.zorvin_uso_da_ia';
    execute 'create policy zorvin_uso_da_ia_leitura on public.zorvin_uso_da_ia
               for select to authenticated using (public.zorvin_admin())';
  end if;
  if v_srv then execute 'grant all on public.zorvin_uso_da_ia to service_role'; end if;

  -- ------------------------------------------------------------
  -- 2. A SOMA, POR DIA, ROTA E MODELO
  -- ------------------------------------------------------------
  -- NO OLHO DE QUEM PERGUNTA (security invoker): a regra de acesso da tabela
  -- vale lá dentro, e quem não administra recebe uma lista vazia. O dia é o
  -- de Brasília. De 1 a 366 dias, contando hoje.
  execute $x$
    create or replace function public.zorvin_gasto_da_ia(p_dias integer default 30)
    returns jsonb language sql stable security invoker set search_path = public as $f$
      select coalesce(jsonb_agg(jsonb_build_object(
               'dia', t.dia, 'rota', t.rota, 'modelo', t.modelo, 'chamadas', t.chamadas,
               'entrada', t.entrada, 'cache_escrita_5m', t.e5, 'cache_escrita_1h', t.e1,
               'cache_lida', t.lida, 'saida', t.saida, 'custo_usd', t.custo)
               order by t.dia desc, t.custo desc nulls last, t.rota, t.modelo), '[]'::jsonb)
        from (
          select (u.quando at time zone 'America/Sao_Paulo')::date as dia, u.rota, u.modelo,
                 count(*) as chamadas,
                 sum(u.entrada) as entrada, sum(u.cache_escrita_5m) as e5, sum(u.cache_escrita_1h) as e1,
                 sum(u.cache_lida) as lida, sum(u.saida) as saida, sum(u.custo_usd) as custo
            from public.zorvin_uso_da_ia u
           where u.quando >= ((now() at time zone 'America/Sao_Paulo')::date
                              - (greatest(1, least(coalesce(p_dias, 30), 366)) - 1))::timestamp
                             at time zone 'America/Sao_Paulo'
           group by 1, 2, 3
        ) t
    $f$
  $x$;
  execute 'revoke all on function public.zorvin_gasto_da_ia(integer) from public';
  if v_anon then execute 'revoke all on function public.zorvin_gasto_da_ia(integer) from anon'; end if;
  if v_auth then execute 'grant execute on function public.zorvin_gasto_da_ia(integer) to authenticated'; end if;
  if v_srv then execute 'grant execute on function public.zorvin_gasto_da_ia(integer) to service_role'; end if;

  -- ------------------------------------------------------------
  -- 3. A CONFERÊNCIA
  -- ------------------------------------------------------------
  insert into zorvin_conferencia_058
  select 'chamadas anotadas nos últimos 30 dias', count(*)::text
    from public.zorvin_uso_da_ia where quando >= now() - interval '30 days';
  if v_auth then
    insert into zorvin_conferencia_058 values
      ('quem entrou só lê (nada de gravar, mudar ou apagar)',
       (has_table_privilege('authenticated', 'public.zorvin_uso_da_ia', 'select')
        and not has_table_privilege('authenticated', 'public.zorvin_uso_da_ia', 'insert')
        and not has_table_privilege('authenticated', 'public.zorvin_uso_da_ia', 'update')
        and not has_table_privilege('authenticated', 'public.zorvin_uso_da_ia', 'delete')
        and not has_table_privilege('authenticated', 'public.zorvin_uso_da_ia', 'truncate'))::text);
  end if;
  if v_anon then
    insert into zorvin_conferencia_058 values
      ('quem não entrou não alcança nada',
       (not has_table_privilege('anon', 'public.zorvin_uso_da_ia', 'select')
        and not has_function_privilege('anon', 'public.zorvin_gasto_da_ia(integer)', 'execute'))::text);
  end if;
end
$gasto$;

-- ----------------------------------------------------------
--  E A CONFERÊNCIA NO PAPEL DE QUEM ATENDE — a régua 4 do LEIA-ME. A tabela
--  pode estar vazia (a primeira rodada), e zero linhas não provaria nada:
--  uma linha de prova entra, quem não administra tem de ver zero, quem
--  administra tem de vê-la, e a linha sai no fim (o erro de propósito desfaz
--  o bloco; as variáveis guardam o que foi visto).
-- ----------------------------------------------------------
do $conf$
declare
  v_admin    uuid;
  v_atende   integer;
  v_adm      integer;
  v_soma     integer;
  v_etapa    text := 'antes';
  v_resposta text;
begin
  if to_regclass('public.zorvin_uso_da_ia') is null
     or not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;
  select id into v_admin from public.usuarios where admin and coalesce(ativo, true) limit 1;
  begin
    insert into public.zorvin_uso_da_ia (rota, modelo, entrada, saida, custo_usd)
      values ('conferencia-058', 'conferencia-058', 7, 3, 0.000001);
    v_etapa := 'quem atende';
    perform set_config('request.jwt.claim.sub', '', true);
    perform set_config('role', 'authenticated', true);
    execute 'select count(*) from public.zorvin_uso_da_ia where rota = ''conferencia-058''' into v_atende;
    execute 'select jsonb_array_length(public.zorvin_gasto_da_ia(1))' into v_soma;
    execute 'reset role';
    if v_admin is not null then
      v_etapa := 'quem administra';
      perform set_config('request.jwt.claim.sub', v_admin::text, true);
      perform set_config('role', 'authenticated', true);
      execute 'select count(*) from public.zorvin_uso_da_ia where rota = ''conferencia-058''' into v_adm;
      execute 'reset role';
    end if;
    perform set_config('request.jwt.claim.sub', '', true);
    v_etapa := 'fim';
    raise exception 'zorvin-058-desfaz' using errcode = 'P0058';
  exception
    when sqlstate 'P0058' then null;
    when others then
      v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ', em ' || v_etapa || ')';
  end;
  if v_resposta is null then
    v_resposta := case when v_atende = 0 and v_soma = 0 then 'true'
                       else 'NÃO — quem não administra leu ' || coalesce(v_atende, -1) || ' linha(s) e '
                            || coalesce(v_soma, -1) || ' soma(s)' end;
  end if;
  insert into zorvin_conferencia_058 values ('quem atende não lê o gasto', v_resposta);
  if v_admin is not null and v_resposta not like 'NÃO — %código%' then
    insert into zorvin_conferencia_058 values
      ('quem administra lê o gasto',
       case when v_adm = 1 then 'true' else 'NÃO — quem administra leu ' || coalesce(v_adm, -1) || ' linha(s)' end);
  end if;
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_058;
