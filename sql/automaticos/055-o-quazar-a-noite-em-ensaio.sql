-- ============================================================
--  O QUAZAR À NOITE, EM ENSAIO
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  A ponte aplica sozinha ao subir (sql/automaticos). Pode rodar de novo sem
--  medo — na ordem da pasta, como diz a regra 5 do LEIA-ME.
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido do Rodrigo em 06/11: o Quazar responde, à noite, quem escreve com
--  o escritório fechado, no lugar da mensagem pronta. Decidido com ele:
--
--    1. COMEÇA PELO ENSAIO: uma semana em que o cliente continua recebendo a
--       mensagem pronta, e o Quazar escreve a resposta que daria, SEM ENVIAR.
--       De manhã a equipe lê na conversa e marca se ele acertou;
--    2. sozinho, ele diz que é o assistente virtual do escritório;
--    3. ele CONVERSA: responde cada vez que o cliente escreve, e não uma vez
--       só por noite.
--
--  Este script é o do ensaio. Mandar de verdade é o próximo script, depois
--  de a equipe ler as respostas.
--
--  TRÊS PEÇAS:
--
--    zorvin_fora_do_horario.quazar   por departamento: 'desligado' ou
--                                    'ensaio'. Quem administra troca na aba
--                                    Fora do horário
--    zorvin_quazar_noturno           o que o Quazar escreveu (ou por que
--                                    ficou calado), e a avaliação da equipe
--    zorvin_quazar_noturno_pendentes quais conversas têm cliente esperando o
--                                    Quazar agora — só a ponte chama
--
--  ------------------------------------------------------------
--  QUANDO O QUAZAR ESCREVE — tudo isto é conferido aqui, e não na ponte:
--
--    - o departamento da linha está em 'ensaio';
--    - o escritório está FECHADO agora, e a última mensagem da conversa é do
--      CLIENTE, escrita depois do fechamento, há mais de 90 segundos (quem
--      manda "oi", "bom dia" e a foto recebe UMA resposta para as três) e há
--      menos de 12 horas;
--    - a equipe não está na conversa: ninguém escreveu depois do fechamento,
--      nem nos 30 minutos antes da mensagem do cliente (a régua do 022, e a
--      mesma carência da fila de espera). Quando alguém da equipe responde,
--      o Quazar sai da conversa;
--    - não é grupo, a linha não está desativada;
--    - o Quazar ainda não escreveu para esta mensagem do cliente.
--
--  A RESERVA DA VEZ é da ponte: ela grava a linha 'pensando' com a chave
--  (conversa, mensagem do cliente), e a segunda ponte, numa publicação,
--  esbarra na chave.
--
--  ------------------------------------------------------------
--  QUEM PODE O QUÊ
--
--    - ler: quem vê a conversa (a regra de acesso de `conversas` vale lá
--      dentro);
--    - avaliar: quem vê a conversa, e só `avaliacao` e `comentario`. Quem
--      avaliou e quando são do gatilho;
--    - escrever o resto: só a ponte.
--
--  NÃO VAI PARA O TEMPO REAL, de propósito (a régua do 021): uma tabela a
--  mais no canal é mexer no canal de todas as conversas. A resposta do ensaio
--  é lida de manhã, quando a conversa abre.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    as tabelas do Zorvin e a resposta fora do horário (021). Sem elas, não
--    faz nada, e diz por quê.
-- ============================================================

