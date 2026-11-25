-- ============================================================
--  070. O QUAZAR NÃO ESCREVE PARA TELEFONE DESCONECTADO (25/11)
--
--  >>> A PONTE APLICA SOZINHA (sql/automaticos). <<<
--  Pode rodar de novo sem medo — a pasta inteira, na ordem (regra 5).
--
--  ------------------------------------------------------------
--  O QUE ACONTECEU
--
--  Na primeira hora do 069 (25/11, das 09h02 às 09h09 de Brasília), o
--  Quazar escreveu para 43 clientes, e 20 respostas não saíram: os
--  telefones Comercial e Subsídio Emenda estão desconectados do WhatsApp
--  ("WhatsApp disconnected: session is not reconnectable"). Cada uma gastou
--  uma ida à IA, e a conversa ficou como 'nao_saiu' — para sempre, porque
--  "uma resposta por espera" a tirou da lista. Quando a linha voltar, o
--  cliente que esperava não recebe nada.
--
--  ------------------------------------------------------------
--  O QUE ESTE SCRIPT FAZ
--
--    zorvin_linha_caida_desde(telefone)   quando a linha caiu, ou nulo se
--                                         ela está de pé. "Caiu" é a régua
--                                         do 007: um erro de desconexão na
--                                         fila (nos últimos 30 dias) sem
--                                         SINAL DE VIDA depois dele — nada
--                                         saiu por ela, nada chegou por ela.
--                                         Sem a janela de 30 minutos do 007:
--                                         a linha fica caída até dar sinal de
--                                         vida (o 007 é um aviso na tela; aqui
--                                         é a decisão de gastar ou não a IA).
--    zorvin_quazar_responde_pendentes     a do 069, sem a linha caída. Uma
--                                         hora depois do último erro, UMA
--                                         conversa dela volta à lista, como
--                                         sonda: se a linha voltou sem que
--                                         nada tenha entrado ou saído (um
--                                         telefone sem movimento), é assim
--                                         que o Quazar descobre. Se não
--                                         voltou, a sonda falha, e o relógio
--                                         recomeça. No máximo uma ida à IA
--                                         por hora, por linha caída.
--    zorvin_quazar_responde_confirmar     a do 069, e:
--                                         - a resposta que falhou porque a
--                                           linha caiu DEVOLVE A VEZ (as
--                                           colunas `resposta*` voltam a nulo):
--                                           ela é tentada de novo quando a
--                                           linha voltar. A que falhou por
--                                           outro motivo continua 'nao_saiu';
--                                         - a resposta que SAIU tira da tela
--                                           as bolhas vermelhas antigas do
--                                           próprio Quazar naquela conversa
--                                           (vira 'descartada', como o
--                                           "Dispensar" do painel): sem isso,
--                                           alguém poderia reenviar a mensagem
--                                           velha, e o cliente receberia duas.
--                                           Só as do Quazar (`pelo_quazar`);
--                                           as da equipe ficam.
--    as 20 de hoje                        a instalação devolve a vez das que
--                                         ficaram 'nao_saiu' por linha caída.
--
--  O que NÃO muda: a faixa vermelha do painel continua dizendo que a linha
--  caiu (007), e a sonda de hora em hora a acende de novo enquanto ela não
--  voltar. Reconectar o aparelho continua sendo trabalho de uma pessoa.
--
--  A VERSÃO DE REFERÊNCIA (regra 5) de zorvin_quazar_responde_pendentes e de
--  zorvin_quazar_responde_confirmar passa a ser a deste script: o 069
--  rodado de novo depois dele as devolve sem a linha caída, e este, na
--  ordem da pasta, a põe de volta.
--
--  DEPENDE DE JÁ TER RODADO: 069 (e o que ele pede).
-- ============================================================

