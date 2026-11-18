-- ============================================================
--  A SUGESTÃO DO QUAZAR FICA MARCADA, E TEM RELATÓRIO
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  A ponte aplica sozinha ao subir (sql/automaticos). Pode rodar de novo sem
--  medo — na ordem da pasta, como diz a regra 5 do LEIA-ME.
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido do Rodrigo em 18/11: "Quando for usado o 'Sugerir resposta' eu
--  preciso saber que o usuário usou essa opção, tem que aparecer de alguma
--  forma discretamente na mensagem (apenas para a equipe, não para o
--  contato). Preciso também de um relatório para isso."
--
--    fila_envio.sugestao_quazar   'igual' (saiu como o Quazar escreveu) ou
--    mensagens.sugestao_quazar    'editada' (a pessoa mexeu antes de mandar).
--                                 Nulo: a mensagem foi escrita sem ele. Quem
--                                 marca é o painel, na fila; a ponte copia
--                                 para a mensagem ao gravá-la. O cliente não
--                                 recebe nada disto: é só uma coluna
--    zorvin_sugestoes             um "Sugerir resposta" (ou um "Pedir uma
--                                 mudança") que deu certo: quem pediu, em qual
--                                 conversa e quando. Só a ponte escreve. É o
--                                 que dá para saber quantas sugestões foram
--                                 pedidas e não usadas
--    zorvin_relatorio_sugestoes   o relatório do Painel de números: pedidas,
--                                 usadas (sem mudança e editadas), quanto das
--                                 mensagens escritas por cada pessoa saiu com
--                                 o Quazar, por pessoa e por dia
--
--  ------------------------------------------------------------
--  QUEM VÊ O QUÊ
--
--    - quem administra vê o relatório de todo mundo; quem atende, o dela
--      (o recorte é feito aqui, como no "Já tratei");
--    - `security invoker`: cada pessoa conta só as conversas que vê;
--    - a arquivada não conta (a régua do 057);
--    - os pedidos (`zorvin_sugestoes`): quem administra lê todos; quem
--      atende, os seus. Ninguém do painel escreve.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    as tabelas do Zorvin, `zorvin_admin()`, e em `mensagens` as colunas de
--    quem enviou (`enviado_por_id`, de agosto) e do automático (037). Sem
--    elas, não faz nada e diz qual falta.
-- ============================================================

do $sug$
declare
  v_anon boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_srv  boolean := exists (select 1 from pg_roles where rolname = 'service_role');
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA (a lição do 006).
  drop table if exists zorvin_conferencia_060;
  create temp table zorvin_conferencia_060 (item text, resposta text);

  if to_regclass('public.usuarios') is null or to_regclass('public.conversas') is null
     or to_regclass('public.mensagens') is null or to_regclass('public.fila_envio') is null
     or to_regclass('public.advogados') is null
     or to_regprocedure('public.zorvin_admin()') is null then
    insert into zorvin_conferencia_060 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 060 não fez nada.';
    return;
  end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public'
                  and table_name = 'mensagens' and column_name = 'enviado_por_id')
     or not exists (select 1 from information_schema.columns where table_schema = 'public'
                  and table_name = 'mensagens' and column_name = 'automatica') then
    insert into zorvin_conferencia_060 values
      ('falta quem enviou ou o automático em mensagens', 'NÃO — rode o SQL de agosto (enviado_por_id) e o 037 antes');
    return;
  end if;

  -- ------------------------------------------------------------
  -- 1. A MARCA, NA FILA E NA MENSAGEM
  -- ------------------------------------------------------------
  execute 'alter table public.fila_envio add column if not exists sugestao_quazar text';
  execute 'alter table public.mensagens  add column if not exists sugestao_quazar text';
  if not exists (select 1 from pg_constraint where conname = 'fila_envio_sugestao_quazar_valida') then
    execute $x$alter table public.fila_envio add constraint fila_envio_sugestao_quazar_valida
               check (sugestao_quazar is null or sugestao_quazar in ('igual', 'editada'))$x$;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'mensagens_sugestao_quazar_valida') then
    execute $x$alter table public.mensagens add constraint mensagens_sugestao_quazar_valida
               check (sugestao_quazar is null or sugestao_quazar in ('igual', 'editada'))$x$;
  end if;
  execute $x$create index if not exists mensagens_sugestao_quazar_idx
             on public.mensagens (criado_em) where sugestao_quazar is not null$x$;

  -- ------------------------------------------------------------
  -- 2. OS PEDIDOS
  -- ------------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_sugestoes (
      id           bigint generated always as identity primary key,
      quando       timestamptz not null default now(),
      quem         uuid references public.usuarios(id) on delete set null,
      conversa_id  uuid references public.conversas(id) on delete cascade,
      tipo         text not null default 'sugerir' check (tipo in ('sugerir', 'ajustar'))
    )
  $x$;
  execute $x$
    comment on table public.zorvin_sugestoes is
      'Um "Sugerir resposta" (ou "Pedir uma mudança") do Quazar que deu certo: '
      'quem pediu, em qual conversa e quando. Só a ponte escreve.'
  $x$;
  execute 'create index if not exists zorvin_sugestoes_quando on public.zorvin_sugestoes (quando)';

  -- A HERANÇA DA SUPABASE dá tudo a todo mundo (a armadilha nº 5): sai tudo,
  -- e volta só a leitura, que a regra deixa para quem administra e para a
  -- própria pessoa.
  execute 'alter table public.zorvin_sugestoes enable row level security';
  execute 'revoke all on public.zorvin_sugestoes from public';
  if v_anon then execute 'revoke all on public.zorvin_sugestoes from anon'; end if;
  if v_auth then
    execute 'revoke all on public.zorvin_sugestoes from authenticated';
    execute 'grant select on public.zorvin_sugestoes to authenticated';
    execute 'drop policy if exists zorvin_sugestoes_leitura on public.zorvin_sugestoes';
    execute 'create policy zorvin_sugestoes_leitura on public.zorvin_sugestoes
               for select to authenticated using (public.zorvin_admin() or quem = auth.uid())';
  end if;
  if v_srv then execute 'grant all on public.zorvin_sugestoes to service_role'; end if;

  -- ------------------------------------------------------------
  -- 3. O RELATÓRIO
  -- ------------------------------------------------------------
  -- "Escritas" são as mensagens de texto que alguém da equipe mandou pelo
  -- painel (com `enviado_por_id`, e não automáticas). "Usadas" são as que
  -- saíram com a marca. O período anterior, do mesmo tamanho, vem para
  -- comparar as usadas e as pedidas.
  execute $x$
