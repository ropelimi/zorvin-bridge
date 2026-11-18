-- ============================================================
--  O QUAZAR À NOITE, VALENDO
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  A ponte aplica sozinha ao subir (sql/automaticos). Pode rodar de novo sem
--  medo — na ordem da pasta, como diz a regra 5 do LEIA-ME.
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido do Rodrigo em 18/11, depois de ler as respostas do ensaio (055):
--  "quero já começar a usar", com o Quazar esperando 1 minuto antes de
--  responder e se apresentando pelo nome ("Sou o Quazar, assistente virtual
--  do escritório ...").
--
--    zorvin_fora_do_horario.quazar     ganha 'valendo': a resposta do Quazar
--                                      vai ao cliente, e a mensagem pronta
--                                      (021) não sai ali
--    fila_envio.pelo_quazar,           a resposta sai pela fila de envio, e a
--    mensagens.pelo_quazar             linha que entra na conversa é marcada
--                                      (e também `automatica`, do 037: ela não
--                                      tira o cliente da fila de espera nem
--                                      da aba Novos — ele continua esperando
--                                      uma pessoa)
--    zorvin_quazar_noturno             o modo 'valendo', o status 'enviada' e
--                                      o item da fila (`fila_id`); a resposta
--                                      enviada também se avalia
--    zorvin_copiloto.nome_do_escritorio  o nome com que o Quazar se apresenta
--    zorvin_quazar_noturno_pendentes   a do 057, com a resposta do Quazar fora
--                                      de "a equipe na conversa": sem isso,
--                                      depois da primeira resposta dele, o
--                                      cliente que escrevesse de novo não
--                                      seria respondido. E a espera padrão
--                                      passa a 1 minuto
--
--  NENHUM DEPARTAMENTO PASSA A 'valendo' AQUI: quem liga é a aba Fora do
--  horário (ou o conector, a pedido do Rodrigo), depois de este script rodar.
--
--  A VERSÃO DE REFERÊNCIA de `zorvin_quazar_noturno_pendentes` passa a ser a
--  deste script (regra 5 do LEIA-ME).
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    021 e 055. Sem eles, não faz nada, e diz por quê.
-- ============================================================

do $valendo$
declare
  v_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_c    record;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_059;
  create temp table zorvin_conferencia_059 (item text, resposta text);

  if to_regclass('public.conversas') is null or to_regclass('public.mensagens') is null
     or to_regclass('public.fila_envio') is null then
    insert into zorvin_conferencia_059 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 059 não fez nada.';
    return;
  end if;
  if to_regclass('public.zorvin_quazar_noturno') is null
     or to_regclass('public.zorvin_fora_do_horario') is null
     or not exists (select 1 from information_schema.columns where table_schema = 'public'
                     and table_name = 'zorvin_fora_do_horario' and column_name = 'quazar') then
    insert into zorvin_conferencia_059 values ('NÃO — falta o Quazar à noite (055)', 'rode o 055 antes');
    raise notice 'Zorvin: script 059 precisa do 055.';
    return;
  end if;

  -- ------------------------------------------------------------
  -- 1. A MARCA DO QUE O QUAZAR MANDA
  -- ------------------------------------------------------------
  execute 'alter table public.fila_envio add column if not exists pelo_quazar boolean not null default false';
  execute 'alter table public.mensagens add column if not exists pelo_quazar boolean not null default false';

  -- ------------------------------------------------------------
  -- 2. O MODO 'valendo'
  -- ------------------------------------------------------------
  -- As regras de lista fechada são trocadas pelo NOME que o Postgres deu a
  -- elas (o 055 as criou dentro do `create table`, sem nome escrito).
  for v_c in
    select conname from pg_constraint
     where conrelid = 'public.zorvin_fora_do_horario'::regclass and contype = 'c'
       and pg_get_constraintdef(oid) ilike '%quazar%'
  loop
    execute format('alter table public.zorvin_fora_do_horario drop constraint %I', v_c.conname);
  end loop;
  execute $x$alter table public.zorvin_fora_do_horario add constraint zorvin_fora_do_horario_quazar_check
             check (quazar in ('desligado', 'ensaio', 'valendo'))$x$;

  for v_c in
    select conname from pg_constraint
     where conrelid = 'public.zorvin_quazar_noturno'::regclass and contype = 'c'
       and (pg_get_constraintdef(oid) ilike '%modo%' or pg_get_constraintdef(oid) ilike '%status%')
  loop
    execute format('alter table public.zorvin_quazar_noturno drop constraint %I', v_c.conname);
  end loop;
  execute $x$alter table public.zorvin_quazar_noturno add constraint zorvin_quazar_noturno_modo_check
             check (modo in ('ensaio', 'valendo'))$x$;
  execute $x$alter table public.zorvin_quazar_noturno add constraint zorvin_quazar_noturno_status_check
             check (status in ('pensando', 'pronta', 'calada', 'falhou', 'enviada'))$x$;
  execute 'alter table public.zorvin_quazar_noturno
             add column if not exists fila_id text';

  -- A RESPOSTA ENVIADA TAMBÉM SE AVALIA: é a que mais importa ler.
  if v_auth then
    execute 'drop policy if exists zorvin_quazar_noturno_avaliar on public.zorvin_quazar_noturno';
    execute 'create policy zorvin_quazar_noturno_avaliar on public.zorvin_quazar_noturno
               for update to authenticated
               using (status in (''pronta'', ''calada'', ''enviada'')
                      and exists (select 1 from public.conversas c where c.id = conversa_id))
               with check (exists (select 1 from public.conversas c where c.id = conversa_id))';
  end if;

  -- ------------------------------------------------------------
  -- 3. O NOME DO ESCRITÓRIO
  -- ------------------------------------------------------------
  if to_regclass('public.zorvin_copiloto') is not null then
    execute 'alter table public.zorvin_copiloto add column if not exists nome_do_escritorio text';
    if not exists (select 1 from pg_constraint where conname = 'zorvin_copiloto_nome_do_escritorio_check') then
      execute $x$alter table public.zorvin_copiloto add constraint zorvin_copiloto_nome_do_escritorio_check
                 check (nome_do_escritorio is null or length(nome_do_escritorio) <= 120)$x$;
    end if;
  end if;

  -- ------------------------------------------------------------
  -- 4. QUEM ESTÁ ESPERANDO O QUAZAR AGORA (a do 057, com a resposta dele
  --    fora de "a equipe na conversa")
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
       and not exists (select 1 from public.zorvin_quazar_noturno q
                        where q.conversa_id = c.id and q.cliente_ate >= m.criado_em)
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
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.zorvin_quazar_noturno_pendentes(integer, integer) from anon';
  end if;
  if v_auth then
    execute 'revoke all on function public.zorvin_quazar_noturno_pendentes(integer, integer) from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.zorvin_quazar_noturno_pendentes(integer, integer) to service_role';
  end if;

  -- ------------------------------------------------------------
  -- 5. A CONFERÊNCIA
  -- ------------------------------------------------------------
  insert into zorvin_conferencia_059
  select 'departamentos em ensaio', coalesce(string_agg(d.nome, ', ' order by d.nome) filter (where f.quazar = 'ensaio'), '(nenhum)')
    from public.zorvin_fora_do_horario f join public.departamentos d on d.id = f.departamento_id;
  insert into zorvin_conferencia_059
  select 'departamentos valendo', coalesce(string_agg(d.nome, ', ' order by d.nome) filter (where f.quazar = 'valendo'), '(nenhum)')
    from public.zorvin_fora_do_horario f join public.departamentos d on d.id = f.departamento_id;
  insert into zorvin_conferencia_059 values
    ('a fila e as mensagens têm a marca do Quazar',
     (exists (select 1 from information_schema.columns where table_schema = 'public'
               and table_name = 'fila_envio' and column_name = 'pelo_quazar')
      and exists (select 1 from information_schema.columns where table_schema = 'public'
               and table_name = 'mensagens' and column_name = 'pelo_quazar'))::text);
  if v_auth then
    insert into zorvin_conferencia_059 values
      ('quem entrou continua sem chamar a lista de pendentes',
       (not has_function_privilege('authenticated',
         'public.zorvin_quazar_noturno_pendentes(integer, integer)', 'execute'))::text);
  end if;
  begin
    insert into zorvin_conferencia_059
    select 'conversas esperando o Quazar agora',
           jsonb_array_length(public.zorvin_quazar_noturno_pendentes(50, 60))::text;
  exception when others then
    insert into zorvin_conferencia_059 values
      ('conversas esperando o Quazar agora', 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')');
  end;
end
$valendo$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_059;
