-- ============================================================
--  066. QUEM PEDE ATENÇÃO NÃO É FINALIZADO PELA FAXINA (25/11)
--
--  >>> A PONTE APLICA SOZINHA (sql/automaticos). <<<
--  Pode rodar de novo sem medo — a pasta inteira, na ordem (regra 5).
--
--  ------------------------------------------------------------
--  O PEDIDO
--
--  Duas regras do Rodrigo, em 25/11, depois de a faxina do Quazar (064)
--  finalizar conversas que não podia:
--
--    1. a conversa de quem tem ORDEM DE SERVIÇO aberta no Vantoro não é
--       finalizada pelo Quazar: ela é do responsável pela OS;
--    2. "clientes antigos, que possuem processos de 2024 para trás, precisam
--       ser obrigatoriamente blindados. Então são casos em que não devem ser
--       finalizadas as conversas sem a blindagem ser feita."
--
--  Quem sabe as duas coisas é o VANTORO (a OS e a blindagem moram lá). A
--  ponte pergunta a lista (`GET /clientes/atencao`) e a guarda aqui; a faxina
--  pergunta a lista daqui, sem acordar o Vantoro.
--
--  ------------------------------------------------------------
--  O QUE ESTE SCRIPT ACRESCENTA
--
--    zorvin_chave_do_telefone()   o DDD e os 8 últimos dígitos: a mesma chave
--                                 para "5571988881111", "557188881111" e
--                                 "(71) 98888-1111"
--    zorvin_atencao               os clientes que pedem atenção, como o
--                                 Vantoro disse: a OS e a blindagem
--    zorvin_atencao_chaves        a chave de cada telefone deles
--    zorvin_atencao_marca         quando a lista foi trocada pela última vez
--    zorvin_atencao_trocar()      troca a lista inteira, de uma vez (só a
--                                 ponte). RECUSA a lista que encolhe pela
--                                 metade de uma vez: isso é o Vantoro
--                                 respondendo errado, e não metade dos
--                                 clientes resolvida no mesmo minuto
--    zorvin_atencao_fresca()      a lista tem menos de 36 horas
--    zorvin_pede_atencao()        o contato está na lista, pelo cliente do
--                                 Vantoro ligado a ele ou pela chave do
--                                 telefone
--    zorvin_atencao_do_contato()  o que a lista diz dele (para a ponte)
--
--  E A FAXINA (064 e 065) PASSA A PERGUNTAR. As quatro funções são as de
--  antes, mais duas linhas:
--
--    - a lista tem de estar FRESCA. Sem ela (a ponte não conseguiu falar com
--      o Vantoro, o script acabou de rodar), a faxina NÃO FINALIZA NADA: não
--      saber quem pede atenção é o caso em que finalizar é mais perigoso;
--    - o contato que pede atenção fica de fora: não é finalizado pelo
--      silêncio, não é lido pelo Quazar para ser finalizado, e não recebe a
--      mensagem de retomada (que é seguida de uma finalização).
--
--  A VERSÃO DE REFERÊNCIA (regra 5) de zorvin_faxina_quietas,
--  zorvin_faxina_para_ler, zorvin_faxina_finalizar e
--  zorvin_faxina_retomadas_da_vez passa a ser a deste script.
--
--  SEM VANTORO (quem compra o Zorvin sem ele), a ponte marca a lista como
--  vazia e fresca (`sem_vantoro`), e a faxina segue como antes.
--
--  DEPENDE DE JÁ TER RODADO: 064 e 065.
-- ============================================================

do $ate$
declare
  v_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_anon boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_srv  boolean := exists (select 1 from pg_roles where rolname = 'service_role');
  f      text;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_066;
  create temp table zorvin_conferencia_066 (item text, resposta text);

  if to_regclass('public.conversas') is null or to_regclass('public.contatos') is null
     or to_regclass('public.advogados') is null then
    insert into zorvin_conferencia_066 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 066 não fez nada.';
    return;
  end if;
  if to_regclass('public.zorvin_quazar_faxina') is null
     or to_regclass('public.zorvin_faxina_retomada') is null
     or to_regprocedure('public.zorvin_faxina_assunto(text)') is null then
    insert into zorvin_conferencia_066 values ('NÃO — falta o 064 e o 065', 'rode-os antes');
    raise notice 'Zorvin: script 066 precisa do 064 e do 065.';
    return;
  end if;

  -- ------------------------------------------------------------
  -- 1. A CHAVE DO TELEFONE: só os dígitos; sem o 55 da frente quando o
  --    número tem 12 ou 13 dígitos; o DDD e os 8 últimos. Assim a forma com
  --    e sem o nono dígito, e com e sem o país, dão a mesma chave. Menos de
  --    10 dígitos não é telefone de ninguém, e não ganha chave.
  -- ------------------------------------------------------------
  execute $x$
