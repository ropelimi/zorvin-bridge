-- ============================================================
--  065. A RETOMADA DA FAXINA SÓ ONDE SE ESCOLHE (25/11)
--
--  >>> A PONTE APLICA SOZINHA (sql/automaticos). <<<
--  Pode rodar de novo sem medo — a pasta inteira, na ordem (regra 5).
--
--  ------------------------------------------------------------
--  O PEDIDO
--
--  A faxina do Quazar (064) manda, a quem espera resposta há 30 dias ou
--  mais, uma mensagem pedindo desculpas pela demora — em todos os telefones.
--  Nas primeiras horas, as nove conversas marcadas para receber essa
--  mensagem eram de Acordos e do Interno: linhas de advogados, onde o
--  cliente fala com o advogado dele, e boa parte com a parte contrária de
--  um processo. Rodrigo, em 25/11: "Vamos seguir com a sua recomendação: a
--  mensagem de retomada só no Sucesso do Cliente e no Comercial. Nos outros
--  telefones, as conversas que já acabaram continuam sendo finalizadas, e
--  as pendentes ficam para a pessoa."
--
--  ------------------------------------------------------------
--  O QUE ESTE SCRIPT FAZ
--
--    zorvin_faxina_retomada            por departamento: a retomada ligada
--                                      ou não. SEM LINHA, NÃO MANDA: o que
--                                      fala com o cliente nasce desligado.
--    a semente                         liga o Sucesso do Cliente e o
--                                      Comercial, uma vez só (desligados
--                                      depois, rodar de novo não religa)
--    zorvin_faxina_retomadas_da_vez()  só escolhe as conversas dos
--                                      departamentos ligados
--    zorvin_faxina_para_ler()          diz, em cada conversa, se o
--                                      departamento manda a retomada
--                                      (`retoma`): fora dele, a ponte guarda
--                                      a decisão como 'pendente', e não
--                                      'retomar'
--    a instalação                      as que esperavam a vez fora dos
--                                      departamentos ligados viram
--                                      'pendente' (em toda rodada: só acha o
--                                      que ficou fora da regra)
--
--  O QUE NÃO MUDA: o silêncio de 7 dias e a leitura do Quazar continuam
--  valendo no escritório todo. O "obrigado" e a propaganda são finalizados
--  em qualquer telefone; a pendente fica para a pessoa.
--
--  AINDA NÃO HÁ TELA para ligar e desligar: por enquanto, pelo conector do
--  Supabase, a pedido do Rodrigo. A tabela é só da ponte (RLS ligada, sem
--  política), como o registro da faxina.
--
--  A VERSÃO DE REFERÊNCIA (regra 5) de zorvin_faxina_retomadas_da_vez e de
--  zorvin_faxina_para_ler passa a ser a deste script: o 064 rodado de novo
--  depois dele as devolve sem o filtro, e este, na ordem da pasta, as põe de
--  volta.
--
--  DEPENDE DE JÁ TER RODADO: 064 (e o 025, que ele já pede).
-- ============================================================

do $ret$
declare
  v_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_anon boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_srv  boolean := exists (select 1 from pg_roles where rolname = 'service_role');
  f      text;
  v_n    integer;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_065;
  create temp table zorvin_conferencia_065 (item text, resposta text);

  if to_regclass('public.conversas') is null or to_regclass('public.advogados') is null
     or to_regclass('public.departamentos') is null then
    insert into zorvin_conferencia_065 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 065 não fez nada.';
    return;
  end if;
  if to_regclass('public.zorvin_quazar_faxina') is null
     or to_regprocedure('public.zorvin_faxina_retomadas_da_vez(integer, integer, integer)') is null
     or to_regprocedure('public.zorvin_faxina_para_ler(integer, integer)') is null
     or to_regprocedure('public.zorvin_chave_do_assunto(text)') is null then
    insert into zorvin_conferencia_065 values ('NÃO — falta o 064', 'rode-o antes');
    raise notice 'Zorvin: script 065 precisa do 064.';
    return;
  end if;

  -- ------------------------------------------------------------
  -- 1. ONDE A RETOMADA SAI. Só a ponte (e o conector) alcança.
  -- ------------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_faxina_retomada (
      departamento_id bigint primary key references public.departamentos(id) on delete cascade,
      ligada          boolean not null default false,
      atualizado_em   timestamptz not null default now()
    )$x$;
  execute 'alter table public.zorvin_faxina_retomada enable row level security';
  if v_anon then execute 'revoke all on public.zorvin_faxina_retomada from anon'; end if;
  if v_auth then execute 'revoke all on public.zorvin_faxina_retomada from authenticated'; end if;
  if v_srv then execute 'grant all on public.zorvin_faxina_retomada to service_role'; end if;

  -- ------------------------------------------------------------
  -- 2. A SEMENTE: o Sucesso do Cliente e o Comercial, uma vez só (regra 5).
  --    Pelo `slug` (sdc, comercial) ou pelo nome sem acento: o `slug` foi
  --    criado à mão e não está em script nenhum, e por isso vem por to_jsonb.
  -- ------------------------------------------------------------
  execute 'create table if not exists public.zorvin_sementes (
             chave text primary key, plantada_em timestamptz not null default now())';
  execute 'alter table public.zorvin_sementes enable row level security';
  if v_anon then execute 'revoke all on public.zorvin_sementes from anon'; end if;
  if v_auth then execute 'revoke all on public.zorvin_sementes from authenticated'; end if;
  if not exists (select 1 from public.zorvin_sementes where chave = 'faxina:retomada-sdc-comercial-065') then
    insert into public.zorvin_faxina_retomada (departamento_id, ligada)
    select d.id, true from public.departamentos d
     where coalesce(to_jsonb(d) ->> 'slug', '') in ('sdc', 'comercial')
        or public.zorvin_chave_do_assunto(d.nome) in ('sucesso do cliente', 'comercial')
    on conflict (departamento_id) do nothing;
    insert into public.zorvin_sementes (chave) values ('faxina:retomada-sdc-comercial-065') on conflict do nothing;
  end if;

  -- ------------------------------------------------------------
  -- 3. O QUE O QUAZAR LÊ, agora dizendo se o departamento manda a retomada.
  --    Igual à do 064, mais o `retoma`.
  -- ------------------------------------------------------------
  execute $x$
