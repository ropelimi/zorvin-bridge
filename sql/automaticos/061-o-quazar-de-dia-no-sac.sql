-- ============================================================
--  O QUAZAR DE DIA NO SAC, EM ENSAIO
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  A ponte aplica sozinha ao subir (sql/automaticos). Pode rodar de novo sem
--  medo — na ordem da pasta, como diz a regra 5 do LEIA-ME.
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido do Rodrigo em 19/11: o Quazar lê a conversa, as intimações, os
--  andamentos e as tarefas do cliente (Vantoro e ADVBOX), num ENSAIO em que
--  ele responderia sozinho os clientes NOVOS do telefone do SAC. Decidido com
--  ele: "novo" é a conversa na aba Novos (028), e ele pode contar o andamento
--  em linguagem simples, sem prometer prazo nem resultado.
--
--    zorvin_quazar_de_dia               por telefone: 'desligado' ou 'ensaio'.
--                                       Nasce com o SAC em ensaio, uma vez só
--                                       (a semente `quazar:ensaio-de-dia-061`)
--    zorvin_quazar_noturno.periodo      'noite' (as de sempre) ou 'dia': a
--                                       resposta do ensaio de dia mora na
--                                       mesma tabela, e a tela a mostra igual,
--                                       com "boa" e "ruim"
--    zorvin_quazar_noturno.contexto     o que ele leu do caso (só contagens:
--                                       "2 processos, 3 tarefas")
--    zorvin_quazar_de_dia_pendentes     quem está esperando o Quazar de dia
--                                       agora — só a ponte chama
--    zorvin_quazar_noturno_pendentes    a do 059, com o ensaio de dia fora de
--                                       "o Quazar já respondeu": ele não foi
--                                       ao cliente
--
--  NADA VAI AO CLIENTE NESTE SCRIPT. É ensaio: a equipe lê na conversa e
--  marca se ele acertou.
--
--  A VERSÃO DE REFERÊNCIA de `zorvin_quazar_noturno_pendentes` passa a ser a
--  deste script (regra 5 do LEIA-ME).
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    021, 028, 055 e 059. Sem eles, não faz nada, e diz por quê.
-- ============================================================

