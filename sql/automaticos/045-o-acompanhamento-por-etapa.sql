-- ============================================================
--  045. O ACOMPANHAMENTO POR ETAPA (02/11)
--
--  >>> A PONTE APLICA SOZINHA (sql/automaticos). <<<
--  Pode rodar de novo sem medo — a pasta inteira, na ordem (regra 5).
--
--  ------------------------------------------------------------
--  O PEDIDO
--
--  Rodrigo, em 02/11: "acompanhamento por etapa do funil". Decidido com ele:
--  LEMBRAR A EQUIPE. Quando um cliente fica parado numa etapa sem responder
--  (por exemplo, 3 dias em "Aguardando cliente"), quem cuida dele recebe uma
--  tarefa com a mensagem de cobrança já escrita. A pessoa abre, confere e
--  manda. NADA SAI PARA O CLIENTE SEM UMA PESSOA.
--
--    zorvin_acompanhamentos         as regras: em qual etapa, depois de quantos
--                                   dias, e o texto pronto. Mais de uma por
--                                   etapa é a cadência (2 dias, 5 dias…)
--    zorvin_acompanhamentos_feitos  o que já foi lembrado: uma vez por regra,
--                                   por cliente, por silêncio
--    zorvin_tarefas.mensagem        a mensagem pronta da tarefa
--    zorvin_acompanhar_funil()      quem a ponte chama de 10 em 10 minutos
--
--  ------------------------------------------------------------
--  QUANDO O CLIENTE ESTÁ "PARADO SEM RESPONDER"
--
--  O relógio de cada regra começa no que vier por último:
--    - a entrada do cartão na etapa (`movido_em`);
--    - a última mensagem do cliente;
--    - a PRIMEIRA ação da equipe depois dela — a resposta, ou o "Já tratei" /
--      Finalizar (`tratada_em`): é aí que a vez passa a ser do cliente.
--
--  AS COBRANÇAS DA EQUIPE NÃO ZERAM O RELÓGIO, e é isso que faz a cadência
--  andar: a proposta sai no dia 0, o lembrete de 2 dias chega, a equipe
--  cobra, e o de 5 dias chega no dia 5 — contado do dia 0. Se cada cobrança
--  recomeçasse a conta, o lembrete de 2 dias voltaria a cada 2 dias para
--  sempre, e o de 5 nunca chegaria. O que recomeça é o cliente escrever (e a
--  equipe responder) ou o cartão mudar de etapa.
--
--  O CLIENTE QUE ESCREVEU POR ÚLTIMO TAMBÉM CONTA. O "ok, mando amanhã" é
--  justamente o caso de "Aguardando cliente", e a fila não separa esse "ok"
--  de uma pergunta sem resposta (é para isso que existe o "Já tratei"). O
--  lembrete leva a pessoa à conversa, e ela vê ali o que o cliente escreveu
--  — o painel avisa quando foi ele quem escreveu por último.
--
--  A mensagem automática (o aviso de audiência, 037) não conta: ninguém
--  escreveu.
--
--  ------------------------------------------------------------
--  A ENXURRADA QUE ISTO NÃO FAZ
--
--  Em 02/11, 984 dos 1.081 cartões do Sucesso do Cliente estavam parados há
--  semanas em "Novo contato". Uma regra de 3 dias ali, contada só pelo
--  silêncio, criaria centenas de tarefas no minuto seguinte — e, contada
--  "a partir da regra", centenas três dias depois.
--
--  A REGRA VALE PARA O QUE VENCE DEPOIS DE ELA EXISTIR (`vale_desde`): o
--  cliente quieto há 2 dias quando a regra de 3 dias nasce recebe o lembrete
--  amanhã; o quieto há 40 dias, não, porque o momento dele passou antes de a
--  regra existir. Mudar os DIAS de uma regra recomeça a conta dela, pela
--  mesma razão. Mudar só o texto, não.
--
--  E AINDA HÁ UM TETO: 20 lembretes de acompanhamento por dia para cada
--  pessoa (e 20 para os sem dono). O que passar disso espera o dia seguinte.
--
--  ------------------------------------------------------------
--  QUEM RECEBE: o responsável pela conversa; sem ele, quem da equipe escreveu
--  por último nela. Desativado, ou sem ver o telefone da conversa (a régua do
--  023, quando ela existe), a tarefa nasce SEM DONO — e aparece em "Da
--  equipe" para quem atende o telefone. Uma tarefa para quem não a vê seria
--  um lembrete que ninguém recebe.
--
--  QUAL CONVERSA: no funil de um telefone, a do cliente com ele; no do
--  departamento, a mais recente do cliente com um telefone do departamento
--  sem funil próprio. Arquivada, grupo e linha desativada não recebem.
--
--  QUANDO NASCE: só no EXPEDIENTE do departamento — a semana da resposta fora
--  do horário (021), que já sabe dos feriados. Sem a semana escrita, a
--  qualquer hora. A conta do silêncio é em dias corridos, como a da fila.
--
--  NÃO NASCE QUANDO:
--    - há uma mensagem AGENDADA esperando a hora na conversa: a equipe já
--      planejou o próximo contato;
--    - já há um lembrete de acompanhamento aberto na conversa: o seguinte é
--      dado por feito — quem não fez o primeiro não precisa de dois;
--    - duas regras vencem juntas para o mesmo cliente (a de 2 e a de 5 dias):
--      só a maior vira tarefa.
--
--  E SE FECHA SOZINHO quando a conversa anda: o cliente escreveu, a equipe
--  respondeu, alguém deu "Já tratei" ou o cartão mudou de etapa. O silêncio
--  que gerou o lembrete acabou, e um número de tarefas que nunca zera se
--  aprende a não ler. A tarefa fecha sem `feita_por` (quem fechou foi o
--  Zorvin), e continua no histórico.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO: o 017, o 018 e o 043. Sem eles, não faz nada e
--  diz. As colunas da conversa que vieram de outros scripts (o "Já tratei"
--  do 005, o responsável do 008) e a `arquivada` (feita à mão) são lidas por
--  `to_jsonb`: faltando alguma, ela vale como vazia. A `automatica` das
--  mensagens (037) e a `agendada_para` da fila (013) são lidas pelo nome:
--  os dois scripts vêm antes deste na pasta.
-- ============================================================

