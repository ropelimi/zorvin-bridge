-- ============================================================
--  068. SÓ QUEM ESPERA RESPOSTA FICA, E A EQUIPE É AVISADA (25/11)
--
--  >>> A PONTE APLICA SOZINHA (sql/automaticos). <<<
--  Pode rodar de novo sem medo — a pasta inteira, na ordem (regra 5).
--
--  ------------------------------------------------------------
--  O PEDIDO
--
--  O 066 tirou da faxina toda conversa de quem tem ORDEM DE SERVIÇO aberta
--  no Vantoro ou é cliente antigo (ação de 2024 para trás) sem a BLINDAGEM
--  completa. No mesmo dia o Rodrigo afinou a regra:
--
--    "Para as conversas em que o cliente não respondeu, pode finalizar como
--    SEM RETORNO DO CLIENTE, mesmo se precisar fazer a blindagem ou tiver OS
--    aberta [...] a regra de não finalizar deve ser para as conversas em que
--    o contato está aguardando mensagem, que fez alguma pergunta [...] mas
--    tem que sinalizar a equipe pois existe OS aberta e/ou precisa blindar.
--    Agora, para as conversas em que o Quazar entender que já foi
--    finalizada, onde o contato mandou um obrigado ou ok e etc, também pode
--    finalizar."
--
--  E, antes, quem recebe o aviso: a OS, o responsável pela OS e os
--  responsáveis pelas pendências; a blindagem, o responsável da conversa —
--  "mas a equipe toda deve ter acesso, poder saber com quem está".
--
--  ------------------------------------------------------------
--  A FAXINA, DAQUI PARA A FRENTE (a versão de referência — regra 5 — de
--  zorvin_faxina_quietas, zorvin_faxina_para_ler e zorvin_faxina_finalizar
--  passa a ser a deste script)
--
--    o silêncio de 7 dias            finaliza (SEM RETORNO DO CLIENTE), com ou
--                                    sem OS e blindagem, e SEM depender da
--                                    lista do Vantoro
--    o Quazar lê quem espera         lê também quem pede atenção; "obrigado",
--                                    "ok" e propaganda finalizam, como sempre
--    o cliente espera resposta       NÃO finaliza quem pede atenção: a
--      (o Quazar leu "pendente")     conversa fica, e a equipe é avisada
--    a mensagem de retomada          continua fora para quem pede atenção (ela
--                                    é seguida de uma finalização), e a
--                                    confirmação dela continua pedindo a
--                                    lista fresca (zorvin_faxina_retomadas_da_vez
--                                    não muda: é a do 066)
--
--  ------------------------------------------------------------
--  O AVISO À EQUIPE
--
--    zorvin_atencao_avisos    a nota que cada conversa já recebeu, por cliente,
--                             motivo e referência (a OS, pelo número; a
--                             blindagem): UMA VEZ SÓ por conversa
--    zorvin_atencao_tarefas   a tarefa que cada pessoa já recebeu, por cliente,
--                             motivo e referência: UMA VEZ SÓ por pessoa, mesmo
--                             com o cliente em duas conversas
--    zorvin_atencao_avisar()  a rodada — só a ponte chama, de 10 em 10 minutos
--
--  QUAIS CONVERSAS: as de quem pede atenção em que o cliente espera resposta
--  e o Quazar leu a última mensagem dele como PENDENTE (uma pergunta, um
--  pedido). Encerrou ou era propaganda: ela já foi finalizada.
--
--    - SÓ COM A LISTA FRESCA (a do 066), e não sem Vantoro;
--    - SÓ NO EXPEDIENTE do departamento (a semana da aba Fora do horário, a
--      régua do 045): a tarefa nasce vencida, e o Zorvin de quem a recebe
--      toca o aviso. De madrugada, ela tocaria para ninguém;
--    - QUEM RECEBE A TAREFA DA OS: os logins que o Vantoro manda (o
--      responsável e os das pendências), achados em `usuarios.login`, ativos
--      e que veem o telefone da conversa (`zorvin_ve_o_telefone`, do 023).
--      Ninguém da OS no Zorvin: o responsável da conversa. Nem ele: a tarefa
--      fica SEM DONO, e aparece em "Da equipe";
--    - QUEM RECEBE A DA BLINDAGEM: o responsável da conversa; sem ele, sem dono;
--    - O TETO: 20 tarefas por pessoa por dia (o dia de São Paulo), e 5 por
--      pessoa a cada volta, para o aviso não tocar vinte vezes seguidas. Sem
--      dono conta como uma pessoa. Passando do teto, a conversa espera a volta
--      seguinte, e a nota espera junto: nota e tarefa chegam juntas;
--    - A ORDEM: quem espera resposta há mais tempo primeiro;
--    - A TAREFA SE FECHA SOZINHA quando o motivo sai da lista do Vantoro (a
--      OS foi concluída, a blindagem ficou completa), e só com a lista fresca;
--    - A TAREFA APAGADA NÃO VOLTA: o registro fica, e apagar é o jeito de
--      dizer "não precisa".
--
--  NADA AQUI FALA COM O CLIENTE: a nota e a tarefa são da equipe.
--
--  A NOTA É DO QUAZAR (`autor` = 'Quazar', sem `autor_id`), e a ponte não a
--  sobe para a ficha do Vantoro: ela fala da faxina do Zorvin, e não do caso.
--
--  DEPENDE DE JÁ TER RODADO: 018 (tarefas), 028 (situação e protocolo), 064,
--  065 e 066 (a faxina e a lista de quem pede atenção).
-- ============================================================