do $linha$
declare
  v_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_anon boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_srv  boolean := exists (select 1 from pg_roles where rolname = 'service_role');
  v_devolvidas integer := 0;
  f      text;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_070;
  create temp table zorvin_conferencia_070 (item text, resposta text);

  if to_regclass('public.conversas') is null or to_regclass('public.fila_envio') is null
     or to_regclass('public.mensagens') is null then
    insert into zorvin_conferencia_070 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 070 não fez nada.';
    return;
  end if;
  if to_regprocedure('public.zorvin_quazar_responde_pendentes(integer, integer)') is null
     or to_regprocedure('public.zorvin_quazar_responde_confirmar(integer)') is null
     or not exists (select 1 from information_schema.columns where table_schema = 'public'
                     and table_name = 'zorvin_quazar_faxina' and column_name = 'resposta') then
    insert into zorvin_conferencia_070 values ('NÃO — falta o 069', 'rode-o antes');
    raise notice 'Zorvin: script 070 precisa do 069.';
    return;
  end if;

  -- ------------------------------------------------------------
  -- 1. QUANDO A LINHA CAIU (ou nulo, se está de pé).
  --    `erro_motivo`, `erro_detalhe` e `enviado_em` vêm por `to_jsonb`: as
  --    três colunas nasceram em scripts colados à mão, e um banco sem elas
  --    não pode derrubar a lista de quem espera.
  -- ------------------------------------------------------------
  execute $x$
create or replace function public.zorvin_linha_caida_desde(p_advogado uuid)
returns timestamptz language plpgsql stable security definer set search_path = public as $f$
declare
  v_erro timestamptz;
begin
  select max(fe.criado_em) into v_erro
    from public.fila_envio fe
    join public.conversas c on c.id = fe.conversa_id
   where c.advogado_id = p_advogado
     and fe.status = 'erro'
     and fe.criado_em > now() - interval '30 days'
     and (coalesce(to_jsonb(fe) ->> 'erro_motivo', '') || ' ' || coalesce(to_jsonb(fe) ->> 'erro_detalhe', ''))
         ~* '(desconect|disconnected|not connected|reconectar)';
  if v_erro is null then return null; end if;
  -- SINAL DE VIDA 1: saiu alguma coisa por ela depois do erro.
  if exists (select 1 from public.fila_envio f2
               join public.conversas c2 on c2.id = f2.conversa_id
              where c2.advogado_id = p_advogado and f2.status = 'enviada'
                and coalesce((to_jsonb(f2) ->> 'enviado_em')::timestamptz, f2.criado_em) > v_erro) then
    return null;
  end if;
  -- SINAL DE VIDA 2: chegou alguma coisa por ela depois do erro.
  if exists (select 1 from public.mensagens m
               join public.conversas c3 on c3.id = m.conversa_id
              where c3.advogado_id = p_advogado and m.criado_em > v_erro) then
    return null;
  end if;
  return v_erro;
end
$f$$x$;

  -- ------------------------------------------------------------
  -- 2. QUEM ELE PODE RESPONDER AGORA: a do 069, sem a linha caída.
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
  -- 3. A RESPOSTA QUE SAIU (ou não): a do 069, com a linha caída devolvendo
  --    a vez, e a que saiu tirando da tela as bolhas vermelhas antigas do
  --    Quazar na mesma conversa.
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
  v_cai  integer := 0;
begin
  for r in
    select q.id, q.conversa_id, q.cliente_ate_id, q.resposta_resolveu, q.resposta_resumo,
           q.resposta_fila_id, fe.status as fila_status, c.contato_id,
           (coalesce(to_jsonb(fe) ->> 'erro_motivo', '') || ' ' || coalesce(to_jsonb(fe) ->> 'erro_detalhe', ''))
             ~* '(desconect|disconnected|not connected|reconectar)' as linha_caiu
      from public.zorvin_quazar_faxina q
      join public.fila_envio fe on fe.id = q.resposta_fila_id
      join public.conversas c on c.id = q.conversa_id
     where q.resposta = 'na_fila'
       and fe.status in ('enviada', 'erro', 'descartada', 'cancelada')
     order by q.respondida_em
     limit greatest(least(p_limite, 500), 0)
  loop
    if r.fila_status <> 'enviada' then
      if r.fila_status = 'erro' and r.linha_caiu then
        -- A LINHA CAIU: a resposta não foi ao cliente por causa do telefone, e não
        -- dele. Devolve a vez, e ela é tentada de novo quando a linha voltar.
        update public.zorvin_quazar_faxina
           set resposta = null, resposta_em = null, respondida_em = null, resposta_fila_id = null,
               resposta_resolveu = null, resposta_resumo = null
         where id = r.id and resposta = 'na_fila';
        v_cai := v_cai + 1;
      else
        update public.zorvin_quazar_faxina set resposta = 'nao_saiu', resposta_em = now()
         where id = r.id and resposta = 'na_fila';
        v_nao := v_nao + 1;
      end if;
      continue;
    end if;
    -- SAIU: as bolhas vermelhas antigas do Quazar nesta conversa saem da tela.
    update public.fila_envio fe set status = 'descartada'
     where fe.conversa_id = r.conversa_id and fe.status = 'erro' and fe.id <> r.resposta_fila_id
       and coalesce((to_jsonb(fe) ->> 'pelo_quazar')::boolean, false);
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
  return jsonb_build_object('finalizadas', v_fin, 'abertas', v_abr, 'nao_saiu', v_nao, 'linha_caida', v_cai);
