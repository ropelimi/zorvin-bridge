-- ============================================================
--  064. A FAXINA DO QUAZAR (25/11)
--
--  >>> A PONTE APLICA SOZINHA (sql/automaticos). <<<
--  Pode rodar de novo sem medo — a pasta inteira, na ordem (regra 5).
--
--  ------------------------------------------------------------
--  O PEDIDO
--
--  Rodrigo, em 25/11: "Temos muitas conversas sem resposta, muitas conversas
--  sem responsáveis, muitas conversas com o contato esperando há mais de 2
--  dias. Preciso zerar isso, ficar em dia para poder 'começar do zero'."
--  Decidido com ele, em quatro respostas:
--
--    1. vale para o ESCRITÓRIO TODO (todos os telefones);
--    2. a conversa em que A EQUIPE FALOU POR ÚLTIMO e o cliente não
--       respondeu mais é finalizada sozinha depois de 7 DIAS de silêncio;
--    3. o cliente que espera resposta HÁ MAIS DE 30 DIAS: o Quazar lê antes.
--       Se era só um "ok"/"obrigado", finaliza. Se há pergunta sem resposta,
--       ele manda uma mensagem pedindo desculpas pela demora e perguntando se
--       o cliente ainda precisa de ajuda, e finaliza;
--    4. nas conversas esperando entre 2 e 30 dias, o Quazar separa as que
--       "já encerraram" (ok, obrigado, 👍) e as FINALIZA SOZINHO, com o
--       registro no "Já tratei" dizendo que foi ele.
--
--  Medido em 25/11, só contando: 1.259 conversas abertas no escritório; 585
--  em que a equipe falou por último há mais de 7 dias (sem mensagem agendada
--  nem tarefa aberta); 296 com o cliente esperando há mais de 30 dias; 212
--  esperando entre 2 e 30.
--
--  ------------------------------------------------------------
--  O QUE ESTE SCRIPT ACRESCENTA
--
--    zorvin_quazar_faxina             o que o Quazar leu e decidiu, uma linha
--                                     por (conversa, última mensagem do
--                                     cliente): ler de novo só quando o
--                                     cliente escrever de novo
--    zorvin_faxina_quietas()          as conversas da regra dos 7 dias
--    zorvin_faxina_para_ler()         as que esperam há 2 dias ou mais e o
--                                     Quazar ainda não leu
--    zorvin_faxina_finalizar()        finaliza UMA conversa, conferindo antes
--                                     que ela continua como foi lida
--    zorvin_faxina_retomadas_da_vez() as de 30 dias ou mais que recebem a
--                                     mensagem de retomada agora: no
--                                     expediente, e no máximo N por telefone
--                                     por hora
--    zorvin_faxina_confirmar()        finaliza as que já receberam a retomada
--
--  TODAS SÃO SÓ DA PONTE (`service_role`). Quem decide quando chamar é a
--  rodada `faxinaDoQuazar`, no index.js.
--
--  ------------------------------------------------------------
--  FINALIZAR É O "JÁ TRATEI" DE SEMPRE, SEM PESSOA
--
--  A finalização é um clique de "Já tratei" gravado pela ponte, com `quem`
--  NULO e o porquê em `observacao`: o gatilho do 028 fecha o atendimento e
--  tira a conversa da fila, como faz com o clique de qualquer pessoa. O
--  painel diz "Quazar" onde a pessoa vem nula. Os assuntos:
--
--    o silêncio de 7 dias, e a retomada  →  SEM RETORNO DO CLIENTE
--    o cliente que encerrou ("obrigado") →  DÚVIDAS TRATADAS
--    propaganda, robô, golpe              →  PROPAGANDA
--
--  (sem o DÚVIDAS TRATADAS ou o PROPAGANDA, vale o SEM RETORNO DO CLIENTE; sem nenhum dos
--  dois, este script cria o SEM RETORNO DO CLIENTE, uma vez só — a semente
--  `assunto:sem-retorno-do-cliente-064`.)
--
--  NADA SE PERDE: o cliente que escrever de novo reabre a conversa, com
--  protocolo novo (028). E o "Já tratei" do Quazar se desfaz como o de
--  qualquer pessoa (o Reabrir).
--
--  ------------------------------------------------------------
--  O QUE NÃO ENTRA NA FAXINA
--
--    - a conversa arquivada, o grupo e a linha desativada;
--    - a conversa com mensagem saindo ou agendada (`fila_envio` pendente);
--    - na regra dos 7 dias, a conversa com TAREFA ABERTA: alguém planejou
--      voltar a ela;
--    - na regra dos 7 dias, a conversa em que o cliente ainda espera
--      (`esperando_desde`): a resposta do Quazar à noite e o aviso de
--      audiência são automáticos, e não tiram o cliente da espera. Essas vão
--      para a leitura do Quazar, e não para o silêncio.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    005 (Já tratei), 009 (o texto do "Já tratei"), 018 (tarefas), 021 (horário), 025 (a chave do
--    assunto), 028 (as abas) e 059 (`pelo_quazar`). Sem eles, não faz nada, e
--    diz por quê.
-- ============================================================

