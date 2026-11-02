-- ============================================================
--  O FUNIL DE CADA TELEFONE
--
--  >>> A PONTE APLICA SOZINHA (sql/automaticos). <<<
--  Pode rodar de novo sem medo — a pasta inteira, na ordem (regra 5).
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido do Rodrigo em 02/11, junto com "o funil movido pela IA":
--  "Haverão etapas diferentes no funil de cada departamento, ideal também ter
--  a opção de funil para cada telefone."
--
--  O funil nasceu um por DEPARTAMENTO (017). Medido em 02/11: o Sucesso do
--  Cliente tem cinco telefones com trabalhos que não se parecem — SAC (871
--  clientes), SDC CCR (280), Subsídio Emenda (241), Audiências (232) e
--  Sucesso do Cliente (31). Num funil só, a jornada de quem recebe um aviso
--  de audiência e a de quem pede a segunda via do boleto teriam de caber nas
--  mesmas colunas.
--
--  A OPÇÃO É POR TELEFONE, e o padrão continua o de sempre: todo telefone usa
--  o funil do departamento dele, até alguém dar a ele um funil próprio. Nos
--  Acordos, os oito telefones são as linhas de cada advogado, com o mesmo
--  trabalho, e continuam dividindo um funil só.
--
--  ------------------------------------------------------------
--  COMO É GUARDADO
--
--  `advogado_id` (o telefone) nas três tabelas do 017, e NULO quer dizer "o
--  funil do departamento". Assim os 1.629 cartões e as etapas de hoje não
--  precisam de conta nenhuma para continuar onde estão: eles já são do funil
--  do departamento.
--
--    zorvin_funis       quais telefones têm funil próprio, e se ele está em
--                       uso (`ativo`). Desligar não apaga nada: o telefone
--                       volta a usar o funil do departamento, e o funil dele
--                       fica guardado, com os cartões, para quando voltar.
--    zorvin_etapas      + advogado_id: as colunas do funil do telefone
--    zorvin_cartoes     + advogado_id: o cliente naquele funil — UM cartão por
--                       cliente em cada funil (era um por departamento)
--    zorvin_movimentos  + advogado_id: de qual funil é cada passo
--
--  ------------------------------------------------------------
--  QUEM VÊ O CARTÃO DO FUNIL DE UM TELEFONE É QUEM VÊ AS CONVERSAS DAQUELE
--  TELEFONE com o cliente. E o funil do departamento passa a ser dos
--  telefones que NÃO têm funil próprio: quem só atende as Audiências não vê,
--  pelo funil do departamento, o cartão do SAC de um cliente que fala com os
--  dois. Antes, ver uma conversa do departamento bastava.
--
--  O HISTÓRICO É A EXCEÇÃO: o passo do funil do departamento continua sendo
--  visto por quem vê o cliente em qualquer telefone do departamento (a regra
--  do 017). O cartão guardado some da tela; o caminho por onde o cliente já
--  passou, não.
--
--  DAR UM FUNIL PRÓPRIO A UM TELEFONE (`zorvin_funil_do_telefone`, só quem
--  administra, pela tela):
--
--    - as etapas nascem COPIADAS das do departamento (nomes, cores, ordem) —
--      é um ponto de partida, e cada um muda as suas depois;
--    - os clientes que estão no funil do departamento e conversam por este
--      telefone ganham um cartão no funil novo, NA ETAPA DE MESMO NOME. Quem
--      foi tirado do funil (não tem cartão) não volta: tirar foi decisão de
--      alguém;
--    - o cartão do departamento NÃO é apagado. Quem também fala com outro
--      telefone do departamento continua lá; quem só falava com este fica
--      guardado, sem aparecer, e volta se o funil próprio for desligado.
--
--  E DESLIGAR faz o caminho de volta: quem só tem cartão no funil do telefone
--  ganha um no do departamento, na etapa de mesmo nome. Nada se apaga.
--
--  ------------------------------------------------------------
--  A VERSÃO DE REFERÊNCIA (regra 5 do LEIA-ME) daqui para a frente, porque
--  este script as recria: `zorvin_cartao_confere`, `zorvin_cartao_historico`,
--  `zorvin_funil_cliente_novo` e `zorvin_funil_trazer` (do 017) e
--  `zorvin_relatorio_funil` (do 019). Rodar o 017 ou o 019 sozinhos depois
--  deste desfaria o funil do telefone; rode a pasta inteira, na ordem.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    o 017 (o funil) e as tabelas do Zorvin. Sem elas, não faz nada e diz.
-- ============================================================