do $noite$
declare
  v_anon boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_srv  boolean := exists (select 1 from pg_roles where rolname = 'service_role');
  v_n    integer;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_055;
  create temp table zorvin_conferencia_055 (item text, resposta text);

  if to_regclass('public.conversas') is null or to_regclass('public.mensagens') is null
     or to_regclass('public.contatos') is null or to_regclass('public.advogados') is null
     or to_regclass('public.departamentos') is null or to_regclass('public.fila_envio') is null then
    insert into zorvin_conferencia_055 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 055 não fez nada.';
    return;
  end if;
  if to_regclass('public.zorvin_fora_do_horario') is null
     or to_regprocedure('public.zorvin_horario_de(jsonb, text, timestamp with time zone)') is null then
    insert into zorvin_conferencia_055 values
      ('NÃO — falta a resposta fora do horário (021)', 'rode o 021 antes');
    raise notice 'Zorvin: script 055 precisa do 021.';
    return;
  end if;

  -- ------------------------------------------------------------
  -- 1. O MODO DE CADA DEPARTAMENTO
  -- ------------------------------------------------------------
  -- Só 'desligado' e 'ensaio' por enquanto: um valor que não faz nada não
  -- entra. O próximo script acrescenta o que manda de verdade.
  if not exists (select 1 from information_schema.columns where table_schema = 'public'
                  and table_name = 'zorvin_fora_do_horario' and column_name = 'quazar') then
    execute $x$
      alter table public.zorvin_fora_do_horario
        add column quazar text not null default 'desligado'
          constraint zorvin_fora_do_horario_quazar_check check (quazar in ('desligado', 'ensaio'))
    $x$;
  end if;

  -- ------------------------------------------------------------
  -- 2. O QUE O QUAZAR ESCREVEU
  -- ------------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_quazar_noturno (
      id              uuid primary key default gen_random_uuid(),
      conversa_id     uuid not null references public.conversas(id) on delete cascade,
      modo            text not null default 'ensaio' check (modo in ('ensaio')),
      -- a noite: quando o escritório abre de novo (o `abre_em` do 021)
      ate             timestamptz not null,
      -- a última mensagem do cliente que esta resposta cobre
      cliente_ate     timestamptz not null,
      cliente_ate_id  uuid not null,
      status          text not null default 'pensando'
                        check (status in ('pensando', 'pronta', 'calada', 'falhou')),
      texto           text check (length(texto) <= 4000),
      resumo          text check (length(resumo) <= 1000),
      motivo          text check (length(motivo) <= 500),
      erro            text check (length(erro) <= 500),
      modelo          text,
      criada_em       timestamptz not null default now(),
      pronta_em       timestamptz,
      avaliacao       text check (avaliacao in ('boa', 'ruim')),
      comentario      text check (length(comentario) <= 500),
      avaliada_por    uuid,
      avaliada_em     timestamptz,
      unique (conversa_id, cliente_ate_id)
    )
  $x$;
  execute $x$
    comment on table public.zorvin_quazar_noturno is
      'O que o Quazar escreveu à noite (no ensaio, sem enviar), e a avaliação da '
      'equipe. Quem vê a conversa lê e avalia; só a ponte escreve o resto.'
  $x$;
  execute 'create index if not exists zorvin_quazar_noturno_conversa
             on public.zorvin_quazar_noturno (conversa_id, cliente_ate desc)';
  execute 'create index if not exists zorvin_quazar_noturno_recentes
             on public.zorvin_quazar_noturno (criada_em desc)';

  -- QUEM AVALIOU E QUANDO são do gatilho, e não da tela. As colunas que a
  -- tela pode mudar são só as duas da avaliação (o `grant` por coluna, logo
  -- abaixo): o gatilho escreve as outras duas, e gatilho não passa pela
  -- conferência de coluna.
  execute $x$
    create or replace function public.zorvin_quazar_noturno_avaliado()
    returns trigger language plpgsql set search_path = public as $f$
    begin
      if new.avaliacao is distinct from old.avaliacao or new.comentario is distinct from old.comentario then
        new.comentario := nullif(btrim(coalesce(new.comentario, '')), '');
        if new.avaliacao is null then
          new.avaliada_por := null;
          new.avaliada_em := null;
        else
          new.avaliada_por := auth.uid();
          new.avaliada_em := now();
        end if;
      end if;
      return new;
    end
    $f$
  $x$;
  execute 'drop trigger if exists zorvin_quazar_noturno_avaliado on public.zorvin_quazar_noturno';
  execute 'create trigger zorvin_quazar_noturno_avaliado before update on public.zorvin_quazar_noturno
             for each row execute function public.zorvin_quazar_noturno_avaliado()';

  -- A HERANÇA DA SUPABASE dá tudo a quem entrou e a quem não entrou (a
  -- armadilha nº 5): sai tudo, e volta só o que serve.
  execute 'alter table public.zorvin_quazar_noturno enable row level security';
  if v_anon then execute 'revoke all on public.zorvin_quazar_noturno from anon'; end if;
  if v_auth then
    execute 'revoke all on public.zorvin_quazar_noturno from authenticated';
    execute 'grant select on public.zorvin_quazar_noturno to authenticated';
    execute 'grant update (avaliacao, comentario) on public.zorvin_quazar_noturno to authenticated';
    execute 'drop policy if exists zorvin_quazar_noturno_leitura on public.zorvin_quazar_noturno';
    execute 'create policy zorvin_quazar_noturno_leitura on public.zorvin_quazar_noturno
               for select to authenticated
               using (exists (select 1 from public.conversas c where c.id = conversa_id))';
    execute 'drop policy if exists zorvin_quazar_noturno_avaliar on public.zorvin_quazar_noturno';
    execute 'create policy zorvin_quazar_noturno_avaliar on public.zorvin_quazar_noturno
               for update to authenticated
               using (status in (''pronta'', ''calada'')
                      and exists (select 1 from public.conversas c where c.id = conversa_id))
               with check (exists (select 1 from public.conversas c where c.id = conversa_id))';
  end if;
  if v_srv then execute 'grant all on public.zorvin_quazar_noturno to service_role'; end if;
  execute 'revoke all on function public.zorvin_quazar_noturno_avaliado() from public';
  if v_anon then execute 'revoke all on function public.zorvin_quazar_noturno_avaliado() from anon'; end if;
  if v_auth then execute 'revoke all on function public.zorvin_quazar_noturno_avaliado() from authenticated'; end if;

  -- ------------------------------------------------------------
  -- 3. QUEM ESTÁ ESPERANDO O QUAZAR AGORA
  -- ------------------------------------------------------------
  -- `a.ativo` PELO NOME, e nunca `to_jsonb(a)`: `advogados` guarda a chave da
  -- Uazapi em colunas fechadas (a régua do 012). SÓ O `false` EXPLÍCITO
  -- desativa — a régua da fila de envio.
  execute $x$
    create or replace function public.zorvin_quazar_noturno_pendentes(
      p_limite integer default 5, p_quieto_s integer default 90)
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
           and c.ultima_atividade > now() - interval '12 hours'
           and ct.numero not like 'grupo:%'
           and coalesce(a.ativo = false, false) = false
           and m.origem = 'contato'
           and m.criado_em > now() - interval '12 hours'
           and m.criado_em <= now() - make_interval(secs => greatest(coalesce(p_quieto_s, 90), 0))
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

        -- A EQUIPE NA CONVERSA: a mensagem nossa (inclui o celular) ou o
        -- pedido na fila (a agendada que espera a hora não conta).
        select greatest(
                 (select max(m.criado_em) from public.mensagens m
                   where m.conversa_id = r.conversa_id and m.origem = 'advogado'),
                 (select max(fe.criado_em) from public.fila_envio fe
                   where fe.conversa_id = r.conversa_id
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
  -- 4. O ENSAIO COMEÇA ONDE A MENSAGEM PRONTA JÁ SAI — uma vez só
  -- ------------------------------------------------------------
  -- Decidido com o Rodrigo: começar pelo ensaio. Ele entra nos departamentos
  -- com a resposta fora do horário ligada, na rodada que planta a semente
  -- (o 027). Desligado depois pela tela, rodar a pasta de novo não religa.
  execute 'create table if not exists public.zorvin_sementes (
             chave text primary key, plantada_em timestamptz not null default now())';
  execute 'alter table public.zorvin_sementes enable row level security';
  if v_anon then execute 'revoke all on public.zorvin_sementes from anon'; end if;
  if v_auth then execute 'revoke all on public.zorvin_sementes from authenticated'; end if;
  if not exists (select 1 from public.zorvin_sementes where chave = 'quazar:ensaio-da-noite-055') then
    update public.zorvin_fora_do_horario set quazar = 'ensaio' where ligada and quazar = 'desligado';
    get diagnostics v_n = row_count;
    insert into public.zorvin_sementes (chave) values ('quazar:ensaio-da-noite-055') on conflict do nothing;
    insert into zorvin_conferencia_055 values ('departamentos que entraram no ensaio nesta rodada', v_n::text);
  end if;

  -- ------------------------------------------------------------
  -- 5. A CONFERÊNCIA
  -- ------------------------------------------------------------
  insert into zorvin_conferencia_055
  select 'departamentos em ensaio', coalesce(string_agg(d.nome, ', ' order by d.nome), '(nenhum)')
    from public.zorvin_fora_do_horario f join public.departamentos d on d.id = f.departamento_id
   where f.quazar = 'ensaio';
  if v_auth then
    insert into zorvin_conferencia_055 values
      ('quem entrou lê as respostas do Quazar',
       has_table_privilege('authenticated', 'public.zorvin_quazar_noturno', 'select')::text),
      ('quem entrou avalia (só avaliacao e comentario)',
       (has_column_privilege('authenticated', 'public.zorvin_quazar_noturno', 'avaliacao', 'update')
        and has_column_privilege('authenticated', 'public.zorvin_quazar_noturno', 'comentario', 'update')
        and not has_column_privilege('authenticated', 'public.zorvin_quazar_noturno', 'texto', 'update')
        and not has_table_privilege('authenticated', 'public.zorvin_quazar_noturno', 'insert')
        and not has_table_privilege('authenticated', 'public.zorvin_quazar_noturno', 'delete'))::text),
      ('quem entrou NÃO chama a lista de pendentes',
       (not has_function_privilege('authenticated',
         'public.zorvin_quazar_noturno_pendentes(integer, integer)', 'execute'))::text);
  end if;
  if v_anon then
    insert into zorvin_conferencia_055 values
      ('quem não entrou não alcança nada',
       (not has_table_privilege('anon', 'public.zorvin_quazar_noturno', 'select')
        and not has_function_privilege('anon',
          'public.zorvin_quazar_noturno_pendentes(integer, integer)', 'execute'))::text);
  end if;
  begin
    execute 'select jsonb_array_length(public.zorvin_quazar_noturno_pendentes(50, 90))' into v_n;
    insert into zorvin_conferencia_055 values ('conversas esperando o Quazar agora', v_n::text);
  exception when others then
    insert into zorvin_conferencia_055 values
      ('conversas esperando o Quazar agora', 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')');
  end;
end
$noite$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_055;