create or replace function public.zorvin_relatorio_sugestoes(
  p_desde        timestamptz default null,
  p_ate          timestamptz default null,
  p_quem         uuid        default null,
  p_fuso         text        default 'America/Sao_Paulo',
  p_telefone     uuid        default null,
  p_departamento bigint      default null
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $fn$
declare
  v_ate   timestamptz := coalesce(p_ate, now());
  v_desde timestamptz := coalesce(p_desde, now() - interval '30 days');
  v_antes timestamptz;
  v_quem  uuid := p_quem;
  v_so_meu boolean := false;
  v_fuso  text := coalesce(p_fuso, 'America/Sao_Paulo');
  v_saida jsonb;
begin
  if not public.zorvin_admin() then v_quem := auth.uid(); v_so_meu := true; end if;
  if not exists (select 1 from pg_timezone_names where name = v_fuso) then v_fuso := 'America/Sao_Paulo'; end if;
  v_antes := v_desde - (v_ate - v_desde);

  with msgs as (
    select m.enviado_por_id as quem, m.criado_em as quando, m.sugestao_quazar as marca
      from public.mensagens m
      join public.conversas c on c.id = m.conversa_id
      left join public.advogados a on a.id = c.advogado_id
     where m.criado_em >= v_antes and m.criado_em <= v_ate
       and m.origem = 'advogado' and m.tipo = 'texto'
       and m.enviado_por_id is not null and not coalesce(m.automatica, false)
       and not coalesce(c.arquivada, false)
       and (p_telefone is null or c.advogado_id = p_telefone)
       and (p_departamento is null or a.departamento_id = p_departamento)
       and (v_quem is null or m.enviado_por_id = v_quem)
  ),
  peds as (
    select s.quem, s.quando, s.tipo
      from public.zorvin_sugestoes s
      join public.conversas c on c.id = s.conversa_id
      left join public.advogados a on a.id = c.advogado_id
     where s.quando >= v_antes and s.quando <= v_ate
       and not coalesce(c.arquivada, false)
       and (p_telefone is null or c.advogado_id = p_telefone)
       and (p_departamento is null or a.departamento_id = p_departamento)
       and (v_quem is null or s.quem = v_quem)
  ),
  agora_m as (select * from msgs where quando >= v_desde),
  agora_p as (select * from peds where quando >= v_desde),
  pessoas as (
    select quem from agora_m where marca is not null
    union select quem from agora_p where quem is not null
  )
  select jsonb_build_object(
    'so_meu', v_so_meu,
    'total', jsonb_build_object(
      'pedidas',  (select count(*) from agora_p where tipo = 'sugerir'),
      'ajustes',  (select count(*) from agora_p where tipo = 'ajustar'),
      'usadas',   (select count(*) from agora_m where marca is not null),
      'iguais',   (select count(*) from agora_m where marca = 'igual'),
      'editadas', (select count(*) from agora_m where marca = 'editada'),
      'escritas', (select count(*) from agora_m)),
    'antes', case when p_desde is null then null else jsonb_build_object(
      'pedidas', (select count(*) from peds where quando < v_desde and tipo = 'sugerir'),
      'usadas',  (select count(*) from msgs where quando < v_desde and marca is not null)) end,
    'por_pessoa', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.quem, 'nome', coalesce(u.nome, '(sem nome)'),
               'pedidas',  (select count(*) from agora_p x where x.quem = p.quem and x.tipo = 'sugerir'),
               'ajustes',  (select count(*) from agora_p x where x.quem = p.quem and x.tipo = 'ajustar'),
               'usadas',   (select count(*) from agora_m x where x.quem = p.quem and x.marca is not null),
               'iguais',   (select count(*) from agora_m x where x.quem = p.quem and x.marca = 'igual'),
               'editadas', (select count(*) from agora_m x where x.quem = p.quem and x.marca = 'editada'),
               'escritas', (select count(*) from agora_m x where x.quem = p.quem))
             order by (select count(*) from agora_m x where x.quem = p.quem and x.marca is not null) desc,
                      coalesce(u.nome, ''))
        from pessoas p left join public.usuarios u on u.id = p.quem), '[]'::jsonb),
    'por_dia', coalesce((
      select jsonb_agg(jsonb_build_object('dia', d.dia, 'pedidas', d.pedidas, 'iguais', d.iguais,
                                          'editadas', d.editadas) order by d.dia)
        from (select dia, sum(pedidas)::int as pedidas, sum(iguais)::int as iguais, sum(editadas)::int as editadas
                from (select (quando at time zone v_fuso)::date as dia, 0 as pedidas,
                             (marca = 'igual')::int as iguais, (marca = 'editada')::int as editadas
                        from agora_m where marca is not null
                      union all
                      select (quando at time zone v_fuso)::date, 1, 0, 0 from agora_p where tipo = 'sugerir') z
               group by dia) d), '[]'::jsonb)
  ) into v_saida;
  return v_saida;
