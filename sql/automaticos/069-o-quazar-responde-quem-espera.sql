-- ============================================================
--  069. O QUAZAR RESPONDE QUEM ESPERA (25/11)
--
--  >>> A PONTE APLICA SOZINHA (sql/automaticos). <<<
--  Pode rodar de novo sem medo — a pasta inteira, na ordem (regra 5).
--
--  ------------------------------------------------------------
--  O PEDIDO
--
--  A faxina do Quazar (064) lê as conversas em que o cliente espera
--  resposta há 2 dias ou mais. O que ele lê como "pendente" (o cliente
--  perguntou, pediu, mandou um documento) ficava para a equipe. Rodrigo, em
--  25/11, sobre isso: "o Quazar o responde e resolve". Decidido com ele: no
--  Sucesso do Cliente e no Comercial, e já valendo (a mensagem vai ao
--  cliente, pedindo desculpas pela demora).
--
--  ------------------------------------------------------------
--  O QUE ESTE SCRIPT FAZ
--
--    zorvin_quazar_responde            por departamento: o Quazar responde
--                                      ou não. SEM LINHA, NÃO RESPONDE: o
--                                      que fala com o cliente nasce
--                                      desligado.
--    a semente                         liga o Sucesso do Cliente e o
--                                      Comercial, uma vez só (desligados
--                                      depois, rodar de novo não religa)
--    as colunas `resposta*` no         o andamento da resposta: 'pensando'
--    registro da faxina                (a ponte reservou a vez), 'na_fila',
--                                      'calada' (ele leu de novo e não
--                                      respondeu), 'saiu', 'finalizou',
--                                      'nao_saiu'
--    zorvin_quazar_responde_pendentes  quem ele pode responder agora — só a
--                                      ponte chama
--    zorvin_quazar_responde_confirmar  a resposta que SAIU: resolvida e de
--                                      quem não pede atenção, finaliza
--                                      (DÚVIDAS TRATADAS); o resto fica
--                                      aberto para a equipe — só a ponte
--    zorvin_faxina_retomadas_da_vez    a do 066, sem os departamentos em que
--                                      o Quazar responde: lá a resposta de
--                                      verdade toma o lugar do "você ainda
--                                      precisa de ajuda?"
--
--  QUEM ELE RESPONDE (o banco diz, e não a ponte):
--    - a conversa que a faxina leu como 'pendente' (ou 'retomar');
--    - num departamento ligado, no expediente dele (a semana da aba Fora do
--      horário, com os feriados; sem a semana, de segunda a sexta, das 8h às
--      18h de Brasília);
--    - a conversa aberta, não arquivada, sem grupo, de linha ativa, com o
--      cliente esperando (`esperando_desde`), a última mensagem dele ainda a
--      que o Quazar leu, nada saindo na fila, e sem resposta do Quazar à
--      noite depois dela;
--    - UMA RESPOSTA POR ESPERA: o que o cliente escrever depois da resposta
--      do Quazar fica para a equipe (ou, se a conversa foi finalizada, para a
--      espera seguinte);
--    - no máximo `p_por_hora` respostas por telefone por hora, as mais
--      antigas primeiro.
--
--  O QUE ACONTECE DEPOIS QUE SAI (`zorvin_quazar_responde_confirmar`):
--    - a ponte diz se a resposta RESOLVEU (respondeu por inteiro o que o
--      cliente pediu, sem sobrar nada para a equipe). Resolvida, e de quem
--      não pede atenção (066), a conversa é finalizada em DÚVIDAS TRATADAS,
--      pelo Quazar — e o cliente que escrever de novo a reabre (028);
--    - não resolvida, ou de quem tem OS aberta ou blindagem por fazer, fica
--      aberta: a mensagem do Quazar é automática (037, 059) e não tira o
--      cliente da espera. Quem pede atenção recebe a nota e a tarefa do 068;
--    - a resposta que não saiu (erro, descartada) fica 'nao_saiu', e a
--      conversa fica para a equipe.
--
--  A VERSÃO DE REFERÊNCIA (regra 5) de zorvin_faxina_retomadas_da_vez passa
--  a ser a deste script: o 066 rodado de novo depois dele a devolve sem o
--  filtro, e este, na ordem da pasta, a põe de volta.
--
--  DEPENDE DE JÁ TER RODADO: 021, 028, 064, 065 e 066.
-- ============================================================