do $dia$
declare
  v_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_anon boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_srv  boolean := exists (select 1 from pg_roles where rolname = 'service_role');
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_061;
  create temp table zorvin_conferencia_061 (item text, resposta text);

  if to_regclass('public.conversas') is null or to_regclass('public.mensagens') is null
     or to_regclass('public.fila_envio') is null or to_regclass('public.advogados') is null then
    insert into zorvin_conferencia_061 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 061 não fez nada.';
    return;
  end if;
  if to_regclass('public.zorvin_quazar_noturno') is null
     or not exists (select 1 from information_schema.columns where table_schema = 'public'
                     and table_name = 'fila_envio' and column_name = 'pelo_quazar')
     or not exists (select 1 from information_schema.columns where table_schema = 'public'
                     and table_name = 'conversas' and column_name = 'situacao')
     or to_regprocedure('public.zorvin_horario_de(jsonb, text, timestamptz)') is null then
    insert into zorvin_conferencia_061 values ('NÃO — falta o 021, o 028, o 055 ou o 059', 'rode-os antes');
    raise notice 'Zorvin: script 061 precisa do 021, do 028, do 055 e do 059.';
    return;
  end if;

  -- ------------------------------------------------------------
  -- 1. O PERÍODO E O QUE ELE LEU
  -- ------------------------------------------------------------
  execute $x$alter table public.zorvin_quazar_noturno add column if not exists periodo text not null default 'noite'$x$;
  if not exists (select 1 from pg_constraint where conname = 'zorvin_quazar_noturno_periodo_check') then
    execute $x$alter table public.zorvin_quazar_noturno add constraint zorvin_quazar_noturno_periodo_check
               check (periodo in ('noite', 'dia'))$x$;
  end if;
  execute 'alter table public.zorvin_quazar_noturno add column if not exists contexto text';
  if not exists (select 1 from pg_constraint where conname = 'zorvin_quazar_noturno_contexto_check') then
    execute $x$alter table public.zorvin_quazar_noturno add constraint zorvin_quazar_noturno_contexto_check
               check (contexto is null or length(contexto) <= 300)$x$;
  end if;

  -- ------------------------------------------------------------
  -- 2. QUAIS TELEFONES ESTÃO EM ENSAIO DE DIA
  -- ------------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_quazar_de_dia (
      advogado_id    uuid primary key references public.advogados(id) on delete cascade,
      modo           text not null default 'desligado' check (modo in ('desligado', 'ensaio')),
      atualizado_em  timestamptz not null default now(),
      atualizado_por uuid
    )$x$;
  execute 'alter table public.zorvin_quazar_de_dia enable row level security';
  if v_anon then execute 'revoke all on public.zorvin_quazar_de_dia from anon'; end if;
  if v_auth then
    execute 'revoke all on public.zorvin_quazar_de_dia from authenticated';
    execute 'grant select on public.zorvin_quazar_de_dia to authenticated';
    execute 'drop policy if exists zorvin_quazar_de_dia_leitura on public.zorvin_quazar_de_dia';
    execute 'create policy zorvin_quazar_de_dia_leitura on public.zorvin_quazar_de_dia
               for select to authenticated using (true)';
  end if;
  if v_srv then execute 'grant all on public.zorvin_quazar_de_dia to service_role'; end if;

  -- O SAC NASCE EM ENSAIO, uma vez só: desligado depois, rodar a pasta de
  -- novo não o religa (regra 5).
  execute 'create table if not exists public.zorvin_sementes (
             chave text primary key, plantada_em timestamptz not null default now())';
  execute 'alter table public.zorvin_sementes enable row level security';
  if v_anon then execute 'revoke all on public.zorvin_sementes from anon'; end if;
  if v_auth then execute 'revoke all on public.zorvin_sementes from authenticated'; end if;
  if not exists (select 1 from public.zorvin_sementes where chave = 'quazar:ensaio-de-dia-061') then
    insert into public.zorvin_quazar_de_dia (advogado_id, modo)
    select a.id, 'ensaio' from public.advogados a
     where upper(btrim(a.nome)) = 'SAC' and coalesce(a.ativo = false, false) = false
    on conflict (advogado_id) do update set modo = 'ensaio', atualizado_em = now();
    insert into public.zorvin_sementes (chave) values ('quazar:ensaio-de-dia-061') on conflict do nothing;
  end if;

  -- ------------------------------------------------------------
  -- 3. QUEM ESTÁ ESPERANDO O QUAZAR DE DIA
  --
  --   o telefone em ensaio; a conversa em Novos (ninguém da equipe agiu
  --   nela), sem arquivar, sem ser grupo; a última mensagem do cliente,
  --   quieta há `p_quieto_s` e com menos de 12 horas; o escritório ABERTO
  --   agora (sem semana escrita, conta como aberto); nada da equipe saindo
  --   na fila; e nenhuma resposta do ensaio de dia que já cubra a mensagem.
  -- ------------------------------------------------------------
  execute $x$
create or replace function public.zorvin_quazar_de_dia_pendentes(
  p_limite integer default 5, p_quieto_s integer default 60)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare
  v_out jsonb := '[]'::jsonb;
  r     record;
  v_h   jsonb;
