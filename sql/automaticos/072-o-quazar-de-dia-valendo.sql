-- ============================================================
--  072 — O QUAZAR DE DIA, VALENDO: ele responde os contatos novos (25/11)
--
--  Pedido do Rodrigo: "E já pode ativar as respostas do Quazar para novos
--  contatos." Até aqui o Quazar de dia (061) só escrevia em ensaio: a
--  resposta ficava guardada, e nada ia ao cliente. Agora, nos telefones
--  "valendo", a resposta vai ao cliente pela fila (a ponte), como a do Quazar
--  à noite (059).
--
--    zorvin_quazar_de_dia.modo         ganha 'valendo'
--    zorvin_quazar_de_dia_pendentes    diz o modo de cada conversa, e não
--                                       oferece a linha caída (070) quando
--                                       vale: a mensagem não sairia
--
--  QUEM ESTÁ ESPERANDO não muda: o telefone em ensaio ou valendo, a conversa
--  em "Novos" (ninguém da equipe respondeu), a última mensagem do cliente,
--  quieto há 1 minuto, o escritório aberto e nada da equipe saindo na fila.
--  Quando alguém da equipe responde, a conversa vai para "Em Atendimento" e
--  o Quazar sai dela.
--
--  LIGA, UMA VEZ SÓ, os telefones do Sucesso do Cliente e do Comercial (o
--  pedido, e os departamentos em que o Quazar já responde quem espera, o 069).
--  Desligado depois, rodar a pasta de novo não religa (regra 5).
--
--  A VERSÃO DE REFERÊNCIA de `zorvin_quazar_de_dia_pendentes` passa a ser a
--  deste script (regra 5 do LEIA-ME).
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    061 e 070. Sem eles, não faz nada, e diz por quê.
-- ============================================================

do $valendo$
declare
  v_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_anon boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_srv  boolean := exists (select 1 from pg_roles where rolname = 'service_role');
  v_c    record;
  f      text := 'public.zorvin_quazar_de_dia_pendentes(integer, integer)';
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_072;
  create temp table zorvin_conferencia_072 (item text, resposta text);

  if to_regclass('public.conversas') is null or to_regclass('public.mensagens') is null
     or to_regclass('public.advogados') is null then
    insert into zorvin_conferencia_072 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 072 não fez nada.';
    return;
  end if;
  if to_regclass('public.zorvin_quazar_de_dia') is null or to_regclass('public.departamentos') is null
     or to_regprocedure(f) is null
     or to_regprocedure('public.zorvin_linha_caida_desde(uuid)') is null then
    insert into zorvin_conferencia_072 values ('NÃO — falta o 061 ou o 070', 'rode-os antes');
    raise notice 'Zorvin: script 072 precisa do 061 e do 070.';
    return;
  end if;

  -- ------------------------------------------------------------
  -- 1. O MODO 'valendo'. A regra do 061 nasceu sem nome: sai toda regra da
  --    tabela que fala do modo, e entra uma com nome.
  -- ------------------------------------------------------------
  for v_c in
    select conname from pg_constraint
     where conrelid = 'public.zorvin_quazar_de_dia'::regclass and contype = 'c'
       and pg_get_constraintdef(oid) ilike '%modo%'
  loop
    execute format('alter table public.zorvin_quazar_de_dia drop constraint %I', v_c.conname);
  end loop;
  execute $x$alter table public.zorvin_quazar_de_dia add constraint zorvin_quazar_de_dia_modo_valido
             check (modo in ('desligado', 'ensaio', 'valendo'))$x$;

  -- ------------------------------------------------------------
  -- 2. QUEM ESTÁ ESPERANDO — a do 061, com o modo e a linha caída.
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
    select c.id as conversa_id, c.advogado_id, a.nome as telefone, d.nome as departamento, qd.modo,
           f.semana, coalesce(f.fuso, 'America/Sao_Paulo') as fuso, m.id as msg_id, m.criado_em as msg_em
      from public.conversas c
      join public.zorvin_quazar_de_dia qd on qd.advogado_id = c.advogado_id and qd.modo in ('ensaio', 'valendo')
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
       -- VALENDO, a linha caída (070) fica de fora: a mensagem não sairia, e
       -- a IA seria paga à toa. Ela volta quando a linha der sinal de vida.
       and (qd.modo <> 'valendo' or public.zorvin_linha_caida_desde(c.advogado_id) is null)
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
      'modo', r.modo,
      'fuso', r.fuso,
      'cliente_ate', r.msg_em,
      'cliente_ate_id', r.msg_id);
  end loop;
  return v_out;