create or replace function public.zorvin_faxina_para_ler(p_limite integer default 10, p_dias integer default 2)
returns jsonb language sql stable security definer set search_path = public as $f$
  select coalesce(jsonb_agg(jsonb_build_object(
           'conversa_id', x.id, 'advogado_id', x.advogado_id, 'cliente_ate_id', x.msg_id,
           'cliente_ate', x.msg_em, 'esperando_desde', x.esperando_desde,
           'dias', floor(extract(epoch from now() - x.esperando_desde) / 86400)::int,
           'retoma', x.retoma)
         order by x.esperando_desde), '[]'::jsonb)
    from (
      select c.id, c.advogado_id, c.esperando_desde, uc.id as msg_id, uc.criado_em as msg_em,
             exists (select 1 from public.zorvin_faxina_retomada r
                      where r.departamento_id = a.departamento_id and r.ligada) as retoma
        from public.conversas c
        join public.advogados a on a.id = c.advogado_id
        join public.contatos ct on ct.id = c.contato_id
        cross join lateral (select m.id, m.criado_em from public.mensagens m
                             where m.conversa_id = c.id and m.origem = 'contato'
                             order by m.criado_em desc, m.id desc limit 1) uc
       where c.situacao is distinct from 'finalizado'
         and coalesce((to_jsonb(c) ->> 'arquivada')::boolean, false) = false
         and c.esperando_desde is not null
         and c.esperando_desde < now() - make_interval(days => greatest(p_dias, 0))
         and ct.numero not like 'grupo:%'
         and a.ativo is not false
         and not exists (select 1 from public.fila_envio f
                          where f.conversa_id = c.id and f.status in ('pendente', 'enviando'))
         and not exists (select 1 from public.zorvin_quazar_faxina q
                          where q.conversa_id = c.id and q.cliente_ate_id = uc.id)
       order by c.esperando_desde
       limit greatest(least(p_limite, 2000), 0)
    ) x
$f$$x$;

  -- ------------------------------------------------------------
  -- 4. AS RETOMADAS DA VEZ: as do 064, só nos departamentos ligados.
  -- ------------------------------------------------------------
  execute $x$
