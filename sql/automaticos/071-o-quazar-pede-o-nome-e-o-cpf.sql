-- ============================================================
--  071. O QUAZAR PEDE O NOME E O CPF DE QUEM NÃO TEM FICHA (25/11)
--
--  >>> A PONTE APLICA SOZINHA (sql/automaticos). <<<
--  Pode rodar de novo sem medo — a pasta inteira, na ordem (regra 5).
--
--  ------------------------------------------------------------
--  O PEDIDO
--
--  "Quando o contato não tiver ficha no Vantoro, precisa sempre pedir o nome
--  completo e o CPF, fazer a consulta e ao buscar e verificar que tem a
--  ficha, fazer as consultas necessárias e responder o contato." (Rodrigo)
--
--  A ponte faz a conversa com o Vantoro (`identificarPeloCpf`, no index.js):
--  o CPF nas mensagens do cliente, o nome que confere com o cadastro, o
--  número acrescentado à ficha, o vínculo e a nota. O que mora no banco é a
--  regra do 069 que diz "uma resposta por espera": com ela, o Quazar que
--  pediu o nome e o CPF não responderia o cliente que mandou os dados.
--
--  ------------------------------------------------------------
--  O QUE ESTE SCRIPT FAZ
--
--    zorvin_quazar_faxina.pediu_identificacao   a resposta pediu o nome
--                                                completo e o CPF (ou a
--                                                correção de um deles). Quem
--                                                grava é a ponte.
--    zorvin_quazar_responde_pendentes            a do 070, com a régua nova:
--                                                o Quazar fala de novo na
--                                                mesma espera quando TODAS as
--                                                respostas dela pediram os
--                                                dados e o cliente mandou um
--                                                CPF (onze dígitos) depois da
--                                                última. No máximo três
--                                                respostas por espera.
--
--  O que NÃO muda: a linha caída (070), o teto por telefone por hora, o
--  expediente, quem o Quazar responde. Ele nunca escreve duas vezes para a
--  mesma mensagem do cliente.
--
--  A VERSÃO DE REFERÊNCIA (regra 5) de zorvin_quazar_responde_pendentes passa
--  a ser a deste script: o 069 e o 070 rodados de novo depois dele a devolvem
--  sem a régua nova, e este, na ordem da pasta, a põe de volta.
--
--  DEPENDE DE JÁ TER RODADO: 069 e 070.
-- ============================================================

do $cpf$
declare
  v_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_anon boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_srv  boolean := exists (select 1 from pg_roles where rolname = 'service_role');
  f      text;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_071;
  create temp table zorvin_conferencia_071 (item text, resposta text);

  if to_regclass('public.conversas') is null or to_regclass('public.mensagens') is null then
    insert into zorvin_conferencia_071 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 071 não fez nada.';
    return;
  end if;
  if to_regprocedure('public.zorvin_linha_caida_desde(uuid)') is null
     or to_regprocedure('public.zorvin_quazar_responde_pendentes(integer, integer)') is null
     or not exists (select 1 from information_schema.columns where table_schema = 'public'
                     and table_name = 'zorvin_quazar_faxina' and column_name = 'resposta') then
    insert into zorvin_conferencia_071 values ('NÃO — falta o 069 ou o 070', 'rode-os antes');
    raise notice 'Zorvin: script 071 precisa do 069 e do 070.';
    return;
  end if;

  -- ------------------------------------------------------------
  -- 1. A MARCA: a resposta pediu o nome e o CPF.
  -- ------------------------------------------------------------
  alter table public.zorvin_quazar_faxina add column if not exists pediu_identificacao boolean not null default false;

  -- ------------------------------------------------------------
  -- 2. QUEM ELE PODE RESPONDER AGORA: a do 070, com a régua nova.
  -- ------------------------------------------------------------
  execute $x$
create or replace function public.zorvin_quazar_responde_pendentes(
  p_limite integer default 10, p_por_hora integer default 10)