end
$fn$
  $x$;
  execute 'revoke all on function public.zorvin_relatorio_sugestoes(timestamptz, timestamptz, uuid, text, uuid, bigint) from public';
  if v_anon then execute 'revoke all on function public.zorvin_relatorio_sugestoes(timestamptz, timestamptz, uuid, text, uuid, bigint) from anon'; end if;
  if v_auth then execute 'grant execute on function public.zorvin_relatorio_sugestoes(timestamptz, timestamptz, uuid, text, uuid, bigint) to authenticated'; end if;
  if v_srv then execute 'grant execute on function public.zorvin_relatorio_sugestoes(timestamptz, timestamptz, uuid, text, uuid, bigint) to service_role'; end if;

  -- ------------------------------------------------------------
  -- 4. A CONFERÊNCIA
  -- ------------------------------------------------------------
  insert into zorvin_conferencia_060 values
    ('a fila e as mensagens têm a marca da sugestão',
     (select count(*) = 2 from information_schema.columns where table_schema = 'public'
       and column_name = 'sugestao_quazar' and table_name in ('fila_envio', 'mensagens'))::text);
  if v_auth then
    insert into zorvin_conferencia_060 values
      ('quem entrou grava a marca na fila, e só lê os pedidos',
       (has_column_privilege('authenticated', 'public.fila_envio', 'sugestao_quazar', 'insert')
        and has_table_privilege('authenticated', 'public.zorvin_sugestoes', 'select')
        and not has_table_privilege('authenticated', 'public.zorvin_sugestoes', 'insert')
        and not has_table_privilege('authenticated', 'public.zorvin_sugestoes', 'update')
        and not has_table_privilege('authenticated', 'public.zorvin_sugestoes', 'delete'))::text);
  end if;
  if v_anon then
    insert into zorvin_conferencia_060 values
      ('quem não entrou não alcança nada',
       (not has_table_privilege('anon', 'public.zorvin_sugestoes', 'select')
        and not has_function_privilege('anon',
          'public.zorvin_relatorio_sugestoes(timestamptz, timestamptz, uuid, text, uuid, bigint)', 'execute'))::text);
  end if;
  insert into zorvin_conferencia_060
  select 'mensagens marcadas nos últimos 30 dias', count(*)::text
    from public.mensagens where sugestao_quazar is not null and criado_em >= now() - interval '30 days';
end
$sug$;

-- ----------------------------------------------------------
--  O RELATÓRIO NO PAPEL DE QUEM ATENDE — a régua 4 do LEIA-ME: a função tem
--  de rodar para quem entrou, e não só para a dona do banco.
-- ----------------------------------------------------------
do $conf$
declare
  v_quem uuid;
  v_r    jsonb;
  v_resposta text;
begin
  if to_regprocedure('public.zorvin_relatorio_sugestoes(timestamptz, timestamptz, uuid, text, uuid, bigint)') is null
     or not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;
  select id into v_quem from public.usuarios where not admin and coalesce(ativo, true) limit 1;
  begin
    perform set_config('request.jwt.claim.sub', coalesce(v_quem::text, ''), true);
    perform set_config('role', 'authenticated', true);
    execute 'select public.zorvin_relatorio_sugestoes(now() - interval ''7 days'', now(), null, ''America/Sao_Paulo'', null, null)' into v_r;
    execute 'reset role';
    perform set_config('request.jwt.claim.sub', '', true);
    v_resposta := case when (v_r ->> 'so_meu')::boolean and v_r ? 'total' then 'true'
                       else 'NÃO — a resposta não veio recortada: ' || left(v_r::text, 120) end;
  exception when others then
    execute 'reset role';
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;
  insert into zorvin_conferencia_060 values ('quem atende abre o relatório, só com o que é dela', v_resposta);
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_060;
