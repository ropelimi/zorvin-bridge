-- ============================================================
--  A DISTRIBUIÇÃO DAS CONVERSAS NOVAS
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  A ponte aplica sozinha ao subir (sql/automaticos). Pode rodar de novo sem
--  medo — na ordem da pasta, como diz a regra 5 do LEIA-ME.
--
--  ------------------------------------------------------------
--  O PEDIDO
--
--  O nº 3 da lista de ideias de 08/10, escolhido pelo Rodrigo em 13/10: "o
--  cliente novo já chega com um responsável, em rodízio entre quem atende
--  aquele departamento". Até aqui ele ficava com quem respondesse primeiro
--  (script 008) e, até alguém responder, não era de ninguém — e com a
--  resposta automática fora do horário (021), quem escreve à noite passava a
--  noite inteira assim.
--
--  Decidido com ele:
--
--    - QUEM ENTRA no rodízio: quem atende o departamento — quem vê as
--      conversas dele. Cada pessoa tem uma chave "recebe conversas novas",
--      para tirar quem está de férias ou de folga;
--    - A REGRA é o rodízio simples: cada um recebe na sua vez;
--    - SÓ A CONVERSA DE CLIENTE NOVO. As antigas sem responsável ficam como
--      estão.
--
--  ------------------------------------------------------------
--  QUATRO DECISÕES QUE O PEDIDO NÃO DIZIA, E O PORQUÊ DE CADA UMA
--
--  1. CADA DEPARTAMENTO LIGA A SUA, E ELA NASCE DESLIGADA — como a resposta
--     fora do horário. Uma distribuição que passasse a valer na publicação
--     daria cliente a quem ninguém escolheu; ligada pela tela, quem
--     administra vê antes a lista de quem vai receber.
--
--  2. QUEM ADMINISTRA COMEÇA FORA DO RODÍZIO, e quem atende começa dentro. O
--     administrador vê todos os telefones POR administrar, e não por atender:
--     sem isto o gerente entraria no rodízio de todos os departamentos sem
--     ninguém ter escolhido. A chave de cada pessoa muda isso, nos dois
--     sentidos.
--
--  3. "NA SUA VEZ" É "QUEM RECEBEU HÁ MAIS TEMPO, NAQUELE DEPARTAMENTO". Quem
--     nunca recebeu vem primeiro, e o empate é pelo nome. Com a equipe de
--     sempre é o rodízio de sempre; e ele acerta sozinho quando a equipe
--     muda: quem volta das férias recebe a próxima, e quem entra na equipe
--     também. Com um ponteiro de "quem é o próximo", quem volta esperaria a
--     vez dar a volta na lista inteira.
--
--  4. SÓ RECEBE QUEM VÊ O TELEFONE DA CONVERSA, e não só o departamento.
--     Quem tem permissão para alguns telefones do departamento entra no
--     rodízio dele, mas só recebe as conversas desses telefones: entregar a
--     alguém uma conversa que ele não consegue abrir seria o cliente sem
--     ninguém, com cara de ter dono. A conferência do fim mede isto contra a
--     regra de acesso de verdade, pessoa por telefone.
--
--  ------------------------------------------------------------
--  O QUE É "CLIENTE NOVO" — e por que quem responde é o banco
--
--  A ponte grava a conversa com `upsert` e não sabe se ela acabou de nascer.
--  Quem sabe é o banco, olhando as mensagens. A conversa é de cliente novo
--  quando:
--
--    - a mensagem que chegou é DO CLIENTE e é RECENTE (até 30 minutos) — a
--      importação de histórico e o reenvio atrasado não distribuem o passado;
--    - a primeira mensagem da conversa também é recente: um cliente que
--      manda "Oi" e "Bom dia" em seguida é o mesmo cliente novo, e se a
--      distribuição do "Oi" tropeçou, a do "Bom dia" acerta. Conversa com
--      histórico de ontem não é nova;
--    - a EQUIPE AINDA NÃO AGIU nela: nenhuma mensagem nossa — nem a do
--      celular —, nenhum item na fila de envio. Conversa começada por nós é
--      cliente que nós procuramos, e não cliente que chegou;
--    - não é grupo, a linha não está desativada e tem departamento.
--
--  A RESPOSTA AUTOMÁTICA NÃO CONTA como a equipe ter agido: ela mora no
--  registro do 021, fora de `mensagens`. O cliente da noite recebe a resposta
--  E um responsável.
--
--  ------------------------------------------------------------
--  O RESPONSÁVEL QUE O ZORVIN PÕE
--
--  É o mesmo `responsavel_id` do 008, com `responsavel_por` NULO — "ninguém
--  passou, o Zorvin pôs". É a convenção dos movimentos do funil (017), onde
--  `quem` nulo é "O Zorvin", e o painel a lê assim: "pela distribuição
--  automática". Nenhuma tela nova para quem atende — a conversa chega com o
--  rosto da pessoa na lista e entra em "Minhas conversas" dela.
--
--  Duas pontes vivas na publicação, a caixa de entrada reprocessando, dois
--  clientes novos no mesmo segundo: a escolha é feita sob uma TRAVA POR
--  DEPARTAMENTO, e a gravação exige `responsavel_id` nulo. Ninguém recebe
--  duas vezes a mesma vez, e ninguém tira a conversa de quem já a pegou.
--
--  ------------------------------------------------------------
--  AS PEÇAS
--
--    zorvin_distribuicao             a chave de cada departamento (nasce desligada)
--    zorvin_rodizio                  a chave de cada pessoa ("recebe conversas novas")
--    zorvin_distribuicoes            quem recebeu qual conversa, e quando — é
--                                    dele que sai "quem recebeu há mais tempo"
--    zorvin_ve_o_telefone(...)       a regra de quem vê um telefone, para uma pessoa
--    zorvin_distribuir_conversa(...) a decisão, que só a ponte chama
--    zorvin_rodizio_pessoas()        a lista da tela de quem administra
--
--  ------------------------------------------------------------
--  ENQUANTO ESTE ARQUIVO NÃO FOR RODADO
--
--  A ponte descobre sozinha que a função não existe, avisa uma vez no log e
--  segue como antes. O painel não mostra a aba.
--
--  DEPENDE DE JÁ TER RODADO
--    as tabelas do Zorvin (`conversas`, `mensagens`, `contatos`, `advogados`,
--    `departamentos`, `usuarios`, `permissoes`, `fila_envio`), `zorvin_admin()`
--    e o 008 (o responsável). Sem eles — um banco limpo, a prova 51l-bis —, não
--    faz nada e diz isso.
-- ============================================================