end
$f$
  $x$;
  -- SÓ A PONTE CHAMA (create or replace guarda as permissões; ditas de novo
  -- pela armadilha nº 5).
  execute format('revoke all on function %s from public', f);
  if v_anon then execute format('revoke all on function %s from anon', f); end if;
  if v_auth then execute format('revoke all on function %s from authenticated', f); end if;
  if v_srv then execute format('grant execute on function %s to service_role', f); end if;

  -- ------------------------------------------------------------
  -- 3. LIGA o Sucesso do Cliente e o Comercial, uma vez só. Pelo `slug`
  --    (sdc, comercial) ou pelo nome sem acento, como o 065 e o 069.
  -- ------------------------------------------------------------
  execute 'create table if not exists public.zorvin_sementes (
             chave text primary key, plantada_em timestamptz not null default now())';
  execute 'alter table public.zorvin_sementes enable row level security';
  if v_anon then execute 'revoke all on public.zorvin_sementes from anon'; end if;
  if v_auth then execute 'revoke all on public.zorvin_sementes from authenticated'; end if;
  if not exists (select 1 from public.zorvin_sementes where chave = 'quazar:dia-valendo-sdc-comercial-072') then
    -- O NOME SEM ACENTO é o do 025: sem ele, só pelo `slug` (a chamada vai
    -- num `execute`, para o script não depender do 025 para ser lido).
    execute format($x$
      insert into public.zorvin_quazar_de_dia (advogado_id, modo)
      select a.id, 'valendo'
        from public.advogados a
        join public.departamentos d on d.id = a.departamento_id
       where coalesce(a.ativo = false, false) = false
         and (coalesce(to_jsonb(d) ->> 'slug', '') in ('sdc', 'comercial') %s)
      on conflict (advogado_id) do update set modo = 'valendo', atualizado_em = now()$x$,
      case when to_regprocedure('public.zorvin_chave_do_assunto(text)') is not null
           then $y$or public.zorvin_chave_do_assunto(d.nome) in ('sucesso do cliente', 'comercial')$y$ else '' end);
    insert into public.zorvin_sementes (chave) values ('quazar:dia-valendo-sdc-comercial-072') on conflict do nothing;
  end if;

  -- ------------------------------------------------------------
  -- A CONFERÊNCIA
  -- ------------------------------------------------------------
  insert into zorvin_conferencia_072
  select 'o modo aceita valendo',
         exists (select 1 from pg_constraint where conname = 'zorvin_quazar_de_dia_modo_valido'
                  and pg_get_constraintdef(oid) ~ 'valendo')::text;
  insert into zorvin_conferencia_072
  select 'quem espera diz o modo, e pula a linha caída',
         (pg_get_functiondef(f::regprocedure) ~ '''modo''' and pg_get_functiondef(f::regprocedure) ~ 'zorvin_linha_caida_desde')::text;
  insert into zorvin_conferencia_072
  select 'telefones em que o Quazar responde de dia (valendo)',
         coalesce(string_agg(a.nome, ', ' order by a.nome), 'nenhum')
    from public.zorvin_quazar_de_dia qd join public.advogados a on a.id = qd.advogado_id
   where qd.modo = 'valendo';
  insert into zorvin_conferencia_072
  select 'telefones em ensaio de dia',
         coalesce(string_agg(a.nome, ', ' order by a.nome), 'nenhum')
    from public.zorvin_quazar_de_dia qd join public.advogados a on a.id = qd.advogado_id
   where qd.modo = 'ensaio';
  if v_auth then
    insert into zorvin_conferencia_072 values
      ('quem entrou não alcança a função', (not has_function_privilege('authenticated', f, 'execute'))::text);
  end if;
  if v_anon then
    insert into zorvin_conferencia_072 values
      ('quem não entrou não alcança', (not has_function_privilege('anon', f, 'execute'))::text);
  end if;
end
$valendo$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_072;
