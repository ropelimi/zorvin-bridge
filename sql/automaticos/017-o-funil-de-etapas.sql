-- ============================================================
--  O FUNIL DE ETAPAS
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido do Rodrigo em 06/10, como segundo passo do Zorvin para CRM: cada
--  cliente numa ETAPA (Novo contato → Em atendimento → … → Encerrado), vista
--  numa tela de colunas em que o cartão é arrastado de uma para a outra.
--
--  Decidido com ele:
--
--    - UM FUNIL POR DEPARTAMENTO — o SAC e o SDC têm caminhos diferentes;
--    - o CARTÃO É O CLIENTE, e não a conversa. Enquanto o Zorvin não tem a
--      ficha própria, "cliente" é o CONTATO (um número de WhatsApp): a mesma
--      pessoa falando por dois números são dois cartões, até a ficha existir;
--    - as etapas começam numa sugestão e são editáveis na administração.
--
--  TRÊS TABELAS:
--
--    zorvin_etapas      as colunas de cada funil (um funil = um departamento)
--    zorvin_cartoes     em que etapa está cada cliente, por departamento —
--                       UM cartão por (contato, departamento)
--    zorvin_movimentos  o histórico: de qual etapa para qual, quem e quando
--
--  ------------------------------------------------------------
--  ETAPA NÃO SE APAGA, DESATIVA-SE — a régua dos assuntos do "Já tratei"
--  (script 005). Os movimentos guardam o id da etapa, e apagar deixaria o
--  histórico apontando para o nada. Por isso não há política de DELETE nas
--  etapas, e não é esquecimento.
--
--  O HISTÓRICO É ESCRITO PELO BANCO, por gatilho, e não pela tela. A tela só
--  move o cartão; quem anota "de onde para onde, quem e quando" é o gatilho —
--  assim não há como mover sem deixar rastro, nem como escrever um rastro
--  falso. Quem entrou LÊ os movimentos e não escreve nenhum.
--
--  QUEM VÊ UM CARTÃO É QUEM VÊ AS CONVERSAS DAQUELE CLIENTE NAQUELE
--  DEPARTAMENTO. A regra pergunta às próprias `conversas`, e por isso herda a
--  permissão de telefones e departamentos que já existe: ninguém enxerga pelo
--  funil o cliente de um telefone que não atende.
--
--  O CLIENTE NOVO ENTRA SOZINHO NA PRIMEIRA ETAPA. Um gatilho em `conversas`
--  põe o cartão quando nasce a primeira conversa de um contato num
--  departamento. Grupo não entra (não é cliente), e telefone sem departamento
--  também não (não há funil). O que JÁ existia antes deste script não entra
--  sozinho: quem administra traz pela tela ("Trazer as conversas dos últimos
--  N dias"), pela função `zorvin_funil_trazer`.
--
--  ------------------------------------------------------------
--  ENQUANTO ESTE ARQUIVO NÃO FOR RODADO
--
--  O painel descobre sozinho que as tabelas não existem, e o funil não
--  aparece — nem o botão da barra, nem a etapa na conversa.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    as tabelas do Zorvin (`conversas`, `contatos`, `advogados`,
--    `departamentos`) e `zorvin_admin()` — é o banco do escritório
-- ============================================================

do $funil$
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_017;
  create temp table zorvin_conferencia_017 (item text, resposta text);

  -- A GUARDA: num banco limpo (a prova 51l-bis, ou um cliente novo) não há
  -- departamento nem conversa, e o certo é desistir em silêncio.
  if to_regclass('public.conversas') is null
     or to_regclass('public.contatos') is null
     or to_regclass('public.advogados') is null
     or to_regclass('public.departamentos') is null
     or to_regprocedure('public.zorvin_admin()') is null then
    insert into zorvin_conferencia_017
      values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 017 não fez nada.';
    return;
  end if;

  -- ----------------------------------------------------------
  --  1. AS ETAPAS
  -- ----------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_etapas (
      id               uuid primary key default gen_random_uuid(),
      departamento_id  bigint not null references public.departamentos(id) on delete cascade,
      nome             text not null check (length(btrim(nome)) between 1 and 60),
      ordem            integer not null default 0,
      cor              text,
      ativo            boolean not null default true,
      criado_em        timestamptz not null default now()
    )
  $x$;
  execute $x$
    comment on table public.zorvin_etapas is
      'As colunas do funil de cada departamento. Editável na tela de '
      'administração. Não se apaga etapa: desativa-se (ativo = false), senão o '
      'histórico dos movimentos fica apontando para o nada.'
  $x$;
  -- O NOME É ÚNICO DENTRO DO FUNIL, e só entre as ativas — a régua do 005.
  execute 'create unique index if not exists zorvin_etapas_nome_ativo
             on public.zorvin_etapas (departamento_id, lower(nome)) where ativo';
  execute 'create index if not exists zorvin_etapas_departamento
             on public.zorvin_etapas (departamento_id, ordem)';

  -- AS ETAPAS SUGERIDAS, em cada departamento que ainda não tem NENHUMA. O
  -- `not exists` olha o funil INTEIRO do departamento, ativas e desativadas:
  -- rodando de novo depois de o escritório ter desativado uma, ela não
  -- ressuscita — etapa que volta sozinha é a chave que volta sozinha.
  execute $x$
    insert into public.zorvin_etapas (departamento_id, nome, ordem, cor)
    select d.id, v.nome, v.ordem, v.cor
      from public.departamentos d
     cross join (values
             ('Novo contato',              10, '#53bdeb'),
             ('Em atendimento',            20, '#00a884'),
             ('Aguardando cliente',        30, '#ffb02e'),
             ('Proposta/acordo enviado',   40, '#a78bfa'),
             ('Acordo fechado',            50, '#25d366'),
             ('Em execução',               60, '#0ea5e9'),
             ('Encerrado',                 70, '#8696a0')
          ) as v(nome, ordem, cor)
     where not exists (select 1 from public.zorvin_etapas e where e.departamento_id = d.id)
  $x$;

  execute 'alter table public.zorvin_etapas enable row level security';
  execute 'drop policy if exists zorvin_etapas_leitura on public.zorvin_etapas';
  execute 'create policy zorvin_etapas_leitura on public.zorvin_etapas
             for select to authenticated using (true)';
  -- ESCREVE QUEM ADMINISTRA, em DUAS políticas: `for all` daria DELETE junto.
  execute 'drop policy if exists zorvin_etapas_criar on public.zorvin_etapas';
  execute 'create policy zorvin_etapas_criar on public.zorvin_etapas
             for insert to authenticated with check (public.zorvin_admin())';
  execute 'drop policy if exists zorvin_etapas_editar on public.zorvin_etapas';
  execute 'create policy zorvin_etapas_editar on public.zorvin_etapas
             for update to authenticated
             using (public.zorvin_admin()) with check (public.zorvin_admin())';
  execute 'grant select, insert, update on public.zorvin_etapas to authenticated';

  -- ----------------------------------------------------------
  --  2. OS CARTÕES
  -- ----------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_cartoes (
      id               uuid primary key default gen_random_uuid(),
      contato_id       uuid not null references public.contatos(id) on delete cascade,
      departamento_id  bigint not null references public.departamentos(id) on delete cascade,
      etapa_id         uuid not null references public.zorvin_etapas(id),
      criado_em        timestamptz not null default now(),
      movido_em        timestamptz not null default now(),
      movido_por       uuid,
      unique (contato_id, departamento_id)
    )
  $x$;
  execute $x$
    comment on table public.zorvin_cartoes is
      'Em que etapa do funil está cada cliente (contato), um cartão por '
      'departamento. O histórico dos movimentos é escrito por gatilho em '
      'zorvin_movimentos.'
  $x$;
  execute 'create index if not exists zorvin_cartoes_etapa
             on public.zorvin_cartoes (departamento_id, etapa_id, movido_em desc)';

  -- ----------------------------------------------------------
  --  3. OS MOVIMENTOS — o histórico, escrito só pelo gatilho
  -- ----------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_movimentos (
      id               uuid primary key default gen_random_uuid(),
      contato_id       uuid not null,
      departamento_id  bigint not null,
      de_etapa         uuid,   -- nulo = entrou no funil agora
      para_etapa       uuid,   -- nulo = saiu do funil
      quem             uuid,   -- nulo = foi o próprio banco (cliente novo)
      quando           timestamptz not null default now()
    )
  $x$;
  execute 'create index if not exists zorvin_movimentos_contato
             on public.zorvin_movimentos (contato_id, departamento_id, quando desc)';

  -- ----------------------------------------------------------
  --  4. QUEM VÊ O CARTÃO — pergunta às próprias conversas
  --
  --  `security invoker` de propósito: a consulta a `conversas` lá dentro passa
  --  pela regra de acesso de QUEM PERGUNTA, que é a permissão por telefone e
  --  departamento que já existe. Uma regra própria aqui divergiria dela.
  --  De `advogados` só se leem `id` e `departamento_id`, que quem entrou
  --  alcança — nada de `to_jsonb(a)`, que morre na chave da Uazapi (o 012).
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_ve_no_funil(p_contato uuid, p_departamento bigint)
    returns boolean
    language sql stable security invoker set search_path = public as $f$
      select exists (
        select 1
          from public.conversas c
          join public.advogados a on a.id = c.advogado_id
         where c.contato_id = p_contato
           and a.departamento_id = p_departamento
      )
    $f$
  $x$;
  execute 'grant execute on function public.zorvin_ve_no_funil(uuid, bigint) to authenticated';

  execute 'alter table public.zorvin_cartoes enable row level security';
  execute 'drop policy if exists zorvin_cartoes_leitura on public.zorvin_cartoes';
  execute 'create policy zorvin_cartoes_leitura on public.zorvin_cartoes
             for select to authenticated
             using (public.zorvin_ve_no_funil(contato_id, departamento_id))';
  execute 'drop policy if exists zorvin_cartoes_criar on public.zorvin_cartoes';
  execute 'create policy zorvin_cartoes_criar on public.zorvin_cartoes
             for insert to authenticated
             with check (public.zorvin_ve_no_funil(contato_id, departamento_id))';
  execute 'drop policy if exists zorvin_cartoes_mover on public.zorvin_cartoes';
  execute 'create policy zorvin_cartoes_mover on public.zorvin_cartoes
             for update to authenticated
             using (public.zorvin_ve_no_funil(contato_id, departamento_id))
             with check (public.zorvin_ve_no_funil(contato_id, departamento_id))';
  -- TIRAR DO FUNIL (spam, engano) é de quem vê o cartão; o rastro fica nos
  -- movimentos, com `para_etapa` nulo.
  execute 'drop policy if exists zorvin_cartoes_tirar on public.zorvin_cartoes';
  execute 'create policy zorvin_cartoes_tirar on public.zorvin_cartoes
             for delete to authenticated
             using (public.zorvin_ve_no_funil(contato_id, departamento_id))';
  execute 'grant select, insert, update, delete on public.zorvin_cartoes to authenticated';

  execute 'alter table public.zorvin_movimentos enable row level security';
  execute 'drop policy if exists zorvin_movimentos_leitura on public.zorvin_movimentos';
  execute 'create policy zorvin_movimentos_leitura on public.zorvin_movimentos
             for select to authenticated
             using (public.zorvin_ve_no_funil(contato_id, departamento_id))';
  execute 'grant select on public.zorvin_movimentos to authenticated';

  -- ----------------------------------------------------------
  --  5. O GATILHO DOS CARTÕES: confere a etapa e escreve o histórico
  --
  --  A ETAPA TEM DE SER DO MESMO DEPARTAMENTO DO CARTÃO. Sem esta conferência,
  --  um cartão do SAC poderia ir para uma etapa do SDC e sumir das duas telas
  --  (cada funil só desenha as próprias colunas).
  --
  --  `security definer` porque quem entrou não escreve em `zorvin_movimentos`
  --  — só o gatilho escreve, e é isso que faz o histórico valer.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_cartao_confere()
    returns trigger language plpgsql set search_path = public as $f$
    begin
      if not exists (select 1 from public.zorvin_etapas e
                      where e.id = new.etapa_id
                        and e.departamento_id = new.departamento_id) then
        raise exception 'Esta etapa não é do funil deste departamento.'
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
  execute 'drop trigger if exists zorvin_cartao_confere on public.zorvin_cartoes';
  execute 'create trigger zorvin_cartao_confere
             before insert or update on public.zorvin_cartoes
             for each row execute function public.zorvin_cartao_confere()';

  execute $x$
    create or replace function public.zorvin_cartao_historico()
    returns trigger language plpgsql security definer set search_path = public as $f$
    begin
      if tg_op = 'INSERT' then
        insert into public.zorvin_movimentos (contato_id, departamento_id, de_etapa, para_etapa, quem)
        values (new.contato_id, new.departamento_id, null, new.etapa_id, auth.uid());
      elsif tg_op = 'UPDATE' then
        if new.etapa_id is distinct from old.etapa_id then
          insert into public.zorvin_movimentos (contato_id, departamento_id, de_etapa, para_etapa, quem)
          values (new.contato_id, new.departamento_id, old.etapa_id, new.etapa_id, auth.uid());
        end if;
      elsif tg_op = 'DELETE' then
        insert into public.zorvin_movimentos (contato_id, departamento_id, de_etapa, para_etapa, quem)
        values (old.contato_id, old.departamento_id, old.etapa_id, null, auth.uid());
      end if;
      return null;
    end
    $f$
  $x$;
  execute 'revoke all on function public.zorvin_cartao_historico() from public';
  execute 'drop trigger if exists zorvin_cartao_historico on public.zorvin_cartoes';
  execute 'create trigger zorvin_cartao_historico
             after insert or update or delete on public.zorvin_cartoes
             for each row execute function public.zorvin_cartao_historico()';

  -- ----------------------------------------------------------
  --  6. O CLIENTE NOVO ENTRA SOZINHO NA PRIMEIRA ETAPA
  --
  --  Gatilho em `conversas`: nasceu a conversa, o contato ganha cartão na
  --  primeira etapa ATIVA do departamento do telefone — se ainda não tiver
  --  cartão ali. Quem já tem cartão (até em "Encerrado") fica onde está: tirar
  --  de "Encerrado" é decisão de gente, e não de um gatilho.
  --
  --  O CORPO INTEIRO VIVE NUM `exception when others`, como o do 001 e o do
  --  004: um gatilho que estoura derruba o INSERT da conversa, e com ele a
  --  mensagem do cliente — o pior desfecho deste sistema. Perder o cartão é um
  --  incômodo; perder a mensagem, não.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_funil_cliente_novo()
    returns trigger language plpgsql security definer set search_path = public as $f$
    declare
      v_dep    bigint;
      v_etapa  uuid;
      v_numero text;
    begin
      begin
        select a.departamento_id into v_dep from public.advogados a where a.id = new.advogado_id;
        if v_dep is null then return null; end if;

        select ct.numero into v_numero from public.contatos ct where ct.id = new.contato_id;
        if v_numero is null or v_numero like 'grupo:%' then return null; end if;

        select e.id into v_etapa
          from public.zorvin_etapas e
         where e.departamento_id = v_dep and e.ativo
         order by e.ordem, e.criado_em
         limit 1;
        if v_etapa is null then return null; end if;

        insert into public.zorvin_cartoes (contato_id, departamento_id, etapa_id)
        values (new.contato_id, v_dep, v_etapa)
        on conflict (contato_id, departamento_id) do nothing;
      exception when others then
        raise warning 'Zorvin: o cliente novo não entrou no funil (%): %', sqlstate, sqlerrm;
      end;
      return null;
    end
    $f$
  $x$;
  execute 'revoke all on function public.zorvin_funil_cliente_novo() from public';
  execute 'drop trigger if exists zorvin_funil_cliente_novo on public.conversas';
  execute 'create trigger zorvin_funil_cliente_novo
             after insert on public.conversas
             for each row execute function public.zorvin_funil_cliente_novo()';

  -- ----------------------------------------------------------
  --  7. TRAZER O QUE JÁ EXISTIA — só quem administra, pela tela
  --
  --  Põe na primeira etapa ativa os clientes com conversa nos telefones do
  --  departamento nos últimos `p_dias`, que ainda não têm cartão ali. Não
  --  mexe em quem já tem. `security invoker`: passa pelas regras de acesso de
  --  quem chama, como tudo o mais. Devolve quantos entraram.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_funil_trazer(p_departamento bigint, p_dias integer default 30)
    returns integer
    language plpgsql security invoker set search_path = public as $f$
    declare
      v_etapa uuid;
      v_n     integer;
    begin
      if not public.zorvin_admin() then
        raise exception 'Só quem administra traz as conversas para o funil.' using errcode = '42501';
      end if;
      if p_dias is null or p_dias < 1 or p_dias > 3650 then
        raise exception 'Escolha de 1 a 3650 dias.' using errcode = '22023';
      end if;

      select e.id into v_etapa
        from public.zorvin_etapas e
       where e.departamento_id = p_departamento and e.ativo
       order by e.ordem, e.criado_em
       limit 1;
      if v_etapa is null then
        raise exception 'Este departamento ainda não tem etapa ativa no funil.' using errcode = '22023';
      end if;

      insert into public.zorvin_cartoes (contato_id, departamento_id, etapa_id)
      select distinct c.contato_id, p_departamento, v_etapa
        from public.conversas c
        join public.advogados a on a.id = c.advogado_id
        join public.contatos ct on ct.id = c.contato_id
       where a.departamento_id = p_departamento
         and c.ultima_atividade >= now() - make_interval(days => p_dias)
         and coalesce(ct.numero, '') not like 'grupo:%'
      on conflict (contato_id, departamento_id) do nothing;

      get diagnostics v_n = row_count;
      return v_n;
    end
    $f$
  $x$;
  execute 'revoke all on function public.zorvin_funil_trazer(bigint, integer) from public';
  execute 'grant execute on function public.zorvin_funil_trazer(bigint, integer) to authenticated';

  -- ----------------------------------------------------------
  --  A CONFERÊNCIA
  -- ----------------------------------------------------------
  insert into zorvin_conferencia_017
  select 'departamentos com funil'::text,
         (select count(distinct departamento_id) from public.zorvin_etapas)::text
          || ' de ' || (select count(*) from public.departamentos)::text
  union all
  select 'etapas ativas',
         (select count(*) from public.zorvin_etapas where ativo)::text
  union all
  select 'o cliente novo entra sozinho',
         exists (select 1 from pg_trigger
                  where tgname = 'zorvin_funil_cliente_novo'
                    and tgrelid = 'public.conversas'::regclass)::text;
end
$funil$;

-- ----------------------------------------------------------
--  E A CONFERÊNCIA NO PAPEL DE QUEM ATENDE — a régua 4 do LEIA-ME. Lê as
--  três tabelas como `authenticated`; quem entrou tem de alcançá-las sem
--  "permission denied". A troca de papel volta atrás sozinha se falhar.
-- ----------------------------------------------------------
do $conf$
declare
  v_resposta text;
begin
  if to_regclass('public.zorvin_cartoes') is null
     or not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;
  begin
    perform set_config('role', 'authenticated', true);
    perform count(*) from public.zorvin_etapas;
    perform count(*) from public.zorvin_cartoes;
    perform count(*) from public.zorvin_movimentos;
    v_resposta := 'true';
    execute 'reset role';
  exception when others then
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;
  insert into zorvin_conferencia_017 values ('quem entrou consegue ler o funil', v_resposta);
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_017;