do $acomp$
declare
  r       record;
  v_assin text;
  v_anon  boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_auth  boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_srv   boolean := exists (select 1 from pg_roles where rolname = 'service_role');
begin
  -- A CONFERÊNCIA NASCE ANTES DA GUARDA: criada depois, o `select` da última
  -- linha estouraria num banco limpo (a lição do 006).
  drop table if exists zorvin_conferencia_045;
  create temp table zorvin_conferencia_045 (item text, resposta text);

  if to_regclass('public.zorvin_funis') is null
     or to_regclass('public.zorvin_etapas') is null
     or to_regclass('public.zorvin_cartoes') is null
     or to_regclass('public.zorvin_tarefas') is null
     or to_regclass('public.conversas') is null
     or to_regclass('public.contatos') is null
     or to_regclass('public.advogados') is null
     or to_regclass('public.mensagens') is null
     or to_regclass('public.fila_envio') is null
     or to_regclass('public.usuarios') is null
     or to_regprocedure('public.zorvin_admin()') is null then
    insert into zorvin_conferencia_045
      values ('sem o funil (017 e 043) ou as tarefas (018)', 'nada a fazer aqui');
    raise notice 'Zorvin: sem o funil ou as tarefas — script 045 não fez nada.';
    return;
  end if;

  -- ----------------------------------------------------------
  --  1. AS REGRAS
  -- ----------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_acompanhamentos (
      id          uuid primary key default gen_random_uuid(),
      etapa_id    uuid not null references public.zorvin_etapas(id) on delete cascade,
      dias        integer not null check (dias between 1 and 60),
      texto       text not null check (length(btrim(texto)) between 1 and 1000),
      criado_em   timestamptz not null default now(),
      criado_por  uuid,
      vale_desde  timestamptz not null default now(),
      mudado_em   timestamptz,
      mudado_por  uuid
    )
  $x$;
  execute $x$
    comment on table public.zorvin_acompanhamentos is
      'O acompanhamento por etapa (045): depois de quantos dias sem resposta do '
      'cliente numa etapa a equipe é lembrada, e com qual mensagem pronta. Quem '
      'administra escreve; quem entrou lê; a ponte cria os lembretes.'
  $x$;
  execute 'create unique index if not exists zorvin_acompanhamentos_um_por_dia
             on public.zorvin_acompanhamentos (etapa_id, dias)';
  execute 'alter table public.zorvin_acompanhamentos enable row level security';
  execute 'drop policy if exists zorvin_acompanhamentos_leitura on public.zorvin_acompanhamentos';
  execute 'create policy zorvin_acompanhamentos_leitura on public.zorvin_acompanhamentos
             for select to authenticated using (true)';
  execute 'drop policy if exists zorvin_acompanhamentos_criar on public.zorvin_acompanhamentos';
  execute 'create policy zorvin_acompanhamentos_criar on public.zorvin_acompanhamentos
             for insert to authenticated with check (public.zorvin_admin())';
  execute 'drop policy if exists zorvin_acompanhamentos_mudar on public.zorvin_acompanhamentos';
  execute 'create policy zorvin_acompanhamentos_mudar on public.zorvin_acompanhamentos
             for update to authenticated using (public.zorvin_admin()) with check (public.zorvin_admin())';
  execute 'drop policy if exists zorvin_acompanhamentos_apagar on public.zorvin_acompanhamentos';
  execute 'create policy zorvin_acompanhamentos_apagar on public.zorvin_acompanhamentos
             for delete to authenticated using (public.zorvin_admin())';
  -- A HERANÇA SAI INTEIRA ANTES DE DAR SÓ O QUE A TELA USA: o `truncate` não
  -- passa pela regra de acesso (a lição do 041).
  if v_anon then execute 'revoke all on public.zorvin_acompanhamentos from anon'; end if;
  if v_auth then
    execute 'revoke all on public.zorvin_acompanhamentos from authenticated';
    execute 'grant select, insert, update, delete on public.zorvin_acompanhamentos to authenticated';
  end if;
  if v_srv then execute 'grant all on public.zorvin_acompanhamentos to service_role'; end if;

  -- QUEM CRIOU, QUEM MUDOU E DESDE QUANDO A REGRA VALE SÃO DO GATILHO, e não
  -- da tela. Mudar os DIAS recomeça a conta: a regra de 30 dias que vira de 3
  -- não pode lembrar de uma vez todo cliente quieto há mais de 3.
  execute $x$
    create or replace function public.zorvin_acompanhamento_quem()
    returns trigger language plpgsql set search_path = public as $f$
    begin
      if tg_op = 'INSERT' then
        new.criado_por := coalesce(auth.uid(), new.criado_por);
        new.criado_em := now();
        new.vale_desde := now();
        new.mudado_em := null;
        new.mudado_por := null;
      else
        new.criado_por := old.criado_por;
        new.criado_em := old.criado_em;
        new.vale_desde := case when new.dias is distinct from old.dias then now() else old.vale_desde end;
        new.mudado_em := now();
        new.mudado_por := coalesce(auth.uid(), new.mudado_por);
      end if;
      return new;
    end
    $f$
  $x$;
  execute 'drop trigger if exists zorvin_acompanhamento_quem on public.zorvin_acompanhamentos';
  execute 'create trigger zorvin_acompanhamento_quem
             before insert or update on public.zorvin_acompanhamentos
             for each row execute function public.zorvin_acompanhamento_quem()';

  -- ----------------------------------------------------------
  --  2. O QUE JÁ FOI LEMBRADO — só a ponte (pelas funções do banco)
  --
  --  A regra apagada não apaga o registro (`set null`): é por ele que a
  --  tarefa aberta se fecha sozinha quando a conversa anda, e que o teto do
  --  dia é contado.
  -- ----------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_acompanhamentos_feitos (
      id                 uuid primary key default gen_random_uuid(),
      cartao_id          uuid not null references public.zorvin_cartoes(id) on delete cascade,
      acompanhamento_id  uuid references public.zorvin_acompanhamentos(id) on delete set null,
      desde              timestamptz not null,
      tarefa_id          uuid references public.zorvin_tarefas(id) on delete set null,
      para_quem          uuid,
      pulado             text,
      criado_em          timestamptz not null default now(),
      unique (cartao_id, acompanhamento_id, desde)
    )
  $x$;
  execute 'create index if not exists zorvin_acompanhamentos_feitos_tarefa
             on public.zorvin_acompanhamentos_feitos (tarefa_id) where tarefa_id is not null';
  execute 'create index if not exists zorvin_acompanhamentos_feitos_do_dia
             on public.zorvin_acompanhamentos_feitos (criado_em) where pulado is null';
  execute 'alter table public.zorvin_acompanhamentos_feitos enable row level security';
  if v_anon then execute 'revoke all on public.zorvin_acompanhamentos_feitos from anon'; end if;
  if v_auth then execute 'revoke all on public.zorvin_acompanhamentos_feitos from authenticated'; end if;
  if v_srv then execute 'grant all on public.zorvin_acompanhamentos_feitos to service_role'; end if;

  -- ----------------------------------------------------------
  --  3. A MENSAGEM PRONTA DA TAREFA
  -- ----------------------------------------------------------
  execute 'alter table public.zorvin_tarefas add column if not exists mensagem text';
  if not exists (select 1 from pg_constraint where conname = 'zorvin_tarefas_mensagem_tamanho') then
    execute 'alter table public.zorvin_tarefas add constraint zorvin_tarefas_mensagem_tamanho
               check (mensagem is null or length(mensagem) <= 2000)';
  end if;

  -- ----------------------------------------------------------
  --  4. A RODADA — só a ponte chama
  --
  --  Devolve { criadas, fechadas, adiadas, puladas }. O log da ponte leva só
  --  esses números.
  -- ----------------------------------------------------------
  for r in select p.oid::regprocedure as f from pg_proc p
            where p.proname = 'zorvin_acompanhar_funil'
              and p.pronamespace = 'public'::regnamespace
  loop
    execute 'drop function ' || r.f;
  end loop;
  execute $x$
    create function public.zorvin_acompanhar_funil(p_limite integer default 50, p_por_pessoa integer default 20)
    returns jsonb
    language plpgsql security definer set search_path = public as $f$
    declare
      r            record;
      v_para       uuid;
      v_ve         boolean;
      v_tarefa     uuid;
      -- O DIA DO TETO é o de São Paulo, e não o da máquina (UTC).
      v_hoje       timestamptz := (date_trunc('day', now() at time zone 'America/Sao_Paulo'))
                                    at time zone 'America/Sao_Paulo';
      v_fechados   bigint[] := '{}';
      v_tem_ve     boolean := to_regprocedure('public.zorvin_ve_o_telefone(uuid,uuid)') is not null;
      v_criadas    integer := 0;
      v_fechadas   integer := 0;
      v_adiadas    integer := 0;
      v_puladas    integer := 0;
      v_limite     integer := greatest(least(coalesce(p_limite, 50), 200), 1);
      v_teto       integer := greatest(least(coalesce(p_por_pessoa, 20), 200), 1);
    begin
      -- 1. O LEMBRETE QUE A CONVERSA JÁ RESOLVEU SE FECHA: o cliente escreveu,
      -- a equipe respondeu, alguém deu "Já tratei", ou o cartão mudou de etapa
      -- depois de o lembrete nascer. Só os que o Zorvin criou.
      update public.zorvin_tarefas t set feita_em = now()
        from public.conversas c
       where c.id = t.conversa_id
         and t.feita_em is null and t.mensagem is not null and t.criada_por is null
         and (exists (select 1 from public.mensagens m
                       where m.conversa_id = t.conversa_id and m.criado_em > t.criada_em
                         and m.automatica is not true)
              or (to_jsonb(c) ->> 'tratada_em')::timestamptz > t.criada_em
              or exists (select 1 from public.zorvin_acompanhamentos_feitos f
                           join public.zorvin_cartoes k on k.id = f.cartao_id
                          where f.tarefa_id = t.id and k.movido_em > t.criada_em));
      get diagnostics v_fechadas = row_count;

      -- 2. O EXPEDIENTE (021). Fechado agora, o departamento espera abrir. A
      -- semana sem nenhum dia aberto não segura nada: "nunca lembrar" não é
      -- uma escolha que alguém faça na tela da resposta fora do horário.
      if to_regprocedure('public.zorvin_horario_de(jsonb,text,timestamptz)') is not null
         and to_regclass('public.zorvin_fora_do_horario') is not null then
        execute $q$
          select coalesce(array_agg(h.departamento_id), '{}')
            from (select f.departamento_id, public.zorvin_horario_de(f.semana, f.fuso, now()) as hr
                    from public.zorvin_fora_do_horario f) h
           where (h.hr ->> 'aberto')::boolean is false and h.hr ->> 'abre_em' is not null
        $q$ into v_fechados;
      end if;

      -- 3. QUEM VENCEU, a regra maior de cada cliente primeiro.
      for r in
        with cand as (
          select k.id as cartao_id, k.departamento_id, e.nome as etapa_nome,
                 a.id as acompanhamento_id, a.dias, a.texto, a.vale_desde,
                 cv.id as conversa_id, cv.advogado_id, cv.responsavel_id,
                 greatest(k.movido_em, uc.quando,
                          least(pt.quando,
                                case when cv.tratada_em > coalesce(uc.quando, '-infinity'::timestamptz)
                                     then cv.tratada_em end)) as desde
            from public.zorvin_cartoes k
            join public.zorvin_etapas e on e.id = k.etapa_id and e.ativo
            join public.zorvin_acompanhamentos a on a.etapa_id = k.etapa_id
            join public.contatos ct on ct.id = k.contato_id and ct.numero not like 'grupo:%'
            cross join lateral (
              select c.id, c.advogado_id,
                     (to_jsonb(c) ->> 'responsavel_id')::uuid as responsavel_id,
                     (to_jsonb(c) ->> 'tratada_em')::timestamptz as tratada_em
                from public.conversas c
                join public.advogados ad on ad.id = c.advogado_id
               where c.contato_id = k.contato_id
                 and ad.ativo is distinct from false
                 and coalesce((to_jsonb(c) ->> 'arquivada')::boolean, false) = false
                 and case when k.advogado_id is not null then c.advogado_id = k.advogado_id
                          else ad.departamento_id = k.departamento_id
                               and not exists (select 1 from public.zorvin_funis g
                                                where g.advogado_id = ad.id and g.ativo)
                     end
               order by c.ultima_atividade desc nulls last
               limit 1
            ) cv
            -- A ÚLTIMA DO CLIENTE…
            left join lateral (
              select m.criado_em as quando
                from public.mensagens m
               where m.conversa_id = cv.id and m.origem = 'contato'
               order by m.criado_em desc
               limit 1
            ) uc on true
            -- …E A PRIMEIRA DA EQUIPE DEPOIS DELA: as cobranças seguintes não
            -- recomeçam a conta.
            left join lateral (
              select m.criado_em as quando
                from public.mensagens m
               where m.conversa_id = cv.id and m.origem = 'advogado' and m.automatica is not true
                 and m.criado_em > coalesce(uc.quando, '-infinity'::timestamptz)
               order by m.criado_em
               limit 1
            ) pt on true
           where (k.advogado_id is null
                  or exists (select 1 from public.zorvin_funis g where g.advogado_id = k.advogado_id and g.ativo))
             and not (k.departamento_id = any (v_fechados))
             -- A EQUIPE JÁ PLANEJOU: uma agendada esperando a hora.
             and not exists (select 1 from public.fila_envio fe
                              where fe.conversa_id = cv.id and fe.status = 'pendente'
                                and fe.agendada_para > now())
        )
        , vencidas as (
          select c.*, c.desde + make_interval(days => c.dias) as vence
            from cand c
           where now() >= c.desde + make_interval(days => c.dias)
             -- VALE PARA O QUE VENCE DEPOIS DE A REGRA EXISTIR.
             and c.desde + make_interval(days => c.dias) >= c.vale_desde
             and not exists (select 1 from public.zorvin_acompanhamentos_feitos f
                              where f.cartao_id = c.cartao_id and f.acompanhamento_id = c.acompanhamento_id
                                and f.desde = c.desde)
        )
        select v.*,
               row_number() over (partition by v.cartao_id order by v.dias desc) as rn,
               first_value(v.vence) over (partition by v.cartao_id order by v.dias desc) as vence_do_cliente
          from vencidas v
         order by vence_do_cliente, v.cartao_id, rn
         limit v_limite * 5
      loop
        exit when v_criadas >= v_limite and r.rn = 1;

        -- UM LEMBRETE DE ACOMPANHAMENTO ABERTO POR CONVERSA. É também o que
        -- faz valer "uma regra por silêncio": a maior vencida vem primeiro
        -- (`rn`) e vira tarefa, e as menores do mesmo cliente encontram o
        -- lembrete dela aberto e são dadas por feitas, sem tarefa.
        if exists (select 1 from public.zorvin_tarefas t
                    where t.conversa_id = r.conversa_id and t.feita_em is null and t.mensagem is not null) then
          insert into public.zorvin_acompanhamentos_feitos (cartao_id, acompanhamento_id, desde, pulado)
          values (r.cartao_id, r.acompanhamento_id, r.desde, 'já havia um lembrete aberto')
          on conflict (cartao_id, acompanhamento_id, desde) do nothing;
          v_puladas := v_puladas + 1;
          continue;
        end if;

        -- QUEM RECEBE: o responsável; sem ele, quem da equipe escreveu por
        -- último (a automática e a mandada pelo celular não têm quem).
        v_para := r.responsavel_id;
        if v_para is null then
          select (to_jsonb(m) ->> 'enviado_por_id')::uuid into v_para
            from public.mensagens m
           where m.conversa_id = r.conversa_id and m.origem = 'advogado'
             and m.automatica is not true
             and (to_jsonb(m) ->> 'enviado_por_id') is not null
           order by m.criado_em desc
           limit 1;
        end if;
        -- DESATIVADO, OU SEM VER O TELEFONE, a tarefa nasce sem dono.
        if v_para is not null then
          if not exists (select 1 from public.usuarios u
                          where u.id = v_para and u.ativo is distinct from false) then
            v_para := null;
          elsif v_tem_ve then
            execute 'select public.zorvin_ve_o_telefone($1, $2)' into v_ve using v_para, r.advogado_id;
            if v_ve is not true then v_para := null; end if;
          end if;
        end if;

        -- O TETO POR PESSOA, por dia de São Paulo. O que passar espera amanhã.
        if (select count(*) from public.zorvin_acompanhamentos_feitos f
             where f.pulado is null and f.criado_em >= v_hoje
               and f.para_quem is not distinct from v_para) >= v_teto then
          v_adiadas := v_adiadas + 1;
          continue;
        end if;

        insert into public.zorvin_tarefas (conversa_id, texto, vence_em, para_quem, mensagem)
        values (r.conversa_id,
                left(format('Acompanhar o cliente em “%s” (lembrete de %s %s).',
                            r.etapa_nome, r.dias, case when r.dias = 1 then 'dia' else 'dias' end), 500),
                now(), v_para, r.texto)
        returning id into v_tarefa;
        insert into public.zorvin_acompanhamentos_feitos (cartao_id, acompanhamento_id, desde, tarefa_id, para_quem)
        values (r.cartao_id, r.acompanhamento_id, r.desde, v_tarefa, v_para);
        v_criadas := v_criadas + 1;
      end loop;

      return jsonb_build_object('criadas', v_criadas, 'fechadas', v_fechadas,
                                'adiadas', v_adiadas, 'puladas', v_puladas);
    end
    $f$
  $x$;

  foreach v_assin in array array['public.zorvin_acompanhar_funil(integer, integer)'] loop
    execute format('revoke all on function %s from public', v_assin);
    if v_anon then execute format('revoke all on function %s from anon', v_assin); end if;
    if v_auth then execute format('revoke all on function %s from authenticated', v_assin); end if;
    if v_srv then execute format('grant execute on function %s to service_role', v_assin); end if;
  end loop;
  -- O GATILHO DAS REGRAS não é chamado por ninguém (o Postgres confere o
  -- EXECUTE ao CRIAR o gatilho, e não ao disparar).
  execute 'revoke all on function public.zorvin_acompanhamento_quem() from public';
  if v_anon then execute 'revoke all on function public.zorvin_acompanhamento_quem() from anon'; end if;
  if v_auth then execute 'revoke all on function public.zorvin_acompanhamento_quem() from authenticated'; end if;

  -- ----------------------------------------------------------
  --  A CONFERÊNCIA
  -- ----------------------------------------------------------
  insert into zorvin_conferencia_045
  select 'regras de acompanhamento escritas'::text,
         (select count(*) from public.zorvin_acompanhamentos)::text
  union all
  select 'a mensagem pronta da tarefa existe',
         exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'zorvin_tarefas' and column_name = 'mensagem')::text
  union all
  select 'só a ponte cria os lembretes',
         (case when v_auth
               then not has_function_privilege('authenticated', 'public.zorvin_acompanhar_funil(integer, integer)', 'execute')
               else true end
          and case when v_anon
                   then not has_function_privilege('anon', 'public.zorvin_acompanhar_funil(integer, integer)', 'execute')
                   else true end)::text
  union all
  select 'quem entrou não alcança o registro dos lembretes',
         (case when v_auth
               then not has_table_privilege('authenticated', 'public.zorvin_acompanhamentos_feitos', 'select')
               else true end)::text;
end
$acomp$;

-- E A CONFERÊNCIA NO PAPEL DE QUEM ATENDE — a régua 4 do LEIA-ME.
do $conf$
declare
  v_resposta text;
begin
  if to_regclass('public.zorvin_acompanhamentos') is null
     or not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;
  begin
    perform set_config('role', 'authenticated', true);
    perform count(*), max(texto), max(dias) from public.zorvin_acompanhamentos;
    perform count(*), max(mensagem) from public.zorvin_tarefas;
    v_resposta := 'sim';
    execute 'reset role';
  exception when others then
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;
  insert into zorvin_conferencia_045 values ('quem entrou lê as regras e a mensagem pronta', v_resposta);
end
$conf$;

select * from zorvin_conferencia_045;