create or replace function public.zorvin_faxina_retomadas_da_vez(
  p_por_hora integer default 6, p_limite integer default 10, p_dias integer default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $f$
declare
  v_out    jsonb := '[]'::jsonb;
  r        record;
  v_aberto boolean;
  v_local  timestamp;
  v_ja     integer;
begin
  for r in
    select q.id, q.conversa_id, q.advogado_id, q.esperando_desde, q.nome_para_saudar,
           f.semana, coalesce(nullif(btrim(f.fuso), ''), 'America/Sao_Paulo') as fuso
      from public.zorvin_quazar_faxina q
      join public.conversas c on c.id = q.conversa_id
      join public.advogados a on a.id = c.advogado_id
      -- SÓ ONDE A RETOMADA ESTÁ LIGADA (sem linha, não manda).
      join public.zorvin_faxina_retomada rt on rt.departamento_id = a.departamento_id and rt.ligada
      left join public.zorvin_fora_do_horario f on f.departamento_id = a.departamento_id
      join public.mensagens um on um.id = q.cliente_ate_id
     where (q.status = 'retomar'
            or (q.status = 'pendente' and q.esperando_desde < now() - make_interval(days => greatest(p_dias, 1))))
       and c.situacao is distinct from 'finalizado'
       and coalesce((to_jsonb(c) ->> 'arquivada')::boolean, false) = false
       -- O CLIENTE AINDA ESPERA: a equipe que respondeu depois da leitura
       -- tirou a conversa da espera, e "desculpe a demora" seria fora de hora.
       and c.esperando_desde is not null
       and a.ativo is not false
       and not exists (select 1 from public.mensagens m
                        where m.conversa_id = q.conversa_id and m.origem = 'contato'
                          and (m.criado_em, m.id) > (um.criado_em, um.id))
       and not exists (select 1 from public.fila_envio fe
                        where fe.conversa_id = q.conversa_id and fe.status in ('pendente', 'enviando'))
     order by q.esperando_desde
  loop
    exit when jsonb_array_length(v_out) >= greatest(p_limite, 0);
    if r.semana is not null then
      v_aberto := coalesce((public.zorvin_horario_de(r.semana, r.fuso, now()) ->> 'aberto')::boolean, false);
    else
      v_local := now() at time zone 'America/Sao_Paulo';
      v_aberto := extract(isodow from v_local) between 1 and 5
                  and v_local::time >= time '08:00' and v_local::time < time '18:00'
                  and not exists (select 1 from public.zorvin_feriados h where h.dia = v_local::date);
    end if;
    continue when not v_aberto;
    select count(*) into v_ja from public.zorvin_quazar_faxina x
     where x.advogado_id = r.advogado_id and x.retomada_em > now() - interval '1 hour';
    v_ja := v_ja + (select count(*) from jsonb_array_elements(v_out) e
                     where e ->> 'advogado_id' = r.advogado_id::text);
    continue when v_ja >= greatest(p_por_hora, 0);
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id', r.id, 'conversa_id', r.conversa_id, 'advogado_id', r.advogado_id,
      'esperando_desde', r.esperando_desde, 'nome', coalesce(r.nome_para_saudar, ''),
      'fuso', r.fuso));
  end loop;
  return v_out;
end
$f$$x$;

  -- ------------------------------------------------------------
  -- 5. AS QUE ESPERAVAM A VEZ FORA DOS DEPARTAMENTOS LIGADOS ficam para a
  --    pessoa ('pendente'). Em toda rodada: só acha o que ficou fora da regra.
  -- ------------------------------------------------------------
  update public.zorvin_quazar_faxina q
     set status = 'pendente'
    from public.conversas c
    join public.advogados a on a.id = c.advogado_id
   where c.id = q.conversa_id
     and q.status = 'retomar'
     and not exists (select 1 from public.zorvin_faxina_retomada r
                      where r.departamento_id = a.departamento_id and r.ligada);
  get diagnostics v_n = row_count;

  -- ------------------------------------------------------------
  -- 6. SÓ A PONTE CHAMA (create or replace guarda as permissões; ditas de
  --    novo pela armadilha nº 5).
  -- ------------------------------------------------------------
  foreach f in array array[
    'public.zorvin_faxina_para_ler(integer, integer)',
    'public.zorvin_faxina_retomadas_da_vez(integer, integer, integer)'] loop
    execute format('revoke all on function %s from public', f);
    if v_anon then execute format('revoke all on function %s from anon', f); end if;
    if v_auth then execute format('revoke all on function %s from authenticated', f); end if;
    if v_srv then execute format('grant execute on function %s to service_role', f); end if;
  end loop;

  -- ------------------------------------------------------------
  -- A CONFERÊNCIA
  -- ------------------------------------------------------------
  insert into zorvin_conferencia_065
  select 'departamentos com a retomada ligada',
         coalesce((select string_agg(d.nome, ', ' order by d.nome) from public.zorvin_faxina_retomada r
                     join public.departamentos d on d.id = r.departamento_id where r.ligada), 'nenhum');
  insert into zorvin_conferencia_065 values
    ('retomadas que esperavam a vez fora deles e ficaram para a pessoa', v_n::text);
  insert into zorvin_conferencia_065
  select 'nenhuma conversa marcada para retomar fora dos departamentos ligados',
         (not exists (select 1 from public.zorvin_quazar_faxina q
                        join public.conversas c on c.id = q.conversa_id
                        join public.advogados a on a.id = c.advogado_id
                       where q.status = 'retomar'
                         and not exists (select 1 from public.zorvin_faxina_retomada r
                                          where r.departamento_id = a.departamento_id and r.ligada)))::text;
  if v_auth then
    insert into zorvin_conferencia_065 values
      ('quem entrou não lê nem muda onde a retomada sai',
       (not has_table_privilege('authenticated', 'public.zorvin_faxina_retomada', 'select')
        and not has_table_privilege('authenticated', 'public.zorvin_faxina_retomada', 'update'))::text),
      ('quem entrou não chama as retomadas da vez',
       (not has_function_privilege('authenticated', 'public.zorvin_faxina_retomadas_da_vez(integer, integer, integer)', 'execute'))::text);
  end if;
  if v_anon then
    insert into zorvin_conferencia_065 values
      ('quem não entrou não alcança onde a retomada sai',
       (not has_table_privilege('anon', 'public.zorvin_faxina_retomada', 'select'))::text);
  end if;
end
$ret$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_065;