create or replace function public.zorvin_chave_do_telefone(p_numero text)
returns text language sql immutable set search_path = public as $f$
  select case when length(d) < 10 then null else left(d, 2) || right(d, 8) end
    from (select case when length(x) in (12, 13) and left(x, 2) = '55' then substr(x, 3) else x end as d
            from (select regexp_replace(coalesce(p_numero, ''), '\D', '', 'g') as x) a) b
$f$$x$;

  -- ------------------------------------------------------------
  -- 2. A LISTA. Só a ponte alcança (RLS ligada, sem política).
  -- ------------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_atencao (
      cliente_id     bigint primary key,
      ordem_servico  jsonb,
      blindagem      jsonb,
      telefones      text[] not null default '{}',
      atualizado_em  timestamptz not null default now()
    )$x$;
  execute $x$
    create table if not exists public.zorvin_atencao_chaves (
      chave       text not null,
      cliente_id  bigint not null references public.zorvin_atencao(cliente_id) on delete cascade,
      primary key (chave, cliente_id)
    )$x$;
  execute $x$
    create table if not exists public.zorvin_atencao_marca (
      id           boolean primary key default true check (id),
      trocada_em   timestamptz not null default now(),
      clientes     integer not null default 0,
      sem_vantoro  boolean not null default false
    )$x$;
  foreach f in array array['public.zorvin_atencao', 'public.zorvin_atencao_chaves', 'public.zorvin_atencao_marca'] loop
    execute format('alter table %s enable row level security', f);
    if v_anon then execute format('revoke all on %s from anon', f); end if;
    if v_auth then execute format('revoke all on %s from authenticated', f); end if;
    if v_srv then execute format('grant all on %s to service_role', f); end if;
  end loop;

  -- ------------------------------------------------------------
  -- 3. TROCAR A LISTA, de uma vez. `p_clientes` é a lista do Vantoro como
  --    veio: [{id, telefones[], ordem_servico, blindagem}]. A lista que
  --    encolhe pela metade (de 20 ou mais) é recusada, e a de antes fica.
  -- ------------------------------------------------------------
  execute $x$
create or replace function public.zorvin_atencao_trocar(p_clientes jsonb, p_sem_vantoro boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare
  v_antes  integer;
  v_novos  integer;
  v_chaves integer;
begin
  if p_clientes is null or jsonb_typeof(p_clientes) <> 'array' then
    raise exception 'a lista do Vantoro tem de ser uma lista' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtext('zorvin_atencao_trocar'));
  select count(*) into v_antes from public.zorvin_atencao;
  select count(distinct e ->> 'id') into v_novos from jsonb_array_elements(p_clientes) e
   where (e ->> 'id') ~ '^\d+$';
  if not p_sem_vantoro and v_antes >= 20 and v_novos * 2 < v_antes then
    return jsonb_build_object('trocada', false, 'antes', v_antes, 'novos', v_novos,
      'motivo', 'a lista encolheu mais da metade de uma vez; a de antes continua valendo');
  end if;
  delete from public.zorvin_atencao_chaves;
  delete from public.zorvin_atencao;
  insert into public.zorvin_atencao (cliente_id, ordem_servico, blindagem, telefones)
  select distinct on ((e ->> 'id')::bigint) (e ->> 'id')::bigint,
         case when jsonb_typeof(e -> 'ordem_servico') = 'object' then e -> 'ordem_servico' end,
         case when jsonb_typeof(e -> 'blindagem') = 'object' then e -> 'blindagem' end,
         coalesce(array(select regexp_replace(t, '\D', '', 'g')
                          from jsonb_array_elements_text(
                                 case when jsonb_typeof(e -> 'telefones') = 'array' then e -> 'telefones' else '[]'::jsonb end) t
                         where regexp_replace(t, '\D', '', 'g') <> ''), '{}')
    from jsonb_array_elements(p_clientes) e
   where (e ->> 'id') ~ '^\d+$'
   order by (e ->> 'id')::bigint;
  insert into public.zorvin_atencao_chaves (chave, cliente_id)
  select distinct public.zorvin_chave_do_telefone(t), a.cliente_id
    from public.zorvin_atencao a cross join unnest(a.telefones) t
   where public.zorvin_chave_do_telefone(t) is not null
  on conflict do nothing;
  get diagnostics v_chaves = row_count;
  insert into public.zorvin_atencao_marca (id, trocada_em, clientes, sem_vantoro)
  values (true, now(), v_novos, p_sem_vantoro)
  on conflict (id) do update set trocada_em = excluded.trocada_em, clientes = excluded.clientes,
                                 sem_vantoro = excluded.sem_vantoro;
  return jsonb_build_object('trocada', true, 'antes', v_antes, 'clientes', v_novos, 'chaves', v_chaves);