do $resp$
declare
  v_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_anon boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_srv  boolean := exists (select 1 from pg_roles where rolname = 'service_role');
  f      text;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_069;
  create temp table zorvin_conferencia_069 (item text, resposta text);

  if to_regclass('public.conversas') is null or to_regclass('public.advogados') is null
     or to_regclass('public.departamentos') is null or to_regclass('public.mensagens') is null
     or to_regclass('public.fila_envio') is null then
    insert into zorvin_conferencia_069 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 069 não fez nada.';
    return;
  end if;
  if to_regclass('public.zorvin_quazar_faxina') is null
     or to_regclass('public.zorvin_faxina_retomada') is null
     or to_regclass('public.zorvin_fora_do_horario') is null
     or to_regprocedure('public.zorvin_pede_atencao(uuid)') is null
     or to_regprocedure('public.zorvin_atencao_fresca(integer)') is null
     or to_regprocedure('public.zorvin_faxina_finalizar(uuid, text, text, uuid)') is null
     or to_regprocedure('public.zorvin_horario_de(jsonb, text, timestamp with time zone)') is null
     or to_regprocedure('public.zorvin_chave_do_assunto(text)') is null then
    insert into zorvin_conferencia_069 values ('NÃO — falta o 021, o 064, o 065 ou o 066', 'rode-os antes');
    raise notice 'Zorvin: script 069 precisa do 021, do 064, do 065 e do 066.';
    return;
  end if;

  -- ------------------------------------------------------------
  -- 1. ONDE O QUAZAR RESPONDE. Só a ponte (e o conector) alcança.
  -- ------------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_quazar_responde (
      departamento_id bigint primary key references public.departamentos(id) on delete cascade,
      ligado          boolean not null default false,
      atualizado_em   timestamptz not null default now()
    )$x$;
  execute 'alter table public.zorvin_quazar_responde enable row level security';
  if v_anon then execute 'revoke all on public.zorvin_quazar_responde from anon'; end if;
  if v_auth then execute 'revoke all on public.zorvin_quazar_responde from authenticated'; end if;
  if v_srv then execute 'grant all on public.zorvin_quazar_responde to service_role'; end if;

  -- ------------------------------------------------------------
  -- 2. A SEMENTE: o Sucesso do Cliente e o Comercial, uma vez só (regra 5).
  --    Pelo `slug` (sdc, comercial) ou pelo nome sem acento, como no 065.
  -- ------------------------------------------------------------
  execute 'create table if not exists public.zorvin_sementes (
             chave text primary key, plantada_em timestamptz not null default now())';
  execute 'alter table public.zorvin_sementes enable row level security';
  if v_anon then execute 'revoke all on public.zorvin_sementes from anon'; end if;
  if v_auth then execute 'revoke all on public.zorvin_sementes from authenticated'; end if;
  if not exists (select 1 from public.zorvin_sementes where chave = 'quazar:responde-quem-espera-069') then
    insert into public.zorvin_quazar_responde (departamento_id, ligado)
    select d.id, true from public.departamentos d
     where coalesce(to_jsonb(d) ->> 'slug', '') in ('sdc', 'comercial')
        or public.zorvin_chave_do_assunto(d.nome) in ('sucesso do cliente', 'comercial')
    on conflict (departamento_id) do nothing;
    insert into public.zorvin_sementes (chave) values ('quazar:responde-quem-espera-069') on conflict do nothing;
  end if;

  -- ------------------------------------------------------------
  -- 3. O ANDAMENTO DA RESPOSTA, no registro da faxina (que já é só da ponte).
  --    `respondida_em` é quando a resposta entrou na fila: é por ela que a
  --    conta por hora e a "uma resposta por espera" contam.
  -- ------------------------------------------------------------
  execute $x$
    alter table public.zorvin_quazar_faxina
      add column if not exists resposta text
        check (resposta in ('pensando', 'na_fila', 'calada', 'saiu', 'finalizou', 'nao_saiu')),
      add column if not exists resposta_em       timestamptz,
      add column if not exists respondida_em     timestamptz,
      add column if not exists resposta_fila_id  uuid,
      add column if not exists resposta_resolveu boolean,
      add column if not exists resposta_resumo   text check (length(resposta_resumo) <= 1000)
  $x$;
  execute 'create index if not exists zorvin_quazar_faxina_respondida
             on public.zorvin_quazar_faxina (advogado_id, respondida_em) where respondida_em is not null';

  -- ------------------------------------------------------------
  -- 4. QUEM ELE PODE RESPONDER AGORA.
  -- ------------------------------------------------------------
  execute $x$