do $distribuicao$
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DE TUDO — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_023;
  create temp table zorvin_conferencia_023 (item text, resposta text);

  -- ----------------------------------------------------------
  --  A GUARDA
  -- ----------------------------------------------------------
  if to_regclass('public.conversas') is null
     or to_regclass('public.mensagens') is null
     or to_regclass('public.contatos') is null
     or to_regclass('public.advogados') is null
     or to_regclass('public.departamentos') is null
     or to_regclass('public.usuarios') is null
     or to_regclass('public.permissoes') is null
     or to_regclass('public.fila_envio') is null
     or to_regprocedure('public.zorvin_admin()') is null then
    insert into zorvin_conferencia_023 values ('sem as tabelas do Zorvin', 'nada a criar');
    raise notice 'Zorvin: sem as tabelas do Zorvin — o script 023 não tem o que criar.';
    return;
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'conversas'
                    and column_name = 'responsavel_id') then
    insert into zorvin_conferencia_023
      values ('o responsável pela conversa (script 008)', 'rode o script 008 antes deste');
    return;
  end if;

  -- ----------------------------------------------------------
  --  O CARIMBO DE QUEM MUDOU A CHAVE, e quando — das duas tabelas de chave.
  --  Pela sessão, e não pela tela: a tela pode mandar o que quiser.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_rodizio_carimbo()
    returns trigger language plpgsql set search_path = public as $f$
    begin
      new.atualizada_em := now();
      new.atualizada_por := coalesce(auth.uid(), new.atualizada_por);
      return new;
    end
    $f$
  $x$;

  -- ----------------------------------------------------------
  --  A CHAVE DE CADA DEPARTAMENTO — nasce desligada (decisão 1)
  -- ----------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_distribuicao (
      departamento_id bigint primary key references public.departamentos(id) on delete cascade,
      ligada          boolean not null default false,
      atualizada_em   timestamptz not null default now(),
      atualizada_por  uuid
    )
  $x$;
  execute $x$
    comment on table public.zorvin_distribuicao is
      'Se as conversas novas de cada departamento são distribuídas sozinhas, '
      'em rodízio. Sem linha, ou desligada, ficam como antes: sem responsável '
      'até alguém responder. Quem administra muda; quem entrou lê.'
  $x$;
  execute 'drop trigger if exists zorvin_distribuicao_carimbo on public.zorvin_distribuicao';
  execute 'create trigger zorvin_distribuicao_carimbo
             before insert or update on public.zorvin_distribuicao
             for each row execute function public.zorvin_rodizio_carimbo()';
  execute 'alter table public.zorvin_distribuicao enable row level security';
  execute 'drop policy if exists zorvin_distribuicao_leitura on public.zorvin_distribuicao';
  execute 'create policy zorvin_distribuicao_leitura on public.zorvin_distribuicao
             for select to authenticated using (true)';
  execute 'drop policy if exists zorvin_distribuicao_criar on public.zorvin_distribuicao';
  execute 'create policy zorvin_distribuicao_criar on public.zorvin_distribuicao
             for insert to authenticated with check (public.zorvin_admin())';
  execute 'drop policy if exists zorvin_distribuicao_editar on public.zorvin_distribuicao';
  execute 'create policy zorvin_distribuicao_editar on public.zorvin_distribuicao
             for update to authenticated
             using (public.zorvin_admin()) with check (public.zorvin_admin())';
  execute 'grant select, insert, update on public.zorvin_distribuicao to authenticated';

  -- ----------------------------------------------------------
  --  A CHAVE DE CADA PESSOA — "recebe conversas novas"
  --
  --  SEM LINHA, VALE O PADRÃO (decisão 2): quem atende recebe, quem
  --  administra não. A linha só existe depois que alguém mexeu na chave da
  --  pessoa, e aí vale o que foi escolhido — inclusive para um administrador
  --  que quer receber.
  --
  --  UMA CHAVE POR PESSOA, e não por departamento: é a das férias e da folga,
  --  e quem sai de férias sai de todos os rodízios de uma vez.
  -- ----------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_rodizio (
      usuario_id      uuid primary key references public.usuarios(id) on delete cascade,
      recebe          boolean not null,
      atualizada_em   timestamptz not null default now(),
      atualizada_por  uuid
    )
  $x$;
  execute $x$
    comment on table public.zorvin_rodizio is
      'A chave "recebe conversas novas" de cada pessoa. Sem linha vale o padrão: '
      'quem atende recebe, quem administra não. Quem administra muda; quem entrou lê.'
  $x$;
  execute 'drop trigger if exists zorvin_rodizio_carimbo on public.zorvin_rodizio';
  execute 'create trigger zorvin_rodizio_carimbo
             before insert or update on public.zorvin_rodizio
             for each row execute function public.zorvin_rodizio_carimbo()';
  execute 'alter table public.zorvin_rodizio enable row level security';
  execute 'drop policy if exists zorvin_rodizio_leitura on public.zorvin_rodizio';
  execute 'create policy zorvin_rodizio_leitura on public.zorvin_rodizio
             for select to authenticated using (true)';
  execute 'drop policy if exists zorvin_rodizio_criar on public.zorvin_rodizio';
  execute 'create policy zorvin_rodizio_criar on public.zorvin_rodizio
             for insert to authenticated with check (public.zorvin_admin())';
  execute 'drop policy if exists zorvin_rodizio_editar on public.zorvin_rodizio';
  execute 'create policy zorvin_rodizio_editar on public.zorvin_rodizio
             for update to authenticated
             using (public.zorvin_admin()) with check (public.zorvin_admin())';
  execute 'grant select, insert, update on public.zorvin_rodizio to authenticated';

  -- ----------------------------------------------------------
  --  O REGISTRO: QUEM RECEBEU QUAL CONVERSA, E QUANDO
  --
  --  É a memória do rodízio ("quem recebeu há mais tempo") e a resposta para
  --  "por que esta conversa foi para ela?". UMA LINHA POR CONVERSA: uma
  --  conversa só é nova uma vez, e o `unique` é o que impede a mesma vez de
  --  ser contada duas.
  --
  --  Só a função abaixo escreve aqui. Quem administra lê, para a tela dizer
  --  quando cada pessoa recebeu a última.
  -- ----------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_distribuicoes (
      id              bigint generated always as identity primary key,
      conversa_id     uuid not null unique references public.conversas(id) on delete cascade,
      departamento_id bigint references public.departamentos(id) on delete set null,
      usuario_id      uuid references public.usuarios(id) on delete set null,
      quando          timestamptz not null default now()
    )
  $x$;
  execute $x$
    comment on table public.zorvin_distribuicoes is
      'Cada conversa nova que o Zorvin distribuiu: para quem, de qual '
      'departamento e quando. É daqui que sai a vez do rodízio.'
  $x$;
  execute 'create index if not exists zorvin_distribuicoes_vez
             on public.zorvin_distribuicoes (departamento_id, usuario_id, quando desc)';
  execute 'create index if not exists zorvin_distribuicoes_pessoa
             on public.zorvin_distribuicoes (usuario_id, quando desc)';
  execute 'alter table public.zorvin_distribuicoes enable row level security';
  execute 'drop policy if exists zorvin_distribuicoes_leitura on public.zorvin_distribuicoes';
  execute 'create policy zorvin_distribuicoes_leitura on public.zorvin_distribuicoes
             for select to authenticated using (public.zorvin_admin())';
  execute 'grant select on public.zorvin_distribuicoes to authenticated';

  -- ----------------------------------------------------------
  --  QUEM VÊ UM TELEFONE — a regra de acesso, com a pessoa como parâmetro
  --
  --  É A MESMA de `pode_ver_conversa` e `meus_telefones`: administradora
  --  ativa vê tudo; os outros, o que uma linha de `permissoes` deixar
  --  (departamento e telefone, o vazio não restringe). Aquelas perguntam por
  --  `auth.uid()`, e a distribuição precisa perguntar por cada pessoa da
  --  equipe. A conferência do fim compara esta com a de verdade, pessoa por
  --  telefone: mudou uma, a conferência acusa a outra.
  --
  --  Só as funções deste script a chamam.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_ve_o_telefone(p_usuario uuid, p_telefone uuid)
    returns boolean language sql stable security definer set search_path = public as $f$
      select coalesce((select u.admin and u.ativo from public.usuarios u where u.id = p_usuario), false)
          or exists (
            select 1
              from public.permissoes p
              join public.advogados a on a.id = p_telefone
             where p.usuario_id = p_usuario
               and (p.departamento_id is null or p.departamento_id = a.departamento_id)
               and (p.telefone_id     is null or p.telefone_id     = p_telefone))
    $f$
  $x$;
  execute 'revoke all on function public.zorvin_ve_o_telefone(uuid, uuid) from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.zorvin_ve_o_telefone(uuid, uuid) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.zorvin_ve_o_telefone(uuid, uuid) from authenticated';
  end if;

  -- ----------------------------------------------------------
  --  A DECISÃO — a ponte chama depois de gravar cada mensagem de cliente
  --
  --  Devolve `{distribuiu, motivo}` ou `{distribuiu: true, para, nome}`. O
  --  motivo é para o log da ponte e para quem investigar: as perguntas
  --  baratas vêm primeiro, e a de quase toda mensagem — "a conversa já tem
  --  dono?" — é a primeira.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_distribuir_conversa(p_conversa uuid, p_id_uazapi text)
    returns jsonb language plpgsql security definer set search_path = public as $f$
    declare
      v_conv      record;
      v_msg       record;
      v_primeira  timestamptz;
      v_dep       bigint;
      v_pessoa    record;
    begin
      select c.id, c.advogado_id, c.responsavel_id, ct.numero,
             a.ativo as linha_ativa, a.departamento_id
        into v_conv
        from public.conversas c
        join public.advogados a  on a.id  = c.advogado_id
        join public.contatos  ct on ct.id = c.contato_id
       where c.id = p_conversa;
      if not found then
        return jsonb_build_object('distribuiu', false, 'motivo', 'conversa_nao_achada');
      end if;
      if v_conv.responsavel_id is not null then
        return jsonb_build_object('distribuiu', false, 'motivo', 'ja_tem_responsavel');
      end if;
      if coalesce(v_conv.numero, '') like 'grupo:%' then
        return jsonb_build_object('distribuiu', false, 'motivo', 'grupo');
      end if;
      -- SÓ O `false` EXPLÍCITO DESATIVA — a régua da ponte para a linha.
      if v_conv.linha_ativa is false then
        return jsonb_build_object('distribuiu', false, 'motivo', 'linha_desativada');
      end if;
      v_dep := v_conv.departamento_id;
      if v_dep is null then
        return jsonb_build_object('distribuiu', false, 'motivo', 'sem_departamento');
      end if;
      if not exists (select 1 from public.zorvin_distribuicao d
                      where d.departamento_id = v_dep and d.ligada) then
        return jsonb_build_object('distribuiu', false, 'motivo', 'desligada');
      end if;

      -- A MENSAGEM QUE CHEGOU: do cliente, e recente.
      select m.origem, m.criado_em into v_msg
        from public.mensagens m
       where m.conversa_id = p_conversa and m.id_uazapi = p_id_uazapi
       limit 1;
      if not found then
        return jsonb_build_object('distribuiu', false, 'motivo', 'mensagem_nao_achada');
      end if;
      if v_msg.origem is distinct from 'contato' then
        return jsonb_build_object('distribuiu', false, 'motivo', 'nao_e_do_cliente');
      end if;
      if v_msg.criado_em < now() - interval '30 minutes' then
        return jsonb_build_object('distribuiu', false, 'motivo', 'mensagem_antiga');
      end if;

      -- CLIENTE NOVO: a equipe ainda não agiu, e a conversa começou há pouco.
      if exists (select 1 from public.mensagens m
                  where m.conversa_id = p_conversa and m.origem = 'advogado')
         or exists (select 1 from public.fila_envio f where f.conversa_id = p_conversa) then
        return jsonb_build_object('distribuiu', false, 'motivo', 'equipe_ja_agiu');
      end if;
      select min(m.criado_em) into v_primeira
        from public.mensagens m where m.conversa_id = p_conversa;
      if v_primeira < v_msg.criado_em - interval '30 minutes' then
        return jsonb_build_object('distribuiu', false, 'motivo', 'conversa_antiga');
      end if;

      -- A TRAVA DO DEPARTAMENTO: dois clientes novos no mesmo segundo não
      -- caem na mesma vez. E, depois dela, a pergunta do dono de novo — quem
      -- esperou na trava pode ter chegado depois de outra chamada pela mesma
      -- conversa.
      perform pg_advisory_xact_lock(hashtextextended('zorvin_distribuicao:' || v_dep::text, 0));
      if exists (select 1 from public.conversas c
                  where c.id = p_conversa and c.responsavel_id is not null) then
        return jsonb_build_object('distribuiu', false, 'motivo', 'ja_tem_responsavel');
      end if;

      -- A VEZ: quem recebeu há mais tempo neste departamento (quem nunca
      -- recebeu, primeiro), entre quem está ativo, recebe e vê o telefone.
      select u.id, u.nome into v_pessoa
        from public.usuarios u
        left join public.zorvin_rodizio r on r.usuario_id = u.id
       where u.ativo
         and coalesce(r.recebe, not u.admin)
         and public.zorvin_ve_o_telefone(u.id, v_conv.advogado_id)
       order by (select max(d.quando) from public.zorvin_distribuicoes d
                  where d.departamento_id = v_dep and d.usuario_id = u.id) asc nulls first,
                lower(coalesce(u.nome, '')), u.id
       limit 1;
      if not found then
        return jsonb_build_object('distribuiu', false, 'motivo', 'ninguem_no_rodizio',
                                  'departamento', v_dep);
      end if;

      update public.conversas
         set responsavel_id = v_pessoa.id, responsavel_em = now(), responsavel_por = null
       where id = p_conversa and responsavel_id is null;
      if not found then
        return jsonb_build_object('distribuiu', false, 'motivo', 'ja_tem_responsavel');
      end if;
      insert into public.zorvin_distribuicoes (conversa_id, departamento_id, usuario_id)
      values (p_conversa, v_dep, v_pessoa.id)
      on conflict (conversa_id) do nothing;

      return jsonb_build_object('distribuiu', true, 'para', v_pessoa.id, 'nome', v_pessoa.nome,
                                'departamento', v_dep);
    end
    $f$
  $x$;
  execute 'revoke all on function public.zorvin_distribuir_conversa(uuid, text) from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.zorvin_distribuir_conversa(uuid, text) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.zorvin_distribuir_conversa(uuid, text) from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.zorvin_distribuir_conversa(uuid, text) to service_role';
  end if;

  -- ----------------------------------------------------------
  --  A LISTA DA TELA DE QUEM ADMINISTRA
  --
  --  Cada pessoa ativa que vê algum telefone ativo com departamento: a chave
  --  dela (a escolhida, ou o padrão), os departamentos em que entra, quando
  --  recebeu a última e quantas recebeu hoje (no dia de Brasília). É a
  --  resposta para "quem vai receber?" ANTES de ligar, e para "está
  --  rodando?" depois.
  --
  --  SÓ QUEM ADMINISTRA: ela diz o que cada pessoa da equipe alcança. Quem
  --  não administra recebe a recusa dita, e não uma lista vazia.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_rodizio_pessoas()
    returns table (usuario_id uuid, nome text, foto_url text, administra boolean,
                   recebe boolean, escolhido boolean, departamentos bigint[],
                   ultima_em timestamptz, hoje integer)
    language plpgsql stable security definer set search_path = public as $f$
    #variable_conflict use_column
    begin
      if not public.zorvin_admin() then
        raise exception using errcode = '42501',
          message = 'Só quem administra o Zorvin vê quem recebe as conversas novas.';
      end if;
      return query
      with pessoas as (
        select u.id, u.nome, to_jsonb(u) ->> 'foto_url' as foto, coalesce(u.admin, false) as adm,
               r.recebe as escolha
          from public.usuarios u
          left join public.zorvin_rodizio r on r.usuario_id = u.id
         where u.ativo
      ), deps as (
        select p.id as pessoa, array_agg(distinct a.departamento_id order by a.departamento_id) as lista
          from pessoas p
          join public.advogados a on a.departamento_id is not null and a.ativo is not false
         where public.zorvin_ve_o_telefone(p.id, a.id)
         group by p.id
      )
      select p.id, p.nome, p.foto, p.adm,
             coalesce(p.escolha, not p.adm),
             p.escolha is not null,
             d.lista,
             (select max(x.quando) from public.zorvin_distribuicoes x where x.usuario_id = p.id),
             (select count(*)::int from public.zorvin_distribuicoes x
               where x.usuario_id = p.id
                 and x.quando >= (date_trunc('day', now() at time zone 'America/Sao_Paulo')
                                  at time zone 'America/Sao_Paulo'))
        from pessoas p
        join deps d on d.pessoa = p.id
       order by lower(coalesce(p.nome, '')), p.id;
    end
    $f$
  $x$;
  execute 'revoke all on function public.zorvin_rodizio_pessoas() from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.zorvin_rodizio_pessoas() from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.zorvin_rodizio_pessoas() to authenticated';
  end if;

  insert into zorvin_conferencia_023
  select 'a chave de cada departamento existe',
         (to_regclass('public.zorvin_distribuicao') is not null)::text
  union all
  select 'a chave de cada pessoa existe',
         (to_regclass('public.zorvin_rodizio') is not null)::text
  union all
  select 'o registro das distribuições existe',
         (to_regclass('public.zorvin_distribuicoes') is not null)::text
  union all
  select 'só a ponte distribui (quem entrou não chama a decisão)',
         (not has_function_privilege('authenticated',
            'public.zorvin_distribuir_conversa(uuid,text)', 'execute'))::text
  union all
  select 'a tela de quem administra alcança a lista do rodízio',
         has_function_privilege('authenticated', 'public.zorvin_rodizio_pessoas()', 'execute')::text
  union all
  select 'departamentos com a distribuição ligada',
         (select count(*) from public.zorvin_distribuicao where ligada)::text
  union all
  select 'pessoas no rodízio de algum departamento (quem administra começa fora)',
         (select count(*) from public.usuarios u
            left join public.zorvin_rodizio r on r.usuario_id = u.id
           where u.ativo and coalesce(r.recebe, not u.admin)
             and exists (select 1 from public.advogados a
                          where a.departamento_id is not null and a.ativo is not false
                            and public.zorvin_ve_o_telefone(u.id, a.id)))::text;