end
$f$$x$;

  execute $x$
create or replace function public.zorvin_atencao_fresca(p_horas integer default 36)
returns boolean language sql stable security definer set search_path = public as $f$
  select exists (select 1 from public.zorvin_atencao_marca m
                  where m.trocada_em > now() - make_interval(hours => greatest(p_horas, 1)))
$f$$x$;

  -- ------------------------------------------------------------
  -- 4. QUEM PEDE ATENÇÃO: pelo cliente do Vantoro ligado ao contato
  --    (`vantoro_cliente_id`, que nasceu à mão e vem por to_jsonb) ou pela
  --    chave do telefone.
  -- ------------------------------------------------------------
  execute $x$
create or replace function public.zorvin_atencao_do_contato(p_contato uuid)
returns jsonb language sql stable security definer set search_path = public as $f$
  select coalesce(jsonb_agg(jsonb_build_object('cliente_id', a.cliente_id, 'ordem_servico', a.ordem_servico,
                                               'blindagem', a.blindagem) order by a.cliente_id), '[]'::jsonb)
    from public.zorvin_atencao a
   where a.cliente_id in (
           select k.cliente_id from public.contatos ct
             join public.zorvin_atencao_chaves k on k.chave = public.zorvin_chave_do_telefone(ct.numero)
            where ct.id = p_contato and ct.numero not like 'grupo:%'
           union
           select (to_jsonb(ct) ->> 'vantoro_cliente_id')::bigint from public.contatos ct
            where ct.id = p_contato and (to_jsonb(ct) ->> 'vantoro_cliente_id') ~ '^\d+$')
$f$$x$;

  execute $x$
create or replace function public.zorvin_pede_atencao(p_contato uuid)
returns boolean language sql stable security definer set search_path = public as $f$
  select jsonb_array_length(public.zorvin_atencao_do_contato(p_contato)) > 0
$f$$x$;

  -- ------------------------------------------------------------
  -- 5. A FAXINA PERGUNTA. As funções do 064 e do 065, mais a lista fresca e
  --    o contato que não pede atenção.
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
       where public.zorvin_atencao_fresca()
         and c.situacao is distinct from 'finalizado'
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
         -- QUEM PEDE ATENÇÃO (a OS aberta, a blindagem dos antigos) fica para a equipe.
         and not public.zorvin_pede_atencao(c.contato_id)
       order by u.criado_em
       limit greatest(least(p_limite, 2000), 0)
    ) x
$f$$x$;

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
       where public.zorvin_atencao_fresca()
         and c.situacao is distinct from 'finalizado'
         and coalesce((to_jsonb(c) ->> 'arquivada')::boolean, false) = false
         and c.esperando_desde is not null
         and c.esperando_desde < now() - make_interval(days => greatest(p_dias, 0))
         and ct.numero not like 'grupo:%'
         and a.ativo is not false
         and not exists (select 1 from public.fila_envio f
                          where f.conversa_id = c.id and f.status in ('pendente', 'enviando'))
         and not exists (select 1 from public.zorvin_quazar_faxina q
                          where q.conversa_id = c.id and q.cliente_ate_id = uc.id)
         and not public.zorvin_pede_atencao(c.contato_id)
       order by c.esperando_desde
       limit greatest(least(p_limite, 2000), 0)
    ) x