do $fax$
declare
  v_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_anon boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_srv  boolean := exists (select 1 from pg_roles where rolname = 'service_role');
  f      text;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_064;
  create temp table zorvin_conferencia_064 (item text, resposta text);

  if to_regclass('public.conversas') is null or to_regclass('public.mensagens') is null
     or to_regclass('public.fila_envio') is null or to_regclass('public.advogados') is null
     or to_regclass('public.contatos') is null then
    insert into zorvin_conferencia_064 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 064 não fez nada.';
    return;
  end if;
  if to_regclass('public.zorvin_tratamentos') is null or to_regclass('public.zorvin_assuntos') is null
     or to_regclass('public.zorvin_atendimentos') is null or to_regclass('public.zorvin_tarefas') is null
     or to_regclass('public.zorvin_fora_do_horario') is null or to_regclass('public.zorvin_feriados') is null
     or to_regprocedure('public.zorvin_horario_de(jsonb, text, timestamptz)') is null
     or to_regprocedure('public.zorvin_chave_do_assunto(text)') is null
     or not exists (select 1 from information_schema.columns where table_schema = 'public'
                     and table_name = 'conversas' and column_name = 'situacao')
     or not exists (select 1 from information_schema.columns where table_schema = 'public'
                     and table_name = 'fila_envio' and column_name = 'pelo_quazar')
     or not exists (select 1 from information_schema.columns where table_schema = 'public'
                     and table_name = 'zorvin_tratamentos' and column_name = 'observacao') then
    insert into zorvin_conferencia_064 values ('NÃO — falta o 005, o 009, o 018, o 021, o 025, o 028 ou o 059', 'rode-os antes');
    raise notice 'Zorvin: script 064 precisa do 005, do 009, do 018, do 021, do 025, do 028 e do 059.';
    return;
  end if;

  -- ------------------------------------------------------------
  -- 1. O ASSUNTO DO SILÊNCIO, uma vez só (regra 5): tirado de uso depois, ou
  --    renomeado, rodar a pasta de novo não o traz de volta.
  -- ------------------------------------------------------------
  execute 'create table if not exists public.zorvin_sementes (
             chave text primary key, plantada_em timestamptz not null default now())';
  execute 'alter table public.zorvin_sementes enable row level security';
  if v_anon then execute 'revoke all on public.zorvin_sementes from anon'; end if;
  if v_auth then execute 'revoke all on public.zorvin_sementes from authenticated'; end if;
  if not exists (select 1 from public.zorvin_sementes where chave = 'assunto:sem-retorno-do-cliente-064') then
    if not exists (select 1 from public.zorvin_assuntos
                    where public.zorvin_chave_do_assunto(nome) = 'sem retorno do cliente') then
      insert into public.zorvin_assuntos (nome, ordem, ativo)
      select 'SEM RETORNO DO CLIENTE', coalesce(max(ordem), 0) + 1, true from public.zorvin_assuntos;
    end if;
    insert into public.zorvin_sementes (chave) values ('assunto:sem-retorno-do-cliente-064') on conflict do nothing;
  end if;

  -- ------------------------------------------------------------
  -- 2. O QUE O QUAZAR LEU E DECIDIU
  --
  --   pensando    a ponte está lendo (a que cair no meio sai em 10 minutos)
  --   pendente    há pergunta sem resposta; fica para a equipe
  --   retomar     há pergunta sem resposta há 30 dias ou mais: recebe a
  --               mensagem de retomada no próximo expediente
  --   retomada    a retomada entrou na fila (`fila_id`)
  --   finalizada  o Quazar finalizou
  --   superada    o cliente escreveu de novo, ou alguém finalizou antes
  --   erro        a retomada não saiu
  -- ------------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_quazar_faxina (
      id               uuid primary key default gen_random_uuid(),
      conversa_id      uuid not null references public.conversas(id) on delete cascade,
      advogado_id      uuid,
      cliente_ate_id   uuid not null,
      esperando_desde  timestamptz,
      status           text not null default 'pensando'
                       check (status in ('pensando', 'pendente', 'retomar', 'retomada', 'finalizada', 'superada', 'erro')),
      motivo           text check (motivo is null or length(motivo) <= 400),
      nome_para_saudar text check (nome_para_saudar is null or length(nome_para_saudar) <= 40),
      fila_id          uuid,
      criada_em        timestamptz not null default now(),
      decidida_em      timestamptz,
      retomada_em      timestamptz,
      finalizada_em    timestamptz,
      unique (conversa_id, cliente_ate_id)
    )$x$;
  execute 'create index if not exists zorvin_quazar_faxina_status on public.zorvin_quazar_faxina (status)';
  execute 'create index if not exists zorvin_quazar_faxina_retomada on public.zorvin_quazar_faxina (advogado_id, retomada_em)';
  -- SÓ A PONTE: RLS ligada, sem política, e a herança tirada.
  execute 'alter table public.zorvin_quazar_faxina enable row level security';
  if v_anon then execute 'revoke all on public.zorvin_quazar_faxina from anon'; end if;
  if v_auth then execute 'revoke all on public.zorvin_quazar_faxina from authenticated'; end if;
  if v_srv then execute 'grant all on public.zorvin_quazar_faxina to service_role'; end if;

  -- ------------------------------------------------------------
  -- 3. O ASSUNTO DE CADA FINALIZAÇÃO, procurado pela chave do 025 (sem
  --    acento, sem maiúscula): o ativo primeiro.
  -- ------------------------------------------------------------
  execute $x$