do $ate$
declare
  v_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_anon boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_srv  boolean := exists (select 1 from pg_roles where rolname = 'service_role');
  f      text;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_068;
  create temp table zorvin_conferencia_068 (item text, resposta text);

  if to_regclass('public.conversas') is null or to_regclass('public.contatos') is null
     or to_regclass('public.advogados') is null or to_regclass('public.notas') is null
     or to_regclass('public.usuarios') is null then
    insert into zorvin_conferencia_068 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 068 não fez nada.';
    return;
  end if;
  if to_regclass('public.zorvin_tarefas') is null
     or to_regclass('public.zorvin_atencao') is null
     or to_regclass('public.zorvin_quazar_faxina') is null
     or to_regprocedure('public.zorvin_faxina_assunto(text)') is null
     or to_regprocedure('public.zorvin_atencao_do_contato(uuid)') is null
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'conversas' and column_name = 'situacao')
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'conversas' and column_name = 'responsavel_id')
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'conversas' and column_name = 'esperando_desde') then
    insert into zorvin_conferencia_068 values ('NÃO — falta o 018, o 028, o 064 ou o 066', 'rode-os antes');
    raise notice 'Zorvin: script 068 precisa do 018, do 028, do 064 e do 066.';
    return;
  end if;

  -- ------------------------------------------------------------
  -- A. A FAXINA. As funções do 066, com a trava só para quem espera.
  --
  --    O SILÊNCIO DE 7 DIAS: sem a pergunta "pede atenção?" e sem a lista
  --    fresca. Quem tem OS aberta e não respondeu é finalizado como SEM
  --    RETORNO DO CLIENTE; quando o responsável pela OS chamar o cliente, ou o
  --    cliente escrever, a conversa reabre com protocolo novo (028).
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

  -- O QUAZAR LÊ TAMBÉM QUEM PEDE ATENÇÃO: "obrigado", "ok" e propaganda
  -- finalizam; o que ele ler como pendente fica, e a equipe é avisada (a
  -- rodada daqui). `retoma` é falso para quem pede atenção: a retomada é
  -- seguida de uma finalização, e ela não é dele.
  execute $x$