end
$distribuicao$;

-- ----------------------------------------------------------
--  A REGRA DO RODÍZIO CONTRA A REGRA DE ACESSO, PESSOA POR TELEFONE
--
--  A distribuição só entrega conversa a quem vê o telefone dela, e decide
--  isso com `zorvin_ve_o_telefone` — uma segunda escrita da regra de acesso.
--  Aqui ela é comparada com a de verdade (`pode_ver_conversa`, ou
--  `meus_telefones`), fazendo o banco acreditar que é cada pessoa da equipe,
--  uma por vez. Tem de dar ZERO divergências: uma só seria um cliente
--  entregue a quem não consegue abrir a conversa dele.
--
--  A troca de quem o banco acredita que é volta atrás sozinha no fim da
--  transação, e é desfeita aqui mesmo antes disso.
-- ----------------------------------------------------------
do $regra$
declare
  v_pessoa   record;
  v_fone     record;
  v_regra    text;
  v_ve       boolean;
  v_pares    int := 0;
  v_divergem int := 0;
  v_item     constant text :=
    'quem recebe vê a conversa (o rodízio contra a regra de acesso, pessoa por telefone)';
begin
  if to_regprocedure('public.zorvin_ve_o_telefone(uuid,uuid)') is null then
    return;
  end if;
  if to_regprocedure('public.pode_ver_conversa(uuid)') is not null then
    v_regra := 'pode_ver_conversa';
  elsif to_regprocedure('public.meus_telefones()') is not null then
    v_regra := 'meus_telefones';
  else
    insert into zorvin_conferencia_023 values (v_item, 'sem a regra de acesso para comparar');
    return;
  end if;
  begin
    for v_pessoa in select id from public.usuarios loop
      perform set_config('request.jwt.claim.sub', v_pessoa.id::text, true);
      perform set_config('request.jwt.claims',
                         json_build_object('sub', v_pessoa.id, 'role', 'authenticated')::text, true);
      for v_fone in select id from public.advogados loop
        if v_regra = 'pode_ver_conversa' then
          execute 'select public.pode_ver_conversa($1)' into v_ve using v_fone.id;
        else
          execute 'select public.zorvin_admin() or $1 = any (public.meus_telefones())'
            into v_ve using v_fone.id;
        end if;
        v_pares := v_pares + 1;
        if coalesce(v_ve, false) is distinct from public.zorvin_ve_o_telefone(v_pessoa.id, v_fone.id) then
          v_divergem := v_divergem + 1;
        end if;
      end loop;
    end loop;
    perform set_config('request.jwt.claim.sub', '', true);
    perform set_config('request.jwt.claims', '', true);
    insert into zorvin_conferencia_023 values (v_item,
      case when v_divergem = 0 then 'true'
           else 'NÃO — ' || v_divergem || ' de ' || v_pares
                || ' pares pessoa/telefone divergem da regra de acesso' end);
  exception when others then
    perform set_config('request.jwt.claim.sub', '', true);
    perform set_config('request.jwt.claims', '', true);
    insert into zorvin_conferencia_023 values (v_item,
      'NÃO consegui conferir — ' || sqlerrm || ' (código ' || sqlstate || ')');
  end;
end
$regra$;

-- ----------------------------------------------------------
--  A CONFERÊNCIA NO PAPEL DE QUEM ATENDE — a régua do 012: quem entrou tem
--  de ler as duas chaves e o registro sem "permission denied". A troca de
--  papel volta atrás sozinha.
-- ----------------------------------------------------------
do $conf$
declare
  v_resposta text;
begin
  if to_regclass('public.zorvin_distribuicoes') is null
     or not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;
  begin
    perform set_config('role', 'authenticated', true);
    perform count(*) from public.zorvin_distribuicao;
    perform count(*) from public.zorvin_rodizio;
    perform count(*) from public.zorvin_distribuicoes;
    v_resposta := 'true';
    execute 'reset role';
  exception when others then
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;
  insert into zorvin_conferencia_023
    values ('quem entrou lê as chaves do rodízio e o registro', v_resposta);
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_023;