returns jsonb language plpgsql stable security definer set search_path = public as $f$
declare
  v_out    jsonb := '[]'::jsonb;
  v_linhas jsonb := '{}'::jsonb;
  r        record;
  v_aberto boolean;
  v_local  timestamp;
  v_ja     integer;
  v_caida  timestamptz;
  v_estado text;
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
       -- UMA RESPOSTA POR ESPERA — menos quando ela pediu o nome completo e o
       -- CPF (071) e o cliente mandou um CPF depois: aí o Quazar fala de novo,
       -- até três vezes na mesma espera.
       and not exists (select 1 from public.zorvin_quazar_faxina g
                        where g.conversa_id = q.conversa_id and g.resposta = 'pensando')
       and (select count(*) from public.zorvin_quazar_faxina g
             where g.conversa_id = q.conversa_id
               and g.respondida_em is not null and g.respondida_em >= c.esperando_desde) < 3
       and not exists (select 1 from public.zorvin_quazar_faxina g
                        where g.conversa_id = q.conversa_id
                          and g.respondida_em is not null and g.respondida_em >= c.esperando_desde
                          and not (g.pediu_identificacao
                                   and exists (select 1 from public.mensagens mc
                                                where mc.conversa_id = q.conversa_id and mc.origem = 'contato'
                                                  and mc.criado_em > g.respondida_em
                                                  and (coalesce(mc.texto, '') || ' ' || coalesce(to_jsonb(mc) ->> 'transcricao', ''))
                                                      ~ '[0-9]{3}[.[:space:]-]?[0-9]{3}[.[:space:]-]?[0-9]{3}[.[:space:]-]?[0-9]{2}')))
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
    -- A LINHA CAÍDA (070): uma pergunta por telefone, guardada nesta chamada.
    v_estado := v_linhas ->> r.advogado_id::text;
    if v_estado is null then
      v_caida := public.zorvin_linha_caida_desde(r.advogado_id);
      v_estado := case when v_caida is null then 'viva'
                       when v_caida > now() - interval '1 hour' then 'caida'
                       else 'sondar' end;
      v_linhas := v_linhas || jsonb_build_object(r.advogado_id::text, v_estado);
    end if;
    continue when v_estado = 'caida';
    -- A SONDA: uma conversa só, e nenhuma enquanto outra da linha está a caminho.
    continue when v_estado = 'sondar'
                  and (exists (select 1 from public.zorvin_quazar_faxina x
                                where x.advogado_id = r.advogado_id and x.resposta in ('pensando', 'na_fila'))
                       or exists (select 1 from jsonb_array_elements(v_out) e
                                   where e ->> 'advogado_id' = r.advogado_id::text));
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
  -- 3. SÓ A PONTE CHAMA (create or replace guarda as permissões; ditas de
  --    novo pela armadilha nº 5).
  -- ------------------------------------------------------------
  f := 'public.zorvin_quazar_responde_pendentes(integer, integer)';
  execute format('revoke all on function %s from public', f);
  if v_anon then execute format('revoke all on function %s from anon', f); end if;
  if v_auth then execute format('revoke all on function %s from authenticated', f); end if;
  if v_srv then execute format('grant execute on function %s to service_role', f); end if;

  -- ------------------------------------------------------------
  -- A CONFERÊNCIA
  -- ------------------------------------------------------------
  insert into zorvin_conferencia_071
  select 'a marca de quem pediu o nome e o CPF existe',
         exists (select 1 from information_schema.columns where table_schema = 'public'
                  and table_name = 'zorvin_quazar_faxina' and column_name = 'pediu_identificacao')::text;
  insert into zorvin_conferencia_071
  select 'o Quazar responde de novo quem mandou o CPF',
         (pg_get_functiondef('public.zorvin_quazar_responde_pendentes(integer, integer)'::regprocedure) ~ 'pediu_identificacao')::text;
  insert into zorvin_conferencia_071
  select 'e continua pulando a linha caída (070)',
         (pg_get_functiondef('public.zorvin_quazar_responde_pendentes(integer, integer)'::regprocedure) ~ 'zorvin_linha_caida_desde')::text;
  insert into zorvin_conferencia_071
  select 'respostas que já pediram o nome e o CPF', count(*)::text
    from public.zorvin_quazar_faxina where pediu_identificacao;
  if v_auth then
    insert into zorvin_conferencia_071 values
      ('quem entrou não alcança a função',
       (not has_function_privilege('authenticated', 'public.zorvin_quazar_responde_pendentes(integer, integer)', 'execute'))::text);
  end if;
  if v_anon then
    insert into zorvin_conferencia_071 values
      ('quem não entrou não alcança',
       (not has_function_privilege('anon', 'public.zorvin_quazar_responde_pendentes(integer, integer)', 'execute'))::text);
  end if;
end
$cpf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_071;