$f$$x$;

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
  -- A SEGUNDA GUARDA (a primeira é a lista de quem a faxina pega): sem a
  -- lista fresca, ou com o contato pedindo atenção, não finaliza.
  if not public.zorvin_atencao_fresca() or public.zorvin_pede_atencao(v_contato) then
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
       -- A RETOMADA É SEGUIDA DE UMA FINALIZAÇÃO: quem pede atenção não a recebe.
       and not public.zorvin_pede_atencao(c.contato_id)
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
  -- 6. SÓ A PONTE CHAMA (create or replace guarda as permissões; ditas de
  --    novo pela armadilha nº 5). A chave do telefone é de todos: não lê nada.
  -- ------------------------------------------------------------
  foreach f in array array[
    'public.zorvin_atencao_trocar(jsonb, boolean)',
    'public.zorvin_atencao_fresca(integer)',
    'public.zorvin_atencao_do_contato(uuid)',
    'public.zorvin_pede_atencao(uuid)',
    'public.zorvin_faxina_quietas(integer, integer)',
    'public.zorvin_faxina_para_ler(integer, integer)',
    'public.zorvin_faxina_finalizar(uuid, text, text, uuid)',
    'public.zorvin_faxina_retomadas_da_vez(integer, integer, integer)'] loop
    execute format('revoke all on function %s from public', f);
    if v_anon then execute format('revoke all on function %s from anon', f); end if;
    if v_auth then execute format('revoke all on function %s from authenticated', f); end if;
    if v_srv then execute format('grant execute on function %s to service_role', f); end if;
  end loop;

  -- ------------------------------------------------------------
  -- A CONFERÊNCIA
  -- ------------------------------------------------------------
  insert into zorvin_conferencia_066
  select 'a chave do telefone junta as formas com e sem o nono dígito e o país',
         (public.zorvin_chave_do_telefone('5571988881111') = '7188881111'
          and public.zorvin_chave_do_telefone('557188881111') = '7188881111'
          and public.zorvin_chave_do_telefone('(71) 98888-1111') = '7188881111'
          and public.zorvin_chave_do_telefone('123') is null)::text;
  insert into zorvin_conferencia_066
  select 'clientes na lista do Vantoro agora', (select count(*) from public.zorvin_atencao)::text;
  insert into zorvin_conferencia_066
  select 'a lista está fresca (sem ela, a faxina não finaliza nada até a ponte trazê-la)',
         case when public.zorvin_atencao_fresca() then 'sim'
              else 'ainda não: a ponte traz a lista do Vantoro na subida' end;
  insert into zorvin_conferencia_066
  select 'conversas abertas de quem pede atenção (a faxina não as finaliza)',
         (select count(*) from public.conversas c
           where c.situacao is distinct from 'finalizado'
             and coalesce((to_jsonb(c) ->> 'arquivada')::boolean, false) = false
             and public.zorvin_pede_atencao(c.contato_id))::text;
  if v_auth then
    insert into zorvin_conferencia_066 values
      ('quem entrou não lê nem muda a lista',
       (not has_table_privilege('authenticated', 'public.zorvin_atencao', 'select')
        and not has_table_privilege('authenticated', 'public.zorvin_atencao_chaves', 'select')
        and not has_table_privilege('authenticated', 'public.zorvin_atencao_marca', 'update'))::text),
      ('quem entrou não troca a lista nem chama a faxina',
       (not has_function_privilege('authenticated', 'public.zorvin_atencao_trocar(jsonb, boolean)', 'execute')
        and not has_function_privilege('authenticated', 'public.zorvin_faxina_finalizar(uuid, text, text, uuid)', 'execute'))::text);
  end if;
  if v_anon then
    insert into zorvin_conferencia_066 values
      ('quem não entrou não alcança a lista',
       (not has_table_privilege('anon', 'public.zorvin_atencao', 'select')
        and not has_function_privilege('anon', 'public.zorvin_pede_atencao(uuid)', 'execute'))::text);
  end if;
end
$ate$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_066;