end
$f$$x$;

  -- ------------------------------------------------------------
  -- 4. AS DE HOJE: as respostas que ficaram 'nao_saiu' porque a linha caiu
  --    voltam para a fila de tentativas. Rodar de novo não acha nenhuma: com
  --    a confirmação acima, a linha caída não deixa mais 'nao_saiu'.
  -- ------------------------------------------------------------
  update public.zorvin_quazar_faxina q
     set resposta = null, resposta_em = null, respondida_em = null, resposta_fila_id = null,
         resposta_resolveu = null, resposta_resumo = null
    from public.fila_envio fe
   where fe.id = q.resposta_fila_id
     and q.resposta = 'nao_saiu'
     and fe.status = 'erro'
     and (coalesce(to_jsonb(fe) ->> 'erro_motivo', '') || ' ' || coalesce(to_jsonb(fe) ->> 'erro_detalhe', ''))
         ~* '(desconect|disconnected|not connected|reconectar)';
  get diagnostics v_devolvidas = row_count;

  -- ------------------------------------------------------------
  -- 5. SÓ A PONTE CHAMA (create or replace guarda as permissões; ditas de
  --    novo pela armadilha nº 5).
  -- ------------------------------------------------------------
  foreach f in array array[
    'public.zorvin_linha_caida_desde(uuid)',
    'public.zorvin_quazar_responde_pendentes(integer, integer)',
    'public.zorvin_quazar_responde_confirmar(integer)'] loop
    execute format('revoke all on function %s from public', f);
    if v_anon then execute format('revoke all on function %s from anon', f); end if;
    if v_auth then execute format('revoke all on function %s from authenticated', f); end if;
    if v_srv then execute format('grant execute on function %s to service_role', f); end if;
  end loop;

  -- ------------------------------------------------------------
  -- A CONFERÊNCIA
  -- ------------------------------------------------------------
  insert into zorvin_conferencia_070
  select 'telefones desconectados agora (o Quazar não escreve por eles)',
         coalesce((select string_agg(coalesce(a.nome, a.numero), ', ' order by a.nome) from public.advogados a
                    where a.ativo is not false and public.zorvin_linha_caida_desde(a.id) is not null), 'nenhum');
  insert into zorvin_conferencia_070 values
    ('respostas que não saíram por linha caída, devolvidas para tentar de novo', v_devolvidas::text);
  insert into zorvin_conferencia_070
  select 'a lista de quem espera pula a linha caída',
         (pg_get_functiondef('public.zorvin_quazar_responde_pendentes(integer, integer)'::regprocedure)
            ~ 'zorvin_linha_caida_desde')::text;
  insert into zorvin_conferencia_070
  select 'a resposta que falhou por linha caída devolve a vez',
         (pg_get_functiondef('public.zorvin_quazar_responde_confirmar(integer)'::regprocedure) ~ 'linha_caida')::text;
  if v_auth then
    insert into zorvin_conferencia_070 values
      ('quem entrou não alcança as funções',
       (not has_function_privilege('authenticated', 'public.zorvin_linha_caida_desde(uuid)', 'execute')
        and not has_function_privilege('authenticated', 'public.zorvin_quazar_responde_pendentes(integer, integer)', 'execute')
        and not has_function_privilege('authenticated', 'public.zorvin_quazar_responde_confirmar(integer)', 'execute'))::text);
  end if;
  if v_anon then
    insert into zorvin_conferencia_070 values
      ('quem não entrou não alcança',
       (not has_function_privilege('anon', 'public.zorvin_linha_caida_desde(uuid)', 'execute'))::text);
  end if;
end
$linha$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_070;