create or replace function public.zorvin_faxina_assunto(p_qual text)
returns uuid language sql stable security definer set search_path = public as $f$
  select s.id from public.zorvin_assuntos s
   where public.zorvin_chave_do_assunto(s.nome)
         = case p_qual when 'tratada' then 'duvidas tratadas' when 'propaganda' then 'propaganda'
                       else 'sem retorno do cliente' end
   order by s.ativo desc, s.ordem
   limit 1
$f$$x$;

  -- ------------------------------------------------------------
  -- 4. A REGRA DOS 7 DIAS: a equipe falou por último, ninguém espera, e o
  --    silêncio passou de `p_dias`. A mais antiga primeiro.
  -- ------------------------------------------------------------
  execute $x$
create or replace function public.zorvin_faxina_quietas(p_dias integer default 7, p_limite integer default 50)
returns jsonb language sql stable security definer set search_path = public as $f$
  select coalesce(jsonb_agg(jsonb_build_object('conversa_id', x.id, 'advogado_id', x.advogado_id,
                                               'ultima', x.ultima) order by x.ultima), '[]'::jsonb)
    from (
      select c.id, c.advogado_id, u.criado_em as ultima
        from public.conversas c
        join public.advogados a on a.id = c.advogado_id
        join public.contatos ct on ct.id = c.contato_id
        cross join lateral (select m.origem, m.criado_em from public.mensagens m
                             where m.conversa_id = c.id order by m.criado_em desc, m.id desc limit 1) u
       where c.situacao is distinct from 'finalizado'
         and coalesce((to_jsonb(c) ->> 'arquivada')::boolean, false) = false
         and c.esperando_desde is null
         -- COM PROTOCOLO: finalizar uma conversa sem atendimento abriria um só
         -- para fechá-lo (028), e ele contaria na contabilização (029).
         and c.protocolo is not null
         and ct.numero not like 'grupo:%'
         and a.ativo is not false
         and u.origem = 'advogado'
         and u.criado_em < now() - make_interval(days => greatest(p_dias, 1))
         and not exists (select 1 from public.fila_envio f
                          where f.conversa_id = c.id and f.status in ('pendente', 'enviando'))
         and not exists (select 1 from public.zorvin_tarefas t where t.conversa_id = c.id and t.feita_em is null)
       order by u.criado_em
       limit greatest(least(p_limite, 2000), 0)
    ) x
$f$$x$;

  -- ------------------------------------------------------------
  -- 5. O QUE O QUAZAR LÊ: o cliente espera há `p_dias` ou mais, e ninguém
  --    leu a última mensagem dele ainda. A espera mais antiga primeiro.
  -- ------------------------------------------------------------
  execute $x$