create or replace function public.zorvin_quazar_responde_pendentes(
  p_limite integer default 10, p_por_hora integer default 10)
returns jsonb language plpgsql stable security definer set search_path = public as $f$
declare
  v_out    jsonb := '[]'::jsonb;
  r        record;
  v_aberto boolean;
  v_local  timestamp;
  v_ja     integer;
begin
  for r in
    select q.id, q.conversa_id, q.advogado_id, q.cliente_ate_id, um.criado_em as cliente_ate,
           c.esperando_desde, c.contato_id, q.nome_para_saudar, d.nome as departamento,
           f.semana, coalesce(nullif(btrim(f.fuso), ''), 'America/Sao_Paulo') as fuso
      from public.zorvin_quazar_faxina q
      join public.conversas c on c.id = q.conversa_id
      join public.advogados a on a.id = c.advogado_id
      join public.departamentos d on d.id = a.departamento_id
      join public.contatos ct on ct.id = c.contato_id
      -- SÓ ONDE O QUAZAR RESPONDE (sem linha, não responde).
      join public.zorvin_quazar_responde rs on rs.departamento_id = a.departamento_id and rs.ligado
      left join public.zorvin_fora_do_horario f on f.departamento_id = a.departamento_id
      join public.mensagens um on um.id = q.cliente_ate_id
     where q.status in ('pendente', 'retomar')
       and q.resposta is null
       and c.situacao is distinct from 'finalizado'
       and coalesce((to_jsonb(c) ->> 'arquivada')::boolean, false) = false
       -- O CLIENTE AINDA ESPERA: a equipe que respondeu tirou a conversa da espera.
       and c.esperando_desde is not null
       and ct.numero not like 'grupo:%'
       and a.ativo is not false
       -- A ÚLTIMA MENSAGEM DO CLIENTE é a que o Quazar leu: a nova, a faxina lê primeiro.
       and not exists (select 1 from public.mensagens m
                        where m.conversa_id = q.conversa_id and m.origem = 'contato'
                          and (m.criado_em, m.id) > (um.criado_em, um.id))
       -- O QUAZAR JÁ FALOU depois da última mensagem do cliente (à noite, 059): não fala de novo.
       and not exists (select 1 from public.mensagens mq
                        where mq.conversa_id = q.conversa_id and mq.origem = 'advogado'
                          and coalesce((to_jsonb(mq) ->> 'pelo_quazar')::boolean, false)
                          and (mq.criado_em, mq.id) > (um.criado_em, um.id))
       and not exists (select 1 from public.fila_envio fe
                        where fe.conversa_id = q.conversa_id and fe.status in ('pendente', 'enviando'))
       -- UMA RESPOSTA POR ESPERA.
       and not exists (select 1 from public.zorvin_quazar_faxina g
                        where g.conversa_id = q.conversa_id
                          and (g.resposta = 'pensando'
                               or (g.respondida_em is not null and g.respondida_em >= c.esperando_desde)))
     order by c.esperando_desde, q.id
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
     where x.advogado_id = r.advogado_id
       and (x.resposta = 'pensando' or x.respondida_em > now() - interval '1 hour');
    v_ja := v_ja + (select count(*) from jsonb_array_elements(v_out) e
                     where e ->> 'advogado_id' = r.advogado_id::text);
    continue when v_ja >= greatest(p_por_hora, 0);
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id', r.id, 'conversa_id', r.conversa_id, 'advogado_id', r.advogado_id,
      'cliente_ate_id', r.cliente_ate_id, 'cliente_ate', r.cliente_ate,
      'esperando_desde', r.esperando_desde,
      'dias', floor(extract(epoch from now() - r.esperando_desde) / 86400)::int,
      'nome', coalesce(r.nome_para_saudar, ''), 'departamento', r.departamento,
      'pede_atencao', public.zorvin_pede_atencao(r.contato_id)));
  end loop;
  return v_out;