begin
  for r in
    select c.id as conversa_id, c.advogado_id, a.nome as telefone, d.nome as departamento,
           f.semana, coalesce(f.fuso, 'America/Sao_Paulo') as fuso, m.id as msg_id, m.criado_em as msg_em
      from public.conversas c
      join public.zorvin_quazar_de_dia qd on qd.advogado_id = c.advogado_id and qd.modo = 'ensaio'
      join public.contatos ct on ct.id = c.contato_id
      join public.advogados a on a.id = c.advogado_id
      left join public.departamentos d on d.id = a.departamento_id
      left join public.zorvin_fora_do_horario f on f.departamento_id = a.departamento_id
      cross join lateral (
        select m.id, m.criado_em, m.origem
          from public.mensagens m
         where m.conversa_id = c.id
         order by m.criado_em desc, m.id desc
         limit 1) m
     where c.situacao = 'aguardando'
       and not coalesce((to_jsonb(c) ->> 'arquivada')::boolean, false)
       and ct.numero not like 'grupo:%'
       and coalesce(a.ativo = false, false) = false
       and m.origem = 'contato'
       and m.criado_em > now() - interval '12 hours'
       and m.criado_em <= now() - make_interval(secs => greatest(coalesce(p_quieto_s, 60), 0))
       and not exists (select 1 from public.zorvin_quazar_noturno q
                        where q.conversa_id = c.id and q.cliente_ate >= m.criado_em and q.periodo = 'dia')
       and not exists (select 1 from public.fila_envio fe
                        where fe.conversa_id = c.id and not fe.pelo_quazar
                          and fe.status in ('pendente', 'enviando')
                          and (to_jsonb(fe) ->> 'agendada_para') is null)
     order by m.criado_em
  loop
    exit when jsonb_array_length(v_out) >= greatest(coalesce(p_limite, 5), 1);
    if r.semana is not null then
      v_h := public.zorvin_horario_de(r.semana, r.fuso, now());
      continue when not coalesce((v_h ->> 'aberto')::boolean, false);
    end if;
    v_out := v_out || jsonb_build_object(
      'conversa_id', r.conversa_id,
      'advogado_id', r.advogado_id,
      'telefone', r.telefone,
      'departamento', r.departamento,
      'fuso', r.fuso,
      'cliente_ate', r.msg_em,
      'cliente_ate_id', r.msg_id);
  end loop;
  return v_out;
end
$f$
  $x$;
  execute 'revoke all on function public.zorvin_quazar_de_dia_pendentes(integer, integer) from public';
  if v_anon then execute 'revoke all on function public.zorvin_quazar_de_dia_pendentes(integer, integer) from anon'; end if;
  if v_auth then execute 'revoke all on function public.zorvin_quazar_de_dia_pendentes(integer, integer) from authenticated'; end if;
  if v_srv then execute 'grant execute on function public.zorvin_quazar_de_dia_pendentes(integer, integer) to service_role'; end if;

  -- ------------------------------------------------------------
  -- 4. A NOITE NÃO CONTA O ENSAIO DE DIA COMO RESPOSTA
  --    (a do 059, com `q.periodo = 'noite'`)
  -- ------------------------------------------------------------
  execute $x$
create or replace function public.zorvin_quazar_noturno_pendentes(
  p_limite integer default 5, p_quieto_s integer default 60)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare
  v_out      jsonb := '[]'::jsonb;
  v_carencia interval := interval '30 minutes';
  r          record;
  v_h        jsonb;
  v_fechou   timestamptz;
  v_ate      timestamptz;
  v_nossa    timestamptz;