create or replace function public.zorvin_faxina_para_ler(p_limite integer default 10, p_dias integer default 2)
returns jsonb language sql stable security definer set search_path = public as $f$
  select coalesce(jsonb_agg(jsonb_build_object(
           'conversa_id', x.id, 'advogado_id', x.advogado_id, 'cliente_ate_id', x.msg_id,
           'cliente_ate', x.msg_em, 'esperando_desde', x.esperando_desde,
           'dias', floor(extract(epoch from now() - x.esperando_desde) / 86400)::int)
         order by x.esperando_desde), '[]'::jsonb)
    from (
      select c.id, c.advogado_id, c.esperando_desde, uc.id as msg_id, uc.criado_em as msg_em
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
  -- 6. FINALIZAR UMA CONVERSA, conferindo antes que ela continua como foi
  --    lida (a ponte leu há segundos, e o cliente pode ter escrito):
  --      - sem `p_cliente_ate_id` (o silêncio): ninguém espera, e a última
  --        mensagem continua sendo da equipe;
  --      - com ele (o que o Quazar leu): o cliente não escreveu depois.
  --    Nada saindo na fila, nem arquivada, nem já finalizada. Devolve se
  --    finalizou.
  -- ------------------------------------------------------------
  execute $x$
create or replace function public.zorvin_faxina_finalizar(
  p_conversa uuid, p_qual text, p_obs text, p_cliente_ate_id uuid default null)
returns boolean language plpgsql security definer set search_path = public as $f$
declare
  v_situacao text;
  v_espera   timestamptz;
  v_j        jsonb;
  v_ate      timestamptz;
  v_assunto  uuid;
begin
  select c.situacao, c.esperando_desde, to_jsonb(c) into v_situacao, v_espera, v_j
    from public.conversas c where c.id = p_conversa for update;
  if not found or v_situacao = 'finalizado' or coalesce((v_j ->> 'arquivada')::boolean, false) then
    return false;
  end if;
  if p_cliente_ate_id is null then
    if v_espera is not null then return false; end if;
    if exists (select 1 from (select m.origem from public.mensagens m where m.conversa_id = p_conversa
                                order by m.criado_em desc, m.id desc limit 1) u
                where u.origem <> 'advogado') then
      return false;
    end if;
  else
    select m.criado_em into v_ate from public.mensagens m
     where m.id = p_cliente_ate_id and m.conversa_id = p_conversa;
    if v_ate is null then return false; end if;
    if exists (select 1 from public.mensagens m
                where m.conversa_id = p_conversa and m.origem = 'contato'
                  and (m.criado_em, m.id) > (v_ate, p_cliente_ate_id)) then
      return false;
    end if;
  end if;
  if exists (select 1 from public.fila_envio f
              where f.conversa_id = p_conversa and f.status in ('pendente', 'enviando')) then
    return false;
  end if;
  v_assunto := coalesce(public.zorvin_faxina_assunto(p_qual), public.zorvin_faxina_assunto('sem-retorno'));
  if v_assunto is null then
    raise exception 'falta o assunto SEM RETORNO DO CLIENTE' using errcode = '22023';
  end if;
  -- O "JÁ TRATEI" SEM PESSOA: o gatilho do 028 fecha o atendimento e tira a
  -- conversa da fila. `quem` nulo é o Quazar.
  insert into public.zorvin_tratamentos (conversa_id, assunto_id, quem, esperava_desde, observacao)
  values (p_conversa, v_assunto, null, v_espera,
          left(coalesce(nullif(btrim(p_obs), ''), 'Finalizada pelo Quazar.'), 500));
  return exists (select 1 from public.conversas where id = p_conversa and situacao = 'finalizado');
end
$f$$x$;

  -- ------------------------------------------------------------
  -- 7. AS RETOMADAS DA VEZ: a decisão foi "pendente" e o cliente espera há
  --    `p_dias` ou mais. Só no EXPEDIENTE do departamento (a semana da
  --    resposta fora do horário, com os feriados; sem a semana escrita, de
  --    segunda a sexta das 8h às 18h de Brasília, fora dos feriados), e no
  --    máximo `p_por_hora` por telefone por hora: um telefone que manda
  --    dezenas de mensagens seguidas para clientes antigos chama a atenção
  --    do WhatsApp.
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
  -- 8. A RETOMADA QUE SAIU FINALIZA; a que não saiu fica com 'erro', e a
  --    conversa aberta, para a equipe.
  -- ------------------------------------------------------------
  execute $x$
create or replace function public.zorvin_faxina_confirmar(p_limite integer default 50)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare
  r       record;
  v_fin   integer := 0;
  v_sup   integer := 0;
  v_err   integer := 0;
  v_dias  integer;
begin
  for r in
    select q.id, q.conversa_id, q.cliente_ate_id, q.esperando_desde, fe.status as fila_status
      from public.zorvin_quazar_faxina q
      join public.fila_envio fe on fe.id = q.fila_id
     where q.status = 'retomada' and fe.status in ('enviada', 'erro', 'descartada', 'cancelada')
     order by q.retomada_em
     limit greatest(p_limite, 0)
  loop
    if r.fila_status = 'enviada' then
      v_dias := greatest(floor(extract(epoch from now() - r.esperando_desde) / 86400)::int, 0);
      if public.zorvin_faxina_finalizar(r.conversa_id, 'sem-retorno',
           format('Finalizada pelo Quazar: o cliente esperava resposta havia %s dias. Ele pediu desculpas pela demora '
                  'e perguntou se o cliente ainda precisa de ajuda; se o cliente responder, a conversa reabre.', v_dias),
           r.cliente_ate_id) then
        update public.zorvin_quazar_faxina set status = 'finalizada', finalizada_em = now() where id = r.id;
        v_fin := v_fin + 1;
      else
        update public.zorvin_quazar_faxina set status = 'superada' where id = r.id;
        v_sup := v_sup + 1;
      end if;
    else
      update public.zorvin_quazar_faxina set status = 'erro' where id = r.id;
      v_err := v_err + 1;
    end if;
  end loop;
  return jsonb_build_object('finalizadas', v_fin, 'superadas', v_sup, 'erros', v_err);
end
$f$$x$;

  -- ------------------------------------------------------------
  -- 9. SÓ A PONTE CHAMA: tirado de quem não entrou, de quem entrou e de
  --    `public` (a armadilha nº 5), e dado à ponte.
  -- ------------------------------------------------------------
  foreach f in array array[
    'public.zorvin_faxina_assunto(text)',
    'public.zorvin_faxina_quietas(integer, integer)',
    'public.zorvin_faxina_para_ler(integer, integer)',
    'public.zorvin_faxina_finalizar(uuid, text, text, uuid)',
    'public.zorvin_faxina_retomadas_da_vez(integer, integer, integer)',
    'public.zorvin_faxina_confirmar(integer)'] loop
    execute format('revoke all on function %s from public', f);
    if v_anon then execute format('revoke all on function %s from anon', f); end if;
    if v_auth then execute format('revoke all on function %s from authenticated', f); end if;
    if v_srv then execute format('grant execute on function %s to service_role', f); end if;
  end loop;

  -- ------------------------------------------------------------
  -- A CONFERÊNCIA
  -- ------------------------------------------------------------
  insert into zorvin_conferencia_064
  select 'o assunto SEM RETORNO DO CLIENTE existe', (public.zorvin_faxina_assunto('sem-retorno') is not null)::text;
  insert into zorvin_conferencia_064
  select 'conversas que a regra dos 7 dias finalizaria agora',
         jsonb_array_length(public.zorvin_faxina_quietas(7, 2000))::text;
  insert into zorvin_conferencia_064
  select 'conversas esperando 2 dias ou mais para o Quazar ler',
         jsonb_array_length(public.zorvin_faxina_para_ler(2000, 2))::text;
  if v_auth then
    insert into zorvin_conferencia_064 values
      ('quem entrou não chama a faxina',
       (not has_function_privilege('authenticated', 'public.zorvin_faxina_finalizar(uuid, text, text, uuid)', 'execute')
        and not has_function_privilege('authenticated', 'public.zorvin_faxina_quietas(integer, integer)', 'execute'))::text),
      ('quem entrou não lê o que o Quazar decidiu',
       (not has_table_privilege('authenticated', 'public.zorvin_quazar_faxina', 'select'))::text);
  end if;
  if v_anon then
    insert into zorvin_conferencia_064 values
      ('quem não entrou não chama a faxina',
       (not has_function_privilege('anon', 'public.zorvin_faxina_finalizar(uuid, text, text, uuid)', 'execute'))::text);
  end if;
end
$fax$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_064;