end
$f$$x$;

  -- ------------------------------------------------------------
  -- 5. A RESPOSTA QUE SAIU. Resolvida, e de quem não pede atenção, finaliza
  --    em DÚVIDAS TRATADAS (o `zorvin_faxina_finalizar` confere de novo que
  --    o cliente não escreveu depois e que nada está saindo). Sem a lista de
  --    quem pede atenção fresca, espera: não saber é o caso em que finalizar
  --    é mais perigoso.
  -- ------------------------------------------------------------
  execute $x$
create or replace function public.zorvin_quazar_responde_confirmar(p_limite integer default 50)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare
  r      record;
  v_fez  boolean;
  v_fin  integer := 0;
  v_abr  integer := 0;
  v_nao  integer := 0;
begin
  for r in
    select q.id, q.conversa_id, q.cliente_ate_id, q.resposta_resolveu, q.resposta_resumo,
           fe.status as fila_status, c.contato_id
      from public.zorvin_quazar_faxina q
      join public.fila_envio fe on fe.id = q.resposta_fila_id
      join public.conversas c on c.id = q.conversa_id
     where q.resposta = 'na_fila'
       and fe.status in ('enviada', 'erro', 'descartada', 'cancelada')
     order by q.respondida_em
     limit greatest(least(p_limite, 500), 0)
  loop
    if r.fila_status <> 'enviada' then
      update public.zorvin_quazar_faxina set resposta = 'nao_saiu', resposta_em = now()
       where id = r.id and resposta = 'na_fila';
      v_nao := v_nao + 1;
      continue;
    end if;
    v_fez := false;
    if coalesce(r.resposta_resolveu, false) then
      continue when not public.zorvin_atencao_fresca();
      if not public.zorvin_pede_atencao(r.contato_id) then
        v_fez := public.zorvin_faxina_finalizar(r.conversa_id, 'tratada',
                   left('Respondida e finalizada pelo Quazar: '
                        || coalesce(nullif(btrim(r.resposta_resumo), ''), 'a dúvida do cliente foi respondida.'), 500),
                   r.cliente_ate_id);
      end if;
    end if;
    if v_fez then
      update public.zorvin_quazar_faxina
         set resposta = 'finalizou', resposta_em = now(), status = 'finalizada', finalizada_em = now()
       where id = r.id and resposta = 'na_fila';
      v_fin := v_fin + 1;
    else
      update public.zorvin_quazar_faxina set resposta = 'saiu', resposta_em = now()
       where id = r.id and resposta = 'na_fila';
      v_abr := v_abr + 1;
    end if;
  end loop;
  return jsonb_build_object('finalizadas', v_fin, 'abertas', v_abr, 'nao_saiu', v_nao);