begin
  begin
    v_carencia := coalesce(public.zorvin_carencia_da_espera(), interval '30 minutes');
  exception when undefined_function then
    v_carencia := interval '30 minutes';
  end;

  for r in
    select c.id as conversa_id, c.advogado_id, a.departamento_id, d.nome as departamento,
           f.semana, f.fuso, f.quazar, m.id as msg_id, m.criado_em as msg_em
      from public.conversas c
      join public.contatos ct on ct.id = c.contato_id
      join public.advogados a on a.id = c.advogado_id
      join public.departamentos d on d.id = a.departamento_id
      join public.zorvin_fora_do_horario f on f.departamento_id = a.departamento_id
      cross join lateral (
        select m.id, m.criado_em, m.origem
          from public.mensagens m
         where m.conversa_id = c.id
         order by m.criado_em desc, m.id desc
         limit 1) m
     where f.quazar <> 'desligado'
       -- A ARQUIVADA NÃO É CLIENTE ESPERANDO (057).
       and not coalesce((to_jsonb(c) ->> 'arquivada')::boolean, false)
       and c.ultima_atividade > now() - interval '12 hours'
       and ct.numero not like 'grupo:%'
       and coalesce(a.ativo = false, false) = false
       and m.origem = 'contato'
       and m.criado_em > now() - interval '12 hours'
       and m.criado_em <= now() - make_interval(secs => greatest(coalesce(p_quieto_s, 60), 0))
       -- SÓ O QUE O QUAZAR ESCREVEU À NOITE cobre a mensagem (061): o
       -- ensaio de dia não foi ao cliente.
       and not exists (select 1 from public.zorvin_quazar_noturno q
                        where q.conversa_id = c.id and q.cliente_ate >= m.criado_em
                          and q.periodo = 'noite')
     order by m.criado_em
  loop
    exit when jsonb_array_length(v_out) >= greatest(coalesce(p_limite, 5), 1);

    -- FECHADO AGORA, e o cliente escreveu depois do fechamento.
    v_h := public.zorvin_horario_de(r.semana, r.fuso, now());
    continue when coalesce((v_h ->> 'aberto')::boolean, false);
    v_ate := (v_h ->> 'abre_em')::timestamptz;
    continue when v_ate is null;
    v_fechou := (v_h ->> 'fechou_em')::timestamptz;
    continue when r.msg_em < coalesce(v_fechou, now() - interval '12 hours');

    -- A EQUIPE NA CONVERSA: a mensagem nossa (inclui o celular) ou o pedido
    -- na fila (a agendada que espera a hora não conta). A RESPOSTA DO PRÓPRIO
    -- QUAZAR (059) NÃO É A EQUIPE: com ela contada, o cliente que escreve de
    -- novo depois da primeira resposta dele ficaria sem resposta.
    select greatest(
             (select max(m.criado_em) from public.mensagens m
               where m.conversa_id = r.conversa_id and m.origem = 'advogado' and not m.pelo_quazar),
             (select max(fe.criado_em) from public.fila_envio fe
               where fe.conversa_id = r.conversa_id and not fe.pelo_quazar
                 and (to_jsonb(fe) ->> 'agendada_para') is null))
      into v_nossa;
    continue when v_nossa >= coalesce(v_fechou, r.msg_em - interval '12 hours');
    continue when v_nossa >= r.msg_em - v_carencia;

    v_out := v_out || jsonb_build_object(
      'conversa_id', r.conversa_id,
      'advogado_id', r.advogado_id,
      'departamento_id', r.departamento_id,
      'departamento', r.departamento,
      'modo', r.quazar,
      'fuso', r.fuso,
      'ate', v_ate,
      'fechou_em', v_fechou,
      'cliente_ate', r.msg_em,
      'cliente_ate_id', r.msg_id);
  end loop;
  return v_out;
end
$f$
  $x$;
  execute 'revoke all on function public.zorvin_quazar_noturno_pendentes(integer, integer) from public';
  if v_anon then execute 'revoke all on function public.zorvin_quazar_noturno_pendentes(integer, integer) from anon'; end if;
  if v_auth then execute 'revoke all on function public.zorvin_quazar_noturno_pendentes(integer, integer) from authenticated'; end if;
  if v_srv then execute 'grant execute on function public.zorvin_quazar_noturno_pendentes(integer, integer) to service_role'; end if;

  -- ------------------------------------------------------------
  -- 5. A CONFERÊNCIA
  -- ------------------------------------------------------------
  insert into zorvin_conferencia_061
  select 'telefones em ensaio de dia', coalesce(string_agg(a.nome, ', ' order by a.nome), '(nenhum)')
    from public.zorvin_quazar_de_dia qd join public.advogados a on a.id = qd.advogado_id
   where qd.modo = 'ensaio';
  if v_auth then
    insert into zorvin_conferencia_061 values
      ('quem entrou não chama a lista do ensaio de dia',
       (not has_function_privilege('authenticated',
         'public.zorvin_quazar_de_dia_pendentes(integer, integer)', 'execute'))::text),
      ('quem entrou lê quais telefones estão em ensaio',
       has_table_privilege('authenticated', 'public.zorvin_quazar_de_dia', 'select')::text),
      ('quem entrou não muda quais telefones estão em ensaio',
       (not has_table_privilege('authenticated', 'public.zorvin_quazar_de_dia', 'update'))::text);
  end if;
  begin
    insert into zorvin_conferencia_061
    select 'conversas esperando o Quazar de dia agora',
           jsonb_array_length(public.zorvin_quazar_de_dia_pendentes(50, 60))::text;
  exception when others then
    insert into zorvin_conferencia_061 values
      ('conversas esperando o Quazar de dia agora', 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')');
  end;
  begin
    insert into zorvin_conferencia_061
    select 'conversas esperando o Quazar à noite agora',
           jsonb_array_length(public.zorvin_quazar_noturno_pendentes(50, 60))::text;
  exception when others then
    insert into zorvin_conferencia_061 values
      ('conversas esperando o Quazar à noite agora', 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')');
  end;
end
$dia$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_061;