create or replace function public.zorvin_faxina_para_ler(p_limite integer default 10, p_dias integer default 2)
returns jsonb language sql stable security definer set search_path = public as $f$
  select coalesce(jsonb_agg(jsonb_build_object(
           'conversa_id', x.id, 'advogado_id', x.advogado_id, 'cliente_ate_id', x.msg_id,
           'cliente_ate', x.msg_em, 'esperando_desde', x.esperando_desde,
           'dias', floor(extract(epoch from now() - x.esperando_desde) / 86400)::int,
           'retoma', x.retoma and not public.zorvin_pede_atencao(x.contato_id))
         order by x.esperando_desde), '[]'::jsonb)
    from (
      select c.id, c.advogado_id, c.contato_id, c.esperando_desde, uc.id as msg_id, uc.criado_em as msg_em,
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

  -- FINALIZAR: a trava de quem pede atenção (e a lista fresca) fica só na
  -- confirmação da RETOMADA ('sem-retorno' com a mensagem lida): ali o
  -- cliente esperava resposta. O silêncio ('sem-retorno' sem mensagem lida) e
  -- o que o Quazar leu como encerrado ou propaganda finalizam sem ela.
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
  v_contato  uuid;
begin
  select c.situacao, c.esperando_desde, to_jsonb(c), c.contato_id into v_situacao, v_espera, v_j, v_contato
    from public.conversas c where c.id = p_conversa for update;
  if not found or v_situacao = 'finalizado' or coalesce((v_j ->> 'arquivada')::boolean, false) then
    return false;
  end if;
  -- A RETOMADA: o cliente esperava resposta. Sem a lista fresca, ou com o
  -- contato pedindo atenção, não finaliza.
  if p_qual = 'sem-retorno' and p_cliente_ate_id is not null
     and (not public.zorvin_atencao_fresca() or public.zorvin_pede_atencao(v_contato)) then
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
  insert into public.zorvin_tratamentos (conversa_id, assunto_id, quem, esperava_desde, observacao)
  values (p_conversa, v_assunto, null, v_espera,
          left(coalesce(nullif(btrim(p_obs), ''), 'Finalizada pelo Quazar.'), 500));
  return exists (select 1 from public.conversas where id = p_conversa and situacao = 'finalizado');
end
$f$$x$;

  -- ------------------------------------------------------------
  -- 1. O REGISTRO. Só a ponte alcança (RLS ligada, sem política).
  -- ------------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_atencao_avisos (
      id           uuid primary key default gen_random_uuid(),
      conversa_id  uuid not null references public.conversas(id) on delete cascade,
      cliente_id   bigint not null,
      motivo       text not null check (motivo in ('os', 'blindagem')),
      referencia   text not null,
      nota_id      uuid references public.notas(id) on delete set null,
      criado_em    timestamptz not null default now(),
      unique (conversa_id, cliente_id, motivo, referencia)
    )$x$;
  execute $x$
    create table if not exists public.zorvin_atencao_tarefas (
      id           uuid primary key default gen_random_uuid(),
      cliente_id   bigint not null,
      motivo       text not null check (motivo in ('os', 'blindagem')),
      referencia   text not null,
      para_quem    uuid references public.usuarios(id) on delete set null,
      tarefa_id    uuid references public.zorvin_tarefas(id) on delete set null,
      conversa_id  uuid references public.conversas(id) on delete set null,
      criado_em    timestamptz not null default now(),
      fechada_em   timestamptz
    )$x$;
  -- UMA TAREFA POR PESSOA (e uma "da equipe", sem dono) para cada cliente,
  -- motivo e referência. `nulls not distinct`: sem dono também é um só.
  execute $x$
    create unique index if not exists zorvin_atencao_tarefas_uma_por_pessoa
      on public.zorvin_atencao_tarefas (cliente_id, motivo, referencia, para_quem) nulls not distinct$x$;
  execute $x$
    create index if not exists zorvin_atencao_tarefas_do_dia
      on public.zorvin_atencao_tarefas (criado_em)$x$;
  foreach f in array array['public.zorvin_atencao_avisos', 'public.zorvin_atencao_tarefas'] loop
    execute format('alter table %s enable row level security', f);
    if v_anon then execute format('revoke all on %s from anon', f); end if;
    if v_auth then execute format('revoke all on %s from authenticated', f); end if;
    if v_srv then execute format('grant all on %s to service_role', f); end if;
  end loop;

  -- ------------------------------------------------------------
  -- 2. A RODADA. Devolve { notas, tarefas, adiadas, fechadas }; o log da
  --    ponte leva só esses números.
  -- ------------------------------------------------------------
  execute $x$
create or replace function public.zorvin_atencao_avisar(p_limite integer default 20, p_por_pessoa integer default 20,
                                                        p_por_volta integer default 5)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare
  r          record;
  m          record;
  p          uuid;
  v_hoje     timestamptz := (date_trunc('day', now() at time zone 'America/Sao_Paulo')) at time zone 'America/Sao_Paulo';
  v_limite   integer := greatest(least(coalesce(p_limite, 20), 200), 1);
  v_teto     integer := greatest(least(coalesce(p_por_pessoa, 20), 200), 1);
  v_volta    integer := greatest(least(coalesce(p_por_volta, 5), 200), 1);
  v_tem_ve   boolean := to_regprocedure('public.zorvin_ve_o_telefone(uuid,uuid)') is not null;
  v_fechados bigint[] := '{}';
  v_notas    integer := 0;
  v_tarefas  integer := 0;
  v_adiadas  integer := 0;
  v_fechadas integer := 0;
  v_logins   text[];
  v_pessoas  uuid[];
  v_novas    uuid[];
  v_ve       boolean;
  v_resp     uuid;
  v_ok       boolean;
  v_ja       integer;
  v_tarefa   uuid;
  v_nota     uuid;
  v_texto    text;
  v_nota_txt text;
  v_quem_txt text;
  v_ref_txt  text;
  v_n        integer;
begin
  -- SEM A LISTA FRESCA, NADA: não saber quem pede atenção não é motivo para
  -- avisar, nem para fechar a tarefa de ninguém. Sem Vantoro, a lista é vazia.
  if to_regprocedure('public.zorvin_atencao_fresca(integer)') is null or not public.zorvin_atencao_fresca()
     or exists (select 1 from public.zorvin_atencao_marca mk where mk.sem_vantoro) then
    return jsonb_build_object('notas', 0, 'tarefas', 0, 'adiadas', 0, 'fechadas', 0, 'sem_lista', true);
  end if;
  -- UMA RODADA POR VEZ: numa publicação há duas pontes vivas, e as duas
  -- deixariam a mesma nota.
  perform pg_advisory_xact_lock(hashtext('zorvin_atencao_avisar'));

  -- 1. A TAREFA SE FECHA SOZINHA quando o motivo saiu da lista: a OS foi
  -- concluída (ou é outra), a blindagem ficou completa, o cliente saiu.
  -- `feita_por` fica vazio pelo gatilho do 018: foi o Zorvin.
  with sairam as (
    select t.id, t.tarefa_id
      from public.zorvin_atencao_tarefas t
     where t.fechada_em is null
       and not exists (
             select 1 from public.zorvin_atencao a
              where a.cliente_id = t.cliente_id
                and ((t.motivo = 'os' and jsonb_typeof(a.ordem_servico) = 'object'
                      and coalesce(nullif(btrim(a.ordem_servico ->> 'id'), ''), 'os') = t.referencia)
                  or (t.motivo = 'blindagem' and a.blindagem -> 'precisa_blindar' = 'true'::jsonb)))
  ), fecha as (
    update public.zorvin_tarefas zt set feita_em = now()
      from sairam s
     where zt.id = s.tarefa_id and zt.feita_em is null
     returning zt.id
  )
  select count(*) into v_fechadas from fecha;
  update public.zorvin_atencao_tarefas t set fechada_em = now()
   where t.fechada_em is null
     and not exists (
           select 1 from public.zorvin_atencao a
            where a.cliente_id = t.cliente_id
              and ((t.motivo = 'os' and jsonb_typeof(a.ordem_servico) = 'object'
                    and coalesce(nullif(btrim(a.ordem_servico ->> 'id'), ''), 'os') = t.referencia)
                or (t.motivo = 'blindagem' and a.blindagem -> 'precisa_blindar' = 'true'::jsonb)));

  -- 2. O EXPEDIENTE (021, a régua do 045): o departamento fechado agora
  -- espera abrir. A semana sem nenhum dia aberto não segura nada.
  if to_regprocedure('public.zorvin_horario_de(jsonb,text,timestamptz)') is not null
     and to_regclass('public.zorvin_fora_do_horario') is not null then
    execute $q$
      select coalesce(array_agg(h.departamento_id), '{}')
        from (select fh.departamento_id, public.zorvin_horario_de(fh.semana, fh.fuso, now()) as hr
                from public.zorvin_fora_do_horario fh) h
       where (h.hr ->> 'aberto')::boolean is false and h.hr ->> 'abre_em' is not null
    $q$ into v_fechados;
  end if;

  -- 3. AS CONVERSAS EM QUE O CLIENTE ESPERA RESPOSTA, de quem pede atenção,
  -- e o Quazar leu a última mensagem dele como PENDENTE (o que a faxina
  -- deixa para a equipe). 'retomar' é o pendente de 30 dias ou mais; e a
  -- retomada que já saiu (e foi desfeita) também conta: o cliente continua
  -- esperando.
  for r in
    select c.id as conversa_id, c.advogado_id, c.contato_id, c.responsavel_id, a.departamento_id,
           c.esperando_desde, public.zorvin_atencao_do_contato(c.contato_id) as atencao
      from public.conversas c
      join public.advogados a on a.id = c.advogado_id
      join public.contatos ct on ct.id = c.contato_id
      cross join lateral (select mm.id from public.mensagens mm
                           where mm.conversa_id = c.id and mm.origem = 'contato'
                           order by mm.criado_em desc, mm.id desc limit 1) uc
      join public.zorvin_quazar_faxina q on q.conversa_id = c.id and q.cliente_ate_id = uc.id
     where c.situacao is distinct from 'finalizado'
       and coalesce((to_jsonb(c) ->> 'arquivada')::boolean, false) = false
       and c.esperando_desde is not null
       and ct.numero not like 'grupo:%'
       and a.ativo is not false
       and not (a.departamento_id = any (v_fechados))
       and (q.status in ('pendente', 'retomar')
            or (q.status in ('retomada', 'finalizada') and q.retomada_em is not null))
       and not exists (select 1 from public.fila_envio fe
                        where fe.conversa_id = c.id and fe.status in ('pendente', 'enviando'))
       and public.zorvin_pede_atencao(c.contato_id)
     order by c.esperando_desde, c.id
  loop
    exit when v_notas >= v_limite;

    -- O RESPONSÁVEL DA CONVERSA, se pode receber: ativo e vendo o telefone.
    v_resp := null;
    if r.responsavel_id is not null
       and exists (select 1 from public.usuarios us where us.id = r.responsavel_id and us.ativo is not false) then
      v_ve := true;
      if v_tem_ve then
        execute 'select public.zorvin_ve_o_telefone($1, $2)' into v_ve using r.responsavel_id, r.advogado_id;
      end if;
      if coalesce(v_ve, false) then v_resp := r.responsavel_id; end if;
    end if;

    for m in
      select (e ->> 'cliente_id')::bigint as cliente_id, 'os'::text as motivo,
             coalesce(nullif(btrim(e -> 'ordem_servico' ->> 'id'), ''), 'os') as referencia,
             e -> 'ordem_servico' as dados
        from jsonb_array_elements(r.atencao) e
       where jsonb_typeof(e -> 'ordem_servico') = 'object'
      union all
      select (e ->> 'cliente_id')::bigint, 'blindagem', 'blindagem', e -> 'blindagem'
        from jsonb_array_elements(r.atencao) e
       where e -> 'blindagem' -> 'precisa_blindar' = 'true'::jsonb
    loop
      continue when exists (select 1 from public.zorvin_atencao_avisos av
                             where av.conversa_id = r.conversa_id and av.cliente_id = m.cliente_id
                               and av.motivo = m.motivo and av.referencia = m.referencia);

      -- QUEM RECEBE A TAREFA.
      v_pessoas := '{}';
      v_quem_txt := null;
      if m.motivo = 'os' then
        v_logins := array(
          select distinct lower(btrim(l)) from (
            select m.dados -> 'responsavel' ->> 'login' as l
            union all
            select pe ->> 'login' from jsonb_array_elements(
              case when jsonb_typeof(m.dados -> 'responsaveis_das_pendencias') = 'array'
                   then m.dados -> 'responsaveis_das_pendencias' else '[]'::jsonb end) pe) z
           where nullif(btrim(l), '') is not null);
        for p in
          select us.id from public.usuarios us
           where lower(btrim(to_jsonb(us) ->> 'login')) = any (v_logins) and us.ativo is not false
           order by us.nome, us.id
        loop
          v_ve := true;
          if v_tem_ve then
            execute 'select public.zorvin_ve_o_telefone($1, $2)' into v_ve using p, r.advogado_id;
          end if;
          if coalesce(v_ve, false) then v_pessoas := v_pessoas || p; end if;
        end loop;
        if cardinality(v_pessoas) = 0 and v_resp is not null then
          v_pessoas := array[v_resp];
          v_quem_txt := ' (o responsável pela conversa: ninguém da OS está no Zorvin com acesso a este telefone)';
        end if;
      else
        if v_resp is not null then v_pessoas := array[v_resp]; end if;
      end if;
      if cardinality(v_pessoas) = 0 then v_pessoas := array[null::uuid]; end if;

      -- O TETO: quem ainda não tem a tarefa deste cliente e motivo, e já
      -- chegou às 20 do dia (ou às 5 desta volta), segura a conversa.
      v_novas := '{}';
      v_ok := true;
      foreach p in array v_pessoas loop
        continue when exists (select 1 from public.zorvin_atencao_tarefas t
                               where t.cliente_id = m.cliente_id and t.motivo = m.motivo
                                 and t.referencia = m.referencia and t.para_quem is not distinct from p);
        select count(*) into v_ja from public.zorvin_atencao_tarefas t
         where t.para_quem is not distinct from p and t.criado_em >= v_hoje;
        if v_ja >= v_teto then v_ok := false; exit; end if;
        -- A VOLTA DE AGORA: tudo o que esta transação criou tem `criado_em` = now().
        select count(*) into v_ja from public.zorvin_atencao_tarefas t
         where t.para_quem is not distinct from p and t.criado_em >= now();
        if v_ja >= v_volta then v_ok := false; exit; end if;
        v_novas := v_novas || p;
      end loop;
      if not v_ok then v_adiadas := v_adiadas + 1; continue; end if;

      -- OS TEXTOS. Nenhum dado do cliente: a tarefa e a nota já estão na
      -- conversa dele.
      if m.motivo = 'os' then
        v_n := case when (m.dados ->> 'pendencias') ~ '^\d+$' then least((m.dados ->> 'pendencias')::bigint, 9999)::integer else 0 end;
        v_ref_txt := case when m.referencia = 'os' then 'uma Ordem de Serviço' else 'a Ordem de Serviço nº ' || m.referencia end;
        v_texto := left(case when m.referencia = 'os' then 'OS' else 'OS nº ' || m.referencia end
                   || ' aberta no Vantoro'
                   || case when v_n > 0 then ' (' || v_n || ' pendência' || case when v_n > 1 then 's' else '' end || ')' else '' end
                   || ': o cliente espera resposta nesta conversa.', 500);
      else
        v_texto := left('Blindar o cliente: tem ação de 2024 para trás sem a blindagem completa'
                   || case when (m.dados ->> 'total') ~ '^\d+$'
                           then ' (' || coalesce(nullif(m.dados ->> 'blindadas', ''), '0') || ' de ' || (m.dados ->> 'total')
                                || ' ações blindadas)' else '' end
                   || '. Ele espera resposta nesta conversa.', 500);
      end if;

      foreach p in array v_novas loop
        insert into public.zorvin_tarefas (conversa_id, texto, vence_em, para_quem)
        values (r.conversa_id, v_texto, now(), p) returning id into v_tarefa;
        insert into public.zorvin_atencao_tarefas (cliente_id, motivo, referencia, para_quem, tarefa_id, conversa_id)
        values (m.cliente_id, m.motivo, m.referencia, p, v_tarefa, r.conversa_id);
        v_tarefas := v_tarefas + 1;
      end loop;

      -- QUEM ESTÁ COM A TAREFA, pelo nome do Zorvin, para a equipe saber.
      v_nota_txt := (select string_agg(coalesce(nullif(btrim(us.nome), ''), 'alguém da equipe'), ', ' order by us.nome)
                       from public.zorvin_atencao_tarefas t join public.usuarios us on us.id = t.para_quem
                      where t.cliente_id = m.cliente_id and t.motivo = m.motivo and t.referencia = m.referencia);
      if v_nota_txt is null then v_nota_txt := 'a equipe (sem dono: aparece em "Da equipe", nas Tarefas)'; end if;

      if m.motivo = 'os' then
        v_nota_txt := 'O cliente espera resposta, e não finalizei esta conversa porque ele tem ' || v_ref_txt || ' aberta no Vantoro'
          || case when v_n > 0 then ', com ' || v_n || ' pendência' || case when v_n > 1 then 's' else '' end else '' end
          || '. Responsável pela OS: '
          || coalesce(nullif(btrim(m.dados -> 'responsavel' ->> 'nome'), ''), 'ninguém no Vantoro') || '.'
          || coalesce(' Pendências com: ' || (
               select string_agg(distinct nullif(btrim(pe ->> 'nome'), ''), ', ')
                 from jsonb_array_elements(case when jsonb_typeof(m.dados -> 'responsaveis_das_pendencias') = 'array'
                                                then m.dados -> 'responsaveis_das_pendencias' else '[]'::jsonb end) pe) || '.', '')
          || ' Tarefa com: ' || v_nota_txt || coalesce(v_quem_txt, '') || '.';
      else
        v_nota_txt := 'O cliente espera resposta, e não finalizei esta conversa porque ele tem ação de 2024 para trás e a blindagem ainda não está completa no Vantoro'
          || case when (m.dados ->> 'total') ~ '^\d+$'
                  then ' (' || coalesce(nullif(m.dados ->> 'blindadas', ''), '0') || ' de ' || (m.dados ->> 'total') || ' ações blindadas)'
                  else '' end
          || '. ' || case when v_resp is not null
                          then 'Esta conversa está com ' || coalesce((select nullif(btrim(us.nome), '') from public.usuarios us where us.id = v_resp), 'alguém da equipe') || '.'
                          else 'Esta conversa ainda não tem responsável.' end
          || ' Tarefa com: ' || v_nota_txt || '.';
      end if;

      insert into public.notas (conversa_id, texto, autor)
      values (r.conversa_id, left(v_nota_txt, 2000), 'Quazar') returning id into v_nota;
      insert into public.zorvin_atencao_avisos (conversa_id, cliente_id, motivo, referencia, nota_id)
      values (r.conversa_id, m.cliente_id, m.motivo, m.referencia, v_nota);
      v_notas := v_notas + 1;
    end loop;
  end loop;

  return jsonb_build_object('notas', v_notas, 'tarefas', v_tarefas, 'adiadas', v_adiadas, 'fechadas', v_fechadas);
end
$f$$x$;

  -- ------------------------------------------------------------
  -- 3. SÓ A PONTE CHAMA (create or replace guarda as permissões; ditas de
  --    novo pela armadilha nº 5).
  -- ------------------------------------------------------------
  foreach f in array array[
    'public.zorvin_faxina_quietas(integer, integer)',
    'public.zorvin_faxina_para_ler(integer, integer)',
    'public.zorvin_faxina_finalizar(uuid, text, text, uuid)',
    'public.zorvin_atencao_avisar(integer, integer, integer)'] loop
    execute format('revoke all on function %s from public', f);
    if v_anon then execute format('revoke all on function %s from anon', f); end if;
    if v_auth then execute format('revoke all on function %s from authenticated', f); end if;
    if v_srv then execute format('grant execute on function %s to service_role', f); end if;
  end loop;

  -- ------------------------------------------------------------
  -- A CONFERÊNCIA
  -- ------------------------------------------------------------
  insert into zorvin_conferencia_068
  select 'conversas de quem pede atenção em que o cliente espera resposta (ficam, e a equipe é avisada)',
         (select count(*) from public.conversas c
           where c.situacao is distinct from 'finalizado'
             and coalesce((to_jsonb(c) ->> 'arquivada')::boolean, false) = false
             and c.esperando_desde is not null
             and public.zorvin_pede_atencao(c.contato_id))::text;
  insert into zorvin_conferencia_068
  select 'o silêncio de 7 dias pega quem pede atenção (finaliza como SEM RETORNO DO CLIENTE)',
         (select count(*) from jsonb_array_elements(public.zorvin_faxina_quietas(7, 2000)) e
            join public.conversas c on c.id = (e ->> 'conversa_id')::uuid
           where public.zorvin_pede_atencao(c.contato_id))::text;
  insert into zorvin_conferencia_068
  select 'notas que o Quazar já deixou', (select count(*) from public.zorvin_atencao_avisos)::text;
  insert into zorvin_conferencia_068
  select 'tarefas que o Quazar já criou', (select count(*) from public.zorvin_atencao_tarefas)::text;
  if v_auth then
    insert into zorvin_conferencia_068 values
      ('quem entrou não lê o registro nem chama a rodada',
       (not has_table_privilege('authenticated', 'public.zorvin_atencao_avisos', 'select')
        and not has_table_privilege('authenticated', 'public.zorvin_atencao_tarefas', 'select')
        and not has_function_privilege('authenticated', 'public.zorvin_atencao_avisar(integer, integer, integer)', 'execute'))::text);
  end if;
  if v_anon then
    insert into zorvin_conferencia_068 values
      ('quem não entrou não alcança o registro',
       (not has_table_privilege('anon', 'public.zorvin_atencao_avisos', 'select')
        and not has_function_privilege('anon', 'public.zorvin_atencao_avisar(integer, integer, integer)', 'execute'))::text);
  end if;
end
$ate$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_068;