end
$f$$x$;

  -- ------------------------------------------------------------
  -- 6. A RETOMADA (066) FICA DE FORA ONDE O QUAZAR RESPONDE. Igual à do
  --    066, mais a última condição.
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
  if not public.zorvin_atencao_fresca() then return v_out; end if;
  for r in
    select q.id, q.conversa_id, q.advogado_id, q.esperando_desde, q.nome_para_saudar,
           f.semana, coalesce(nullif(btrim(f.fuso), ''), 'America/Sao_Paulo') as fuso
      from public.zorvin_quazar_faxina q
      join public.conversas c on c.id = q.conversa_id
      join public.advogados a on a.id = c.advogado_id
      join public.zorvin_faxina_retomada rt on rt.departamento_id = a.departamento_id and rt.ligada
      left join public.zorvin_fora_do_horario f on f.departamento_id = a.departamento_id
      join public.mensagens um on um.id = q.cliente_ate_id
     where (q.status = 'retomar'
            or (q.status = 'pendente' and q.esperando_desde < now() - make_interval(days => greatest(p_dias, 1))))
       and c.situacao is distinct from 'finalizado'
       and coalesce((to_jsonb(c) ->> 'arquivada')::boolean, false) = false
       and c.esperando_desde is not null
       and a.ativo is not false
       and not exists (select 1 from public.mensagens m
                        where m.conversa_id = q.conversa_id and m.origem = 'contato'
                          and (m.criado_em, m.id) > (um.criado_em, um.id))
       and not exists (select 1 from public.fila_envio fe
                        where fe.conversa_id = q.conversa_id and fe.status in ('pendente', 'enviando'))
       and not public.zorvin_pede_atencao(c.contato_id)
       -- ONDE O QUAZAR RESPONDE (069), a resposta de verdade toma o lugar da retomada.
       and not exists (select 1 from public.zorvin_quazar_responde rs
                        where rs.departamento_id = a.departamento_id and rs.ligado)
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
  -- 7. SÓ A PONTE CHAMA (create or replace guarda as permissões; ditas de
  --    novo pela armadilha nº 5).
  -- ------------------------------------------------------------
  foreach f in array array[
    'public.zorvin_quazar_responde_pendentes(integer, integer)',
    'public.zorvin_quazar_responde_confirmar(integer)',
    'public.zorvin_faxina_retomadas_da_vez(integer, integer, integer)'] loop
    execute format('revoke all on function %s from public', f);
    if v_anon then execute format('revoke all on function %s from anon', f); end if;
    if v_auth then execute format('revoke all on function %s from authenticated', f); end if;
    if v_srv then execute format('grant execute on function %s to service_role', f); end if;
  end loop;

  -- ------------------------------------------------------------
  -- A CONFERÊNCIA
  -- ------------------------------------------------------------
  insert into zorvin_conferencia_069
  select 'departamentos em que o Quazar responde quem espera',
         coalesce((select string_agg(d.nome, ', ' order by d.nome) from public.zorvin_quazar_responde r
                     join public.departamentos d on d.id = r.departamento_id where r.ligado), 'nenhum');
  insert into zorvin_conferencia_069
  select 'conversas que ele pode responder agora (no expediente, sem o teto por hora)',
         jsonb_array_length(public.zorvin_quazar_responde_pendentes(100000, 100000))::text;
  insert into zorvin_conferencia_069
  select 'a retomada fica de fora onde o Quazar responde',
         (pg_get_functiondef('public.zorvin_faxina_retomadas_da_vez(integer, integer, integer)'::regprocedure)
            ~ 'zorvin_quazar_responde')::text;
  if v_auth then
    insert into zorvin_conferencia_069 values
      ('quem entrou não alcança onde o Quazar responde nem as funções',
       (not has_table_privilege('authenticated', 'public.zorvin_quazar_responde', 'select')
        and not has_function_privilege('authenticated', 'public.zorvin_quazar_responde_pendentes(integer, integer)', 'execute')
        and not has_function_privilege('authenticated', 'public.zorvin_quazar_responde_confirmar(integer)', 'execute'))::text);
  end if;
  if v_anon then
    insert into zorvin_conferencia_069 values
      ('quem não entrou não alcança',
       (not has_table_privilege('anon', 'public.zorvin_quazar_responde', 'select')
        and not has_function_privilege('anon', 'public.zorvin_quazar_responde_confirmar(integer)', 'execute'))::text);
  end if;
end
$resp$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_069;