do $funis$
declare
  r       record;
  v_assin text;
  -- OS PAPÉIS DA SUPABASE podem não existir num Postgres que não é o dela
  -- (a régua do 030 ao 033): cada permissão para eles pergunta antes.
  v_anon  boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_srv   boolean := exists (select 1 from pg_roles where rolname = 'service_role');
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_043;
  create temp table zorvin_conferencia_043 (item text, resposta text);

  if to_regclass('public.zorvin_etapas') is null
     or to_regclass('public.zorvin_cartoes') is null
     or to_regclass('public.zorvin_movimentos') is null
     or to_regclass('public.conversas') is null
     or to_regclass('public.advogados') is null
     or to_regclass('public.departamentos') is null
     or to_regprocedure('public.zorvin_admin()') is null then
    insert into zorvin_conferencia_043
      values ('sem o funil do 017', 'nada a fazer aqui');
    raise notice 'Zorvin: sem o funil do 017 — script 043 não fez nada.';
    return;
  end if;

  -- ----------------------------------------------------------
  --  1. QUAIS TELEFONES TÊM FUNIL PRÓPRIO
  --
  --  `advogado_id` pode ser nulo para caber, depois, a configuração do funil
  --  do departamento (a chave da IA vem no próximo script); hoje só nascem
  --  linhas de telefone. Um funil por telefone, e um por departamento.
  -- ----------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_funis (
      id               uuid primary key default gen_random_uuid(),
      departamento_id  bigint not null references public.departamentos(id) on delete cascade,
      advogado_id      uuid references public.advogados(id) on delete cascade,
      ativo            boolean not null default true,
      criado_em        timestamptz not null default now(),
      criado_por       uuid,
      mudado_em        timestamptz,
      mudado_por       uuid
    )
  $x$;
  execute $x$
    comment on table public.zorvin_funis is
      'Os telefones que têm funil próprio (advogado_id), e se ele está em uso. '
      'Sem linha, o telefone usa o funil do departamento. Desligar não apaga '
      'nada: o funil do telefone fica guardado, com os cartões.'
  $x$;
  execute 'create unique index if not exists zorvin_funis_um_por_telefone
             on public.zorvin_funis (advogado_id) where advogado_id is not null';
  execute 'create unique index if not exists zorvin_funis_um_por_departamento
             on public.zorvin_funis (departamento_id) where advogado_id is null';

  execute 'alter table public.zorvin_funis enable row level security';
  execute 'drop policy if exists zorvin_funis_leitura on public.zorvin_funis';
  execute 'create policy zorvin_funis_leitura on public.zorvin_funis
             for select to authenticated using (true)';
  -- ESCREVE QUEM ADMINISTRA, em duas políticas: `for all` daria DELETE junto,
  -- e apagar a linha apagaria em cascata... nada — mas deixaria o funil do
  -- telefone sem dono, com os cartões órfãos. Desliga-se, não se apaga.
  execute 'drop policy if exists zorvin_funis_criar on public.zorvin_funis';
  execute 'create policy zorvin_funis_criar on public.zorvin_funis
             for insert to authenticated with check (public.zorvin_admin())';
  execute 'drop policy if exists zorvin_funis_mudar on public.zorvin_funis';
  execute 'create policy zorvin_funis_mudar on public.zorvin_funis
             for update to authenticated
             using (public.zorvin_admin()) with check (public.zorvin_admin())';
  execute 'grant select, insert, update on public.zorvin_funis to authenticated';

  -- ----------------------------------------------------------
  --  2. O TELEFONE NAS TRÊS TABELAS DO FUNIL
  -- ----------------------------------------------------------
  execute 'alter table public.zorvin_etapas
             add column if not exists advogado_id uuid references public.advogados(id) on delete cascade';
  execute 'alter table public.zorvin_cartoes
             add column if not exists advogado_id uuid references public.advogados(id) on delete cascade';
  -- O histórico não tem chave estrangeira em nada (como no 017): o passo de
  -- um telefone que foi apagado continua sendo um passo que aconteceu.
  execute 'alter table public.zorvin_movimentos add column if not exists advogado_id uuid';

  -- O NOME DA ETAPA É ÚNICO DENTRO DO FUNIL, e não mais dentro do
  -- departamento: o funil do SAC e o das Audiências são do mesmo
  -- departamento e nascem com os mesmos nomes. `nulls not distinct` faz o
  -- funil do departamento (advogado_id nulo) contar como um funil só.
  execute 'drop index if exists public.zorvin_etapas_nome_ativo';
  execute 'create unique index if not exists zorvin_etapas_nome_no_funil
             on public.zorvin_etapas (departamento_id, advogado_id, lower(nome)) nulls not distinct
             where ativo';
  execute 'create index if not exists zorvin_etapas_telefone
             on public.zorvin_etapas (advogado_id, ordem) where advogado_id is not null';

  -- UM CARTÃO POR CLIENTE EM CADA FUNIL. A regra do 017 (um por cliente e
  -- departamento) não deixaria o mesmo cliente estar no funil do SAC e no
  -- das Audiências. A troca é numa transação só: não há instante sem regra.
  for r in select conname from pg_constraint
            where conrelid = 'public.zorvin_cartoes'::regclass
              and contype = 'u'
              and conname = 'zorvin_cartoes_contato_id_departamento_id_key'
  loop
    execute format('alter table public.zorvin_cartoes drop constraint %I', r.conname);
  end loop;
  execute 'create unique index if not exists zorvin_cartoes_um_por_funil
             on public.zorvin_cartoes (contato_id, departamento_id, advogado_id) nulls not distinct';
  execute 'create index if not exists zorvin_cartoes_telefone
             on public.zorvin_cartoes (advogado_id, etapa_id, movido_em desc) where advogado_id is not null';

  -- ----------------------------------------------------------
  --  3. QUEM VÊ O CARTÃO — agora por funil
  --
  --  O funil de um telefone: quem vê alguma conversa daquele telefone com o
  --  cliente. O do departamento: quem vê alguma conversa do cliente num
  --  telefone do departamento QUE NÃO TEM FUNIL PRÓPRIO.
  --
  --  `security invoker`, como a do 017: a consulta a `conversas` passa pela
  --  regra de acesso de quem pergunta. De `advogados` só `id` e
  --  `departamento_id`, que quem entrou alcança (a lição do 012).
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_ve_no_funil(p_contato uuid, p_departamento bigint, p_telefone uuid)
    returns boolean
    language sql stable security invoker set search_path = public as $f$
      select exists (
        select 1
          from public.conversas c
          join public.advogados a on a.id = c.advogado_id
         where c.contato_id = p_contato
           and case when p_telefone is not null then a.id = p_telefone
                    else a.departamento_id = p_departamento
                         and not exists (select 1 from public.zorvin_funis f
                                          where f.advogado_id = a.id and f.ativo)
               end
      )
    $f$
  $x$;

  execute 'drop policy if exists zorvin_cartoes_leitura on public.zorvin_cartoes';
  execute 'create policy zorvin_cartoes_leitura on public.zorvin_cartoes
             for select to authenticated
             using (public.zorvin_ve_no_funil(contato_id, departamento_id, advogado_id))';
  execute 'drop policy if exists zorvin_cartoes_criar on public.zorvin_cartoes';
  execute 'create policy zorvin_cartoes_criar on public.zorvin_cartoes
             for insert to authenticated
             with check (public.zorvin_ve_no_funil(contato_id, departamento_id, advogado_id))';
  execute 'drop policy if exists zorvin_cartoes_mover on public.zorvin_cartoes';
  execute 'create policy zorvin_cartoes_mover on public.zorvin_cartoes
             for update to authenticated
             using (public.zorvin_ve_no_funil(contato_id, departamento_id, advogado_id))
             with check (public.zorvin_ve_no_funil(contato_id, departamento_id, advogado_id))';
  execute 'drop policy if exists zorvin_cartoes_tirar on public.zorvin_cartoes';
  execute 'create policy zorvin_cartoes_tirar on public.zorvin_cartoes
             for delete to authenticated
             using (public.zorvin_ve_no_funil(contato_id, departamento_id, advogado_id))';
  -- O HISTÓRICO NÃO SOME COM O CARTÃO. O passo do funil do departamento
  -- continua com a regra do 017 (quem vê uma conversa do cliente em qualquer
  -- telefone do departamento): dar um funil próprio às Audiências guarda o
  -- cartão do departamento de quem só fala com elas, e não pode apagar da
  -- vista por onde esse cliente já passou. A prova do painel pegou: o caminho
  -- do histórico mostrava só o funil novo.
  execute 'drop policy if exists zorvin_movimentos_leitura on public.zorvin_movimentos';
  execute 'create policy zorvin_movimentos_leitura on public.zorvin_movimentos
             for select to authenticated
             using (case when advogado_id is null
                         then public.zorvin_ve_no_funil(contato_id, departamento_id)
                         else public.zorvin_ve_no_funil(contato_id, departamento_id, advogado_id) end)';

  -- ----------------------------------------------------------
  --  4. OS GATILHOS DOS CARTÕES — a etapa tem de ser DO MESMO FUNIL
  --
  --  Sem esta conferência, um cartão do funil das Audiências poderia ir para
  --  uma coluna do funil do SAC e sumir das duas telas.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_cartao_confere()
    returns trigger language plpgsql set search_path = public as $f$
    begin
      if not exists (select 1 from public.zorvin_etapas e
                      where e.id = new.etapa_id
                        and e.departamento_id = new.departamento_id
                        and e.advogado_id is not distinct from new.advogado_id) then
        raise exception 'Esta etapa não é deste funil.'
          using errcode = '23514';
      end if;
      if tg_op = 'UPDATE' and new.etapa_id is distinct from old.etapa_id then
        new.movido_em := now();
        new.movido_por := coalesce(auth.uid(), new.movido_por);
      elsif tg_op = 'INSERT' then
        new.movido_por := coalesce(auth.uid(), new.movido_por);
      end if;
      return new;
    end
    $f$
  $x$;

  execute $x$
    create or replace function public.zorvin_cartao_historico()
    returns trigger language plpgsql security definer set search_path = public as $f$
    begin
      if tg_op = 'INSERT' then
        insert into public.zorvin_movimentos (contato_id, departamento_id, advogado_id, de_etapa, para_etapa, quem)
        values (new.contato_id, new.departamento_id, new.advogado_id, null, new.etapa_id, auth.uid());
      elsif tg_op = 'UPDATE' then
        if new.etapa_id is distinct from old.etapa_id then
          insert into public.zorvin_movimentos (contato_id, departamento_id, advogado_id, de_etapa, para_etapa, quem)
          values (new.contato_id, new.departamento_id, new.advogado_id, old.etapa_id, new.etapa_id, auth.uid());
        end if;
      elsif tg_op = 'DELETE' then
        insert into public.zorvin_movimentos (contato_id, departamento_id, advogado_id, de_etapa, para_etapa, quem)
        values (old.contato_id, old.departamento_id, old.advogado_id, old.etapa_id, null, auth.uid());
      end if;
      return null;
    end
    $f$
  $x$;

  -- ----------------------------------------------------------
  --  5. O CLIENTE NOVO ENTRA NO FUNIL DO TELEFONE, se ele tiver um
  --
  --  Telefone com funil próprio: a primeira etapa ativa dele. Senão, o do
  --  departamento, como no 017. O corpo inteiro continua num
  --  `exception when others`: perder o cartão é um incômodo; derrubar o
  --  INSERT da conversa, e com ele a mensagem do cliente, não.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_funil_cliente_novo()
    returns trigger language plpgsql security definer set search_path = public as $f$
    declare
      v_dep      bigint;
      v_etapa    uuid;
      v_dep_eta  bigint;
      v_telefone uuid;
      v_numero   text;
    begin
      begin
        select ct.numero into v_numero from public.contatos ct where ct.id = new.contato_id;
        if v_numero is null or v_numero like 'grupo:%' then return null; end if;

        if exists (select 1 from public.zorvin_funis f
                    where f.advogado_id = new.advogado_id and f.ativo) then
          v_telefone := new.advogado_id;
          select e.id, e.departamento_id into v_etapa, v_dep_eta
            from public.zorvin_etapas e
           where e.advogado_id = new.advogado_id and e.ativo
           order by e.ordem, e.criado_em
           limit 1;
        else
          select a.departamento_id into v_dep from public.advogados a where a.id = new.advogado_id;
          if v_dep is null then return null; end if;
          select e.id, e.departamento_id into v_etapa, v_dep_eta
            from public.zorvin_etapas e
           where e.departamento_id = v_dep and e.advogado_id is null and e.ativo
           order by e.ordem, e.criado_em
           limit 1;
        end if;
        if v_etapa is null then return null; end if;

        insert into public.zorvin_cartoes (contato_id, departamento_id, advogado_id, etapa_id)
        values (new.contato_id, v_dep_eta, v_telefone, v_etapa)
        on conflict (contato_id, departamento_id, advogado_id) do nothing;
      exception when others then
        raise warning 'Zorvin: o cliente novo não entrou no funil (%): %', sqlstate, sqlerrm;
      end;
      return null;
    end
    $f$
  $x$;

  -- ----------------------------------------------------------
  --  6. TRAZER O QUE JÁ EXISTIA — agora também para o funil de um telefone
  --
  --  As versões de antes saem primeiro: `create or replace` com outra lista
  --  de argumentos criaria uma SEGUNDA função, e a chamada do painel de antes
  --  (que manda só departamento e dias) morreria com "could not choose the
  --  best candidate". O argumento novo tem padrão, e por isso ela continua
  --  servindo a chamada de antes.
  -- ----------------------------------------------------------
  for r in select p.oid::regprocedure as f from pg_proc p
            where p.proname = 'zorvin_funil_trazer'
              and p.pronamespace = 'public'::regnamespace
  loop
    execute 'drop function ' || r.f;
  end loop;
  execute $x$
    create function public.zorvin_funil_trazer(
      p_departamento bigint, p_dias integer default 30, p_telefone uuid default null)
    returns integer
    language plpgsql security invoker set search_path = public as $f$
    declare
      v_etapa uuid;
      v_dep   bigint;
      v_n     integer;
    begin
      if not public.zorvin_admin() then
        raise exception 'Só quem administra traz as conversas para o funil.' using errcode = '42501';
      end if;
      if p_dias is null or p_dias < 1 or p_dias > 3650 then
        raise exception 'Escolha de 1 a 3650 dias.' using errcode = '22023';
      end if;

      if p_telefone is not null then
        if not exists (select 1 from public.zorvin_funis f where f.advogado_id = p_telefone and f.ativo) then
          raise exception 'Este telefone usa o funil do departamento — traga as conversas por lá.' using errcode = '22023';
        end if;
        select e.id, e.departamento_id into v_etapa, v_dep
          from public.zorvin_etapas e
         where e.advogado_id = p_telefone and e.ativo
         order by e.ordem, e.criado_em
         limit 1;
        if v_etapa is null then
          raise exception 'O funil deste telefone ainda não tem etapa ativa.' using errcode = '22023';
        end if;
        insert into public.zorvin_cartoes (contato_id, departamento_id, advogado_id, etapa_id)
        select distinct c.contato_id, v_dep, p_telefone, v_etapa
          from public.conversas c
          join public.contatos ct on ct.id = c.contato_id
         where c.advogado_id = p_telefone
           and c.ultima_atividade >= now() - make_interval(days => p_dias)
           and coalesce(ct.numero, '') not like 'grupo:%'
        on conflict (contato_id, departamento_id, advogado_id) do nothing;
      else
        select e.id into v_etapa
          from public.zorvin_etapas e
         where e.departamento_id = p_departamento and e.advogado_id is null and e.ativo
         order by e.ordem, e.criado_em
         limit 1;
        if v_etapa is null then
          raise exception 'Este departamento ainda não tem etapa ativa no funil.' using errcode = '22023';
        end if;
        -- SÓ OS TELEFONES QUE USAM O FUNIL DO DEPARTAMENTO: os de funil
        -- próprio trazem os seus pelo funil deles.
        insert into public.zorvin_cartoes (contato_id, departamento_id, advogado_id, etapa_id)
        select distinct c.contato_id, p_departamento, null::uuid, v_etapa
          from public.conversas c
          join public.advogados a on a.id = c.advogado_id
          join public.contatos ct on ct.id = c.contato_id
         where a.departamento_id = p_departamento
           and not exists (select 1 from public.zorvin_funis f where f.advogado_id = a.id and f.ativo)
           and c.ultima_atividade >= now() - make_interval(days => p_dias)
           and coalesce(ct.numero, '') not like 'grupo:%'
        on conflict (contato_id, departamento_id, advogado_id) do nothing;
      end if;

      get diagnostics v_n = row_count;
      return v_n;
    end
    $f$
  $x$;

  -- ----------------------------------------------------------
  --  7. DAR (OU TIRAR) O FUNIL PRÓPRIO DE UM TELEFONE — só quem administra
  --
  --  Devolve o que fez: { funil, ativo, etapas, cartoes } — quantas etapas
  --  nasceram e quantos clientes ganharam cartão. A tela escreve esses
  --  números, e eles saem daqui, e não de uma conta da tela.
  --
  --  `security definer`, COM a conferência de quem administra na primeira
  --  linha, e não `security invoker` como o "trazer". Medido na prova: ligado
  --  o funil do telefone, a regra de leitura passa a esconder o cartão do
  --  departamento de quem só fala com aquele telefone — e esconde até de quem
  --  administra, porque a regra é sobre o FUNIL, e não sobre a pessoa. Lendo
  --  pela regra, justamente esses clientes ficavam fora do funil novo.
  -- ----------------------------------------------------------
  for r in select p.oid::regprocedure as f from pg_proc p
            where p.proname = 'zorvin_funil_do_telefone'
              and p.pronamespace = 'public'::regnamespace
  loop
    execute 'drop function ' || r.f;
  end loop;
  execute $x$
    create function public.zorvin_funil_do_telefone(p_telefone uuid, p_ligar boolean default true)
    returns jsonb
    language plpgsql security definer set search_path = public as $f$
    declare
      v_dep      bigint;
      v_funil    uuid;
      v_ativo    boolean;
      v_etapas   integer := 0;
      v_cartoes  integer := 0;
      v_primeira uuid;
    begin
      if not public.zorvin_admin() then
        raise exception 'Só quem administra muda o funil de um telefone.' using errcode = '42501';
      end if;
      if not exists (select 1 from public.advogados a where a.id = p_telefone) then
        raise exception 'Este telefone não existe.' using errcode = '22023';
      end if;
      select f.id, f.ativo, f.departamento_id into v_funil, v_ativo, v_dep
        from public.zorvin_funis f where f.advogado_id = p_telefone;

      if p_ligar then
        if v_funil is null then
          select a.departamento_id into v_dep from public.advogados a where a.id = p_telefone;
          if v_dep is null then
            raise exception 'Este telefone não tem departamento — ponha-o num departamento antes.' using errcode = '22023';
          end if;
          insert into public.zorvin_funis (departamento_id, advogado_id, ativo, criado_por, mudado_em, mudado_por)
          values (v_dep, p_telefone, true, auth.uid(), now(), auth.uid())
          returning id into v_funil;
        elsif not v_ativo then
          update public.zorvin_funis set ativo = true, mudado_em = now(), mudado_por = auth.uid()
           where id = v_funil;
        end if;

        -- AS ETAPAS NASCEM COPIADAS das ativas do departamento, só se o funil
        -- do telefone ainda não tem nenhuma: ligar de novo não duplica nada,
        -- nem ressuscita a etapa que alguém tirou de uso.
        if not exists (select 1 from public.zorvin_etapas e where e.advogado_id = p_telefone) then
          insert into public.zorvin_etapas (departamento_id, advogado_id, nome, ordem, cor)
          select v_dep, p_telefone, e.nome, e.ordem, e.cor
            from public.zorvin_etapas e
           where e.departamento_id = v_dep and e.advogado_id is null and e.ativo;
          get diagnostics v_etapas = row_count;
          if v_etapas = 0 then
            insert into public.zorvin_etapas (departamento_id, advogado_id, nome, ordem, cor)
            select v_dep, p_telefone, v.nome, v.ordem, v.cor
              from (values ('Novo contato', 10, '#53bdeb'), ('Em atendimento', 20, '#00a884'),
                           ('Aguardando cliente', 30, '#ffb02e'), ('Proposta/acordo enviado', 40, '#a78bfa'),
                           ('Acordo fechado', 50, '#25d366'), ('Em execução', 60, '#0ea5e9'),
                           ('Encerrado', 70, '#8696a0')) as v(nome, ordem, cor);
            get diagnostics v_etapas = row_count;
          end if;
        end if;

        select e.id into v_primeira
          from public.zorvin_etapas e
         where e.advogado_id = p_telefone and e.ativo
         order by e.ordem, e.criado_em
         limit 1;
        -- OS CLIENTES: quem está no funil do departamento e conversa por este
        -- telefone, na etapa de MESMO NOME (sem acento nem maiúscula de
        -- diferença, ela é a mesma coluna). Quem foi tirado do funil, não.
        if v_primeira is not null then
          insert into public.zorvin_cartoes (contato_id, departamento_id, advogado_id, etapa_id)
          select k.contato_id, v_dep, p_telefone,
                 coalesce((select e2.id from public.zorvin_etapas e2
                            where e2.advogado_id = p_telefone and e2.ativo
                              and lower(btrim(e2.nome)) = lower(btrim(e1.nome))
                            order by e2.ordem limit 1),
                          v_primeira)
            from public.zorvin_cartoes k
            join public.zorvin_etapas e1 on e1.id = k.etapa_id
           where k.departamento_id = v_dep and k.advogado_id is null
             and exists (select 1 from public.conversas c
                          where c.contato_id = k.contato_id and c.advogado_id = p_telefone)
          on conflict (contato_id, departamento_id, advogado_id) do nothing;
          get diagnostics v_cartoes = row_count;
        end if;
        return jsonb_build_object('funil', v_funil, 'ativo', true, 'etapas', v_etapas, 'cartoes', v_cartoes);
      end if;

      -- DESLIGAR: o telefone volta ao funil do departamento.
      if v_funil is null or not v_ativo then
        return jsonb_build_object('funil', v_funil, 'ativo', false, 'etapas', 0, 'cartoes', 0);
      end if;
      update public.zorvin_funis set ativo = false, mudado_em = now(), mudado_por = auth.uid()
       where id = v_funil;
      select e.id into v_primeira
        from public.zorvin_etapas e
       where e.departamento_id = v_dep and e.advogado_id is null and e.ativo
       order by e.ordem, e.criado_em
       limit 1;
      -- Quem só tinha cartão no funil do telefone ganha um no do departamento,
      -- na etapa de mesmo nome. O cartão do telefone fica guardado.
      if v_primeira is not null then
        insert into public.zorvin_cartoes (contato_id, departamento_id, advogado_id, etapa_id)
        select k.contato_id, v_dep, null::uuid,
               coalesce((select e2.id from public.zorvin_etapas e2
                          where e2.departamento_id = v_dep and e2.advogado_id is null and e2.ativo
                            and lower(btrim(e2.nome)) = lower(btrim(e1.nome))
                          order by e2.ordem limit 1),
                        v_primeira)
          from public.zorvin_cartoes k
          join public.zorvin_etapas e1 on e1.id = k.etapa_id
         where k.advogado_id = p_telefone
        on conflict (contato_id, departamento_id, advogado_id) do nothing;
        get diagnostics v_cartoes = row_count;
      end if;
      return jsonb_build_object('funil', v_funil, 'ativo', false, 'etapas', 0, 'cartoes', v_cartoes);
    end
    $f$
  $x$;

  -- ----------------------------------------------------------
  --  8. O RELATÓRIO DO FUNIL — um bloco por FUNIL
  --
  --  Era um por departamento (019). Agora o funil do departamento (com os
  --  telefones que não têm funil próprio) e o de cada telefone que tem o seu.
  --  A resposta continua com a chave `departamentos`, e cada bloco ganhou
  --  `telefone_id` e `telefone` (nulos no funil do departamento): o painel
  --  de antes continua lendo, e o de agora diz de qual funil é cada bloco.
  --
  --  O tempo numa etapa continua sendo o de quem SAIU, e a chegada é
  --  procurada pela própria etapa — que é de um funil só, então o passo de
  --  um funil nunca serve de chegada para o outro.
  --
  --  O filtro de telefone: o funil próprio dele, se tiver; senão, o do
  --  departamento, só com os clientes que conversam por ele (como no 019).
  -- ----------------------------------------------------------
  for r in select p.oid::regprocedure as f from pg_proc p
            where p.proname = 'zorvin_relatorio_funil'
              and p.pronamespace = 'public'::regnamespace
  loop
    execute 'drop function ' || r.f;
  end loop;
  execute $x$
    create function public.zorvin_relatorio_funil(
      p_desde        timestamptz default null,
      p_ate          timestamptz default null,
      p_departamento bigint      default null,
      p_telefone     uuid        default null
    )
    returns jsonb
    language plpgsql
    stable
    security invoker
    set search_path = public
    as $fn$
    declare
      v_desde timestamptz := coalesce(p_desde, now() - interval '30 days');
      v_ate   timestamptz := coalesce(p_ate, now());
      v_dep_do_telefone bigint;
      v_tel_tem_funil   boolean := false;
      v_saida jsonb;
    begin
      if p_telefone is not null then
        select a.departamento_id into v_dep_do_telefone from public.advogados a where a.id = p_telefone;
        v_tel_tem_funil := exists (select 1 from public.zorvin_funis f
                                    where f.advogado_id = p_telefone and f.ativo);
      end if;

      with
      com_funil as (
        select f.advogado_id from public.zorvin_funis f
         where f.ativo and f.advogado_id is not null
      ),
      funis as (
        select d.id as departamento_id, d.nome, d.ordem, null::uuid as telefone_id,
               null::text as telefone, 0 as tipo
          from public.departamentos d
         where exists (select 1 from public.zorvin_etapas e
                        where e.departamento_id = d.id and e.advogado_id is null)
           and (p_departamento is null or d.id = p_departamento)
           and (p_telefone is null or (not v_tel_tem_funil and d.id = v_dep_do_telefone))
           and exists (select 1 from public.conversas c
                         join public.advogados a on a.id = c.advogado_id
                        where a.departamento_id = d.id
                          and a.id not in (select advogado_id from com_funil))
        union all
        select f.departamento_id, d.nome, d.ordem, f.advogado_id, a.nome, 1
          from public.zorvin_funis f
          join public.departamentos d on d.id = f.departamento_id
          join public.advogados a on a.id = f.advogado_id
         where f.ativo and f.advogado_id is not null
           and exists (select 1 from public.zorvin_etapas e where e.advogado_id = f.advogado_id)
           and (p_departamento is null or f.departamento_id = p_departamento)
           and (p_telefone is null or f.advogado_id = p_telefone)
           and exists (select 1 from public.conversas c where c.advogado_id = f.advogado_id)
      ),
      cartoes as (
        select k.etapa_id, k.departamento_id, k.advogado_id, k.movido_em
          from public.zorvin_cartoes k
          join funis f on f.departamento_id = k.departamento_id
                      and f.telefone_id is not distinct from k.advogado_id
         where (p_telefone is null or exists (
                 select 1 from public.conversas c
                  where c.contato_id = k.contato_id and c.advogado_id = p_telefone))
      ),
      movs as (
        select m.*
          from public.zorvin_movimentos m
          join funis f on f.departamento_id = m.departamento_id
                      and f.telefone_id is not distinct from m.advogado_id
         where m.quando >= v_desde and m.quando < v_ate
           and (p_telefone is null or exists (
                 select 1 from public.conversas c
                  where c.contato_id = m.contato_id and c.advogado_id = p_telefone))
      ),
      passagens as (
        select s.de_etapa as etapa_id,
               extract(epoch from s.quando - (
                 select max(c.quando) from public.zorvin_movimentos c
                  where c.contato_id = s.contato_id
                    and c.departamento_id = s.departamento_id
                    and c.para_etapa = s.de_etapa
                    and c.quando <= s.quando)) as segundos
          from movs s
         where s.de_etapa is not null
      ),
      por_etapa as (
        select e.id, e.departamento_id, e.advogado_id, e.nome, e.cor, e.ordem, e.ativo,
               (select count(*) from cartoes k where k.etapa_id = e.id)                         as agora,
               (select percentile_cont(0.5) within group (order by extract(epoch from now() - k.movido_em))
                  from cartoes k where k.etapa_id = e.id)                                       as agora_mediana_s,
               (select min(k.movido_em) from cartoes k where k.etapa_id = e.id)                 as mais_antigo,
               (select count(*) from movs m where m.para_etapa = e.id)                          as entraram,
               (select count(*) from movs m where m.de_etapa = e.id)                            as sairam,
               (select percentile_cont(0.5) within group (order by p.segundos)
                  from passagens p where p.etapa_id = e.id and p.segundos is not null)          as tempo_mediana_s,
               (select avg(p.segundos)
                  from passagens p where p.etapa_id = e.id and p.segundos is not null)          as tempo_media_s,
               (select count(*) from passagens p where p.etapa_id = e.id and p.segundos is not null) as tempo_quantos
          from public.zorvin_etapas e
          join funis f on f.departamento_id = e.departamento_id
                      and f.telefone_id is not distinct from e.advogado_id
      )
      select jsonb_build_object(
        'desde', v_desde,
        'ate', v_ate,
        'agora', now(),
        'departamentos', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'id', f.departamento_id,
                   'nome', f.nome,
                   'telefone_id', f.telefone_id,
                   'telefone', f.telefone,
                   'agora', (select count(*) from cartoes k
                              where k.departamento_id = f.departamento_id
                                and k.advogado_id is not distinct from f.telefone_id),
                   'entraram_no_funil', (select count(*) from movs m
                                          where m.departamento_id = f.departamento_id
                                            and m.advogado_id is not distinct from f.telefone_id
                                            and m.de_etapa is null),
                   'sairam_do_funil', (select count(*) from movs m
                                        where m.departamento_id = f.departamento_id
                                          and m.advogado_id is not distinct from f.telefone_id
                                          and m.para_etapa is null),
                   'movimentos', (select count(*) from movs m
                                   where m.departamento_id = f.departamento_id
                                     and m.advogado_id is not distinct from f.telefone_id),
                   'etapas', coalesce((
                     select jsonb_agg(jsonb_build_object(
                              'id', p.id, 'nome', p.nome, 'cor', p.cor, 'ordem', p.ordem,
                              'ativo', p.ativo, 'agora', p.agora,
                              'agora_mediana_s', round(p.agora_mediana_s::numeric),
                              'mais_antigo', p.mais_antigo,
                              'entraram', p.entraram, 'sairam', p.sairam,
                              'tempo_mediana_s', round(p.tempo_mediana_s::numeric),
                              'tempo_media_s', round(p.tempo_media_s::numeric),
                              'tempo_quantos', p.tempo_quantos)
                            order by p.ordem, p.nome)
                       from por_etapa p
                      where p.departamento_id = f.departamento_id
                        and p.advogado_id is not distinct from f.telefone_id
                        and (p.ativo or p.agora > 0 or p.entraram > 0 or p.sairam > 0)), '[]'::jsonb))
                 order by f.ordem, f.nome, f.tipo, f.telefone)
            from funis f), '[]'::jsonb)
      ) into v_saida;

      return v_saida;
    end
    $fn$
  $x$;
  execute $x$
    comment on function public.zorvin_relatorio_funil(timestamptz, timestamptz, bigint, uuid) is
      'O relatório do funil: por funil (o do departamento e o de cada telefone '
      'que tem o seu) e por etapa, quantos cartões estão nela agora e há quanto '
      'tempo, e no período quantos entraram, quantos saíram e quanto tempo '
      'ficaram. security invoker: conta só o que quem chama enxerga.'
  $x$;

  -- ----------------------------------------------------------
  --  AS PERMISSÕES, num lugar só
  --
  --  Toda função nasce executável por `public`, que inclui quem não entrou
  --  (a armadilha nº 5). As três que a tela chama vão para quem entrou e para
  --  a ponte; as de gatilho, para ninguém: gatilho dispara sem permissão de
  --  executar (o 032), e as recriadas com `create or replace` guardam a
  --  permissão que já tinham.
  -- ----------------------------------------------------------
  if v_anon then execute 'revoke all on public.zorvin_funis from anon'; end if;
  foreach v_assin in array array[
    'public.zorvin_ve_no_funil(uuid, bigint, uuid)',
    'public.zorvin_funil_trazer(bigint, integer, uuid)',
    'public.zorvin_funil_do_telefone(uuid, boolean)',
    'public.zorvin_relatorio_funil(timestamptz, timestamptz, bigint, uuid)'
  ] loop
    execute format('revoke all on function %s from public', v_assin);
    if v_anon then execute format('revoke all on function %s from anon', v_assin); end if;
    execute format('grant execute on function %s to authenticated', v_assin);
    if v_srv then execute format('grant execute on function %s to service_role', v_assin); end if;
  end loop;
  foreach v_assin in array array[
    'public.zorvin_cartao_historico()',
    'public.zorvin_funil_cliente_novo()'
  ] loop
    execute format('revoke all on function %s from public', v_assin);
    if v_anon then execute format('revoke all on function %s from anon', v_assin); end if;
  end loop;

  -- ----------------------------------------------------------
  --  A CONFERÊNCIA
  -- ----------------------------------------------------------
  insert into zorvin_conferencia_043
  select 'telefones com funil próprio em uso'::text,
         (select count(*) from public.zorvin_funis where advogado_id is not null and ativo)::text
  union all
  select 'o cartão é um por cliente em cada funil',
         (to_regclass('public.zorvin_cartoes_um_por_funil') is not null)::text
  union all
  select 'a regra antiga (um cartão por departamento) saiu',
         (not exists (select 1 from pg_constraint
                       where conrelid = 'public.zorvin_cartoes'::regclass
                         and conname = 'zorvin_cartoes_contato_id_departamento_id_key'))::text
  union all
  select 'o cliente novo entra sozinho no funil',
         exists (select 1 from pg_trigger
                  where tgname = 'zorvin_funil_cliente_novo'
                    and tgrelid = 'public.conversas'::regclass)::text;
end
$funis$;

-- ----------------------------------------------------------
--  E A CONFERÊNCIA NO PAPEL DE QUEM ATENDE — a régua 4 do LEIA-ME. Lê as
--  quatro tabelas e chama o relatório como `authenticated`: a regra de
--  leitura dos cartões passou a perguntar por `zorvin_funis`, e quem entrou
--  tem de alcançá-la sem "permission denied".
-- ----------------------------------------------------------
do $conf$
declare
  v_resposta text;
begin
  if to_regclass('public.zorvin_funis') is null
     or not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;
  begin
    perform set_config('role', 'authenticated', true);
    perform count(*) from public.zorvin_funis;
    perform count(*) from public.zorvin_etapas;
    perform count(*) from public.zorvin_cartoes;
    perform count(*) from public.zorvin_movimentos;
    perform public.zorvin_relatorio_funil();
    perform public.zorvin_relatorio_funil(null, null, null,
              (select a.id from public.advogados a limit 1));
    v_resposta := 'sim';
    execute 'reset role';
  exception when others then
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;
  insert into zorvin_conferencia_043 values ('quem entrou lê o funil e o relatório', v_resposta);
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha.
select * from zorvin_conferencia_043;
