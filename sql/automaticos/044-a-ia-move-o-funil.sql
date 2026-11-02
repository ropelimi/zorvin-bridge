-- ============================================================
--  A IA MOVE O FUNIL
--
--  >>> A PONTE APLICA SOZINHA (sql/automaticos). <<<
--  Pode rodar de novo sem medo — a pasta inteira, na ordem (regra 5).
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido do Rodrigo em 02/11: "funil movido pela IA". A IA lê a conversa e
--  muda a etapa SOZINHA (decidido com ele: sozinha, e não só sugerir), e o
--  cartão diz que foi ela e por quê. Medido em 02/11: dos 1.081 cartões do
--  Sucesso do Cliente, 984 entraram pelo "Trazer conversas" e continuam na
--  etapa em que nasceram; só 8 foram movidos por uma pessoa depois.
--
--  QUEM LÊ E DECIDE É A PONTE (a rodada `moverOFunilComAIA`, no index.js),
--  com a chave e o modelo do copiloto. Este script guarda o que ela precisa:
--
--    zorvin_funis.ia_ligada       a chave, POR FUNIL (o de um departamento ou
--                                 o de um telefone — o 043). Nasce desligada.
--    zorvin_etapas.descricao      o que a etapa quer dizer, para a IA e para
--                                 quem olha. Opcional: sem ela, vale o nome.
--    zorvin_cartoes.ia_leu_ate    até onde a IA leu a conversa deste cliente
--                                 (a última atividade que ela viu)
--    zorvin_cartoes.ia_motivo     o porquê, quando foi a IA que pôs o cartão
--                                 onde ele está; nulo quando foi gente
--    zorvin_movimentos.pela_ia    no histórico: este passo foi da IA?
--    zorvin_movimentos.motivo     e o porquê dela
--
--  ------------------------------------------------------------
--  QUEM ESCREVE O QUE A IA FEZ É SÓ A PONTE
--
--  O painel grava como `authenticated`, e a regra de mover deixa qualquer um
--  que vê o cartão mexer nele inteiro. Então o gatilho que confere o cartão
--  desfaz o que o painel escrever em `ia_motivo` e `ia_leu_ate`: um motivo de
--  IA que uma pessoa escreveu seria a tela mentindo sobre quem decidiu. E
--  quando uma PESSOA muda a etapa, o motivo da IA sai: ele não pode continuar
--  valendo para uma etapa que ela não escolheu. As funções do banco
--  (`security definer`, como a que liga a IA) não passam por essa trava.
--
--  QUEM MOVEU, NO HISTÓRICO: a ponte grava com a chave de serviço, e ali
--  `auth.uid()` é nulo — o mesmo nulo do cliente que entrou sozinho no funil
--  (017). O que separa os dois é o motivo: a IA SEMPRE grava o porquê junto
--  com a etapa.
--
--  ------------------------------------------------------------
--  O QUE A IA LÊ — `zorvin_funil_para_a_ia`, só da ponte
--
--    - só os funis com a chave ligada (e o de um telefone, só em uso);
--    - quem a IA ainda não leu (a passada que começa quando a chave liga), e
--      depois só quem teve conversa NOVA desde a última leitura;
--    - E O QUE UMA PESSOA DECIDIU NÃO É DESFEITO SEM NADA NOVO NA CONVERSA:
--      com uma mudança de etapa feita por gente depois da última mensagem, a
--      IA espera a próxima. "Decidiu" é MUDAR a etapa (`movido_em` depois de
--      `criado_em`): o cartão que nasceu pelo "Trazer conversas" tem quem
--      clicou em `movido_por`, e isso não é uma decisão sobre a etapa dele;
--    - só depois que a conversa sossega (`p_quieto_min`, 10 minutos): no meio
--      de uma troca de mensagens a etapa ainda está mudando;
--    - grupo não é cliente de funil;
--    - a conversa mais recente primeiro.
--
--  ------------------------------------------------------------
--  LIGAR A IA NUM FUNIL — `zorvin_ia_do_funil`, só quem administra, pela tela.
--  Ligar faz a IA ler, uma vez, todos os clientes que já estão no funil. E
--  "passar de novo" (depois de mudar as etapas) faz a mesma coisa. Desligar
--  não desfaz nada do que ela fez.
--
--  ------------------------------------------------------------
--  A VERSÃO DE REFERÊNCIA (regra 5) de `zorvin_cartao_confere` e
--  `zorvin_cartao_historico` passa a ser a deste script.
--
--  DEPENDE DE JÁ TER RODADO: o 017 e o 043. Sem eles, não faz nada e diz.
-- ============================================================

do $ia$
declare
  r       record;
  v_assin text;
  v_anon  boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_auth  boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_srv   boolean := exists (select 1 from pg_roles where rolname = 'service_role');
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_044;
  create temp table zorvin_conferencia_044 (item text, resposta text);

  if to_regclass('public.zorvin_funis') is null
     or to_regclass('public.zorvin_etapas') is null
     or to_regclass('public.zorvin_cartoes') is null
     or to_regclass('public.zorvin_movimentos') is null
     or to_regclass('public.conversas') is null
     or to_regclass('public.contatos') is null
     or to_regclass('public.advogados') is null
     or to_regclass('public.departamentos') is null
     or to_regprocedure('public.zorvin_admin()') is null then
    insert into zorvin_conferencia_044
      values ('sem o funil de cada telefone (043)', 'nada a fazer aqui');
    raise notice 'Zorvin: sem o 043 — script 044 não fez nada.';
    return;
  end if;

  -- ----------------------------------------------------------
  --  1. AS COLUNAS
  -- ----------------------------------------------------------
  execute 'alter table public.zorvin_funis add column if not exists ia_ligada boolean not null default false';
  execute 'alter table public.zorvin_funis add column if not exists ia_mudada_em timestamptz';
  execute 'alter table public.zorvin_funis add column if not exists ia_mudada_por uuid';
  execute 'alter table public.zorvin_etapas add column if not exists descricao text';
  execute 'alter table public.zorvin_cartoes add column if not exists ia_leu_ate timestamptz';
  execute 'alter table public.zorvin_cartoes add column if not exists ia_motivo text';
  execute 'alter table public.zorvin_movimentos add column if not exists pela_ia boolean not null default false';
  execute 'alter table public.zorvin_movimentos add column if not exists motivo text';

  -- OS TETOS: a descrição é para caber no pedido à IA e em duas linhas da
  -- tela; o motivo, numa linha do cartão.
  if not exists (select 1 from pg_constraint where conname = 'zorvin_etapas_descricao_tamanho') then
    execute 'alter table public.zorvin_etapas add constraint zorvin_etapas_descricao_tamanho
               check (descricao is null or length(descricao) <= 500)';
  end if;
  if not exists (select 1 from pg_constraint where conname = 'zorvin_cartoes_ia_motivo_tamanho') then
    execute 'alter table public.zorvin_cartoes add constraint zorvin_cartoes_ia_motivo_tamanho
               check (ia_motivo is null or length(ia_motivo) <= 300)';
  end if;

  -- ----------------------------------------------------------
  --  2. OS GATILHOS DOS CARTÕES — versão de referência (a do 043, mais a IA)
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
      -- O QUE A IA FEZ, SÓ A PONTE ESCREVE (044). O painel grava como
      -- `authenticated`: o que ele mandar nessas duas colunas é desfeito, e a
      -- etapa que uma pessoa muda perde o motivo da IA.
      if current_user in ('authenticated', 'anon') then
        if tg_op = 'INSERT' then
          new.ia_motivo := null;
          new.ia_leu_ate := null;
        else
          new.ia_leu_ate := old.ia_leu_ate;
          new.ia_motivo := case when new.etapa_id is distinct from old.etapa_id
                                then null else old.ia_motivo end;
        end if;
      end if;
      return new;
    end
    $f$
  $x$;

  execute $x$
    create or replace function public.zorvin_cartao_historico()
    returns trigger language plpgsql security definer set search_path = public as $f$
    declare
      v_ia boolean;
    begin
      if tg_op = 'INSERT' then
        v_ia := auth.uid() is null and new.ia_motivo is not null;
        insert into public.zorvin_movimentos (contato_id, departamento_id, advogado_id, de_etapa, para_etapa, quem,
                                              pela_ia, motivo)
        values (new.contato_id, new.departamento_id, new.advogado_id, null, new.etapa_id, auth.uid(),
                v_ia, case when v_ia then new.ia_motivo end);
      elsif tg_op = 'UPDATE' then
        if new.etapa_id is distinct from old.etapa_id then
          v_ia := auth.uid() is null and new.ia_motivo is not null;
          insert into public.zorvin_movimentos (contato_id, departamento_id, advogado_id, de_etapa, para_etapa, quem,
                                                pela_ia, motivo)
          values (new.contato_id, new.departamento_id, new.advogado_id, old.etapa_id, new.etapa_id, auth.uid(),
                  v_ia, case when v_ia then new.ia_motivo end);
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
  --  3. LIGAR (OU DESLIGAR) A IA NUM FUNIL — só quem administra
  --
  --  O funil do departamento ganha a sua linha em `zorvin_funis` aqui, na
  --  primeira vez (advogado_id nulo — o 043 deixou o lugar para ela). O de um
  --  telefone tem de existir e estar em uso.
  --
  --  LIGAR, ou PASSAR DE NOVO, faz a IA ler todos os clientes do funil uma
  --  vez (`ia_leu_ate` volta a nulo). Desligar não desfaz nada do que ela
  --  fez: as etapas ficam, com o motivo, e o histórico também.
  --
  --  Devolve { ligada, clientes } — quantos clientes a IA vai ler (os que têm
  --  conversa por um telefone deste funil). A tela escreve esse número, e ele
  --  sai daqui.
  -- ----------------------------------------------------------
  for r in select p.oid::regprocedure as f from pg_proc p
            where p.proname = 'zorvin_ia_do_funil'
              and p.pronamespace = 'public'::regnamespace
  loop
    execute 'drop function ' || r.f;
  end loop;
  execute $x$
    create function public.zorvin_ia_do_funil(
      p_departamento bigint, p_telefone uuid default null,
      p_ligar boolean default true, p_de_novo boolean default false)
    returns jsonb
    language plpgsql security definer set search_path = public as $f$
    declare
      v_funil  uuid;
      v_dep    bigint;
      v_antes  boolean;
      v_n      integer := 0;
    begin
      if not coalesce(public.zorvin_admin(), false) then
        raise exception 'Só quem administra liga a IA no funil.' using errcode = '42501';
      end if;
      if p_telefone is not null then
        select f.id, f.departamento_id, f.ia_ligada into v_funil, v_dep, v_antes
          from public.zorvin_funis f where f.advogado_id = p_telefone and f.ativo;
        if v_funil is null then
          raise exception 'Este telefone usa o funil do departamento — ligue a IA por lá.' using errcode = '22023';
        end if;
      else
        if not exists (select 1 from public.departamentos d where d.id = p_departamento) then
          raise exception 'Este departamento não existe.' using errcode = '22023';
        end if;
        v_dep := p_departamento;
        select f.id, f.ia_ligada into v_funil, v_antes
          from public.zorvin_funis f where f.departamento_id = p_departamento and f.advogado_id is null;
      end if;

      -- SEM PARA ONDE MOVER, NÃO LIGA: com menos de duas etapas em uso a IA
      -- só teria a etapa de agora para escolher.
      if p_ligar and (select count(*) from public.zorvin_etapas e
                       where e.departamento_id = v_dep
                         and e.advogado_id is not distinct from p_telefone and e.ativo) < 2 then
        raise exception 'Este funil precisa de pelo menos duas etapas em uso para a IA ter para onde mover.'
          using errcode = '22023';
      end if;

      if v_funil is null then
        insert into public.zorvin_funis (departamento_id, advogado_id, ativo, criado_por, ia_ligada)
        values (v_dep, null, true, auth.uid(), false)
        returning id, ia_ligada into v_funil, v_antes;
      end if;

      update public.zorvin_funis
         set ia_ligada = p_ligar, ia_mudada_em = now(), ia_mudada_por = auth.uid()
       where id = v_funil;

      -- A PASSADA: ao ligar (quem estava desligado) ou ao pedir de novo.
      if p_ligar and (not coalesce(v_antes, false) or p_de_novo) then
        update public.zorvin_cartoes k
           set ia_leu_ate = null
         where k.departamento_id = v_dep
           and k.advogado_id is not distinct from p_telefone
           and k.ia_leu_ate is not null;
      end if;
      if p_ligar then
        select count(*) into v_n
          from public.zorvin_cartoes k
         where k.departamento_id = v_dep
           and k.advogado_id is not distinct from p_telefone
           and k.ia_leu_ate is null
           and exists (select 1 from public.conversas c
                         join public.advogados a on a.id = c.advogado_id
                        where c.contato_id = k.contato_id
                          and case when p_telefone is not null then c.advogado_id = p_telefone
                                   else a.departamento_id = v_dep
                                        and not exists (select 1 from public.zorvin_funis g
                                                         where g.advogado_id = a.id and g.ativo)
                              end)
           and not exists (select 1 from public.contatos ct
                            where ct.id = k.contato_id and ct.numero like 'grupo:%');
      end if;
      return jsonb_build_object('ligada', p_ligar, 'clientes', v_n);
    end
    $f$
  $x$;

  -- ----------------------------------------------------------
  --  4. O QUE A IA TEM PARA LER — só a ponte
  --
  --  A última atividade é a das conversas do cliente NOS TELEFONES DESTE
  --  FUNIL: o funil de um telefone, só ele; o do departamento, os telefones
  --  dele que não têm funil próprio (a regra do 043). `pessoa_decidiu_em` é
  --  quando uma pessoa MUDOU a etapa por último, ou nulo — a ponte diz isso à
  --  IA.
  -- ----------------------------------------------------------
  for r in select p.oid::regprocedure as f from pg_proc p
            where p.proname = 'zorvin_funil_para_a_ia'
              and p.pronamespace = 'public'::regnamespace
  loop
    execute 'drop function ' || r.f;
  end loop;
  execute $x$
    create function public.zorvin_funil_para_a_ia(p_limite integer default 5, p_quieto_min integer default 10)
    returns table (cartao_id uuid, contato_id uuid, departamento_id bigint, telefone_id uuid,
                   etapa_id uuid, movido_em timestamptz, pessoa_decidiu_em timestamptz,
                   ia_leu_ate timestamptz, ia_motivo text, ultima timestamptz, conversas uuid[])
    language sql stable security definer set search_path = public as $f$
      select k.id, k.contato_id, k.departamento_id, k.advogado_id, k.etapa_id, k.movido_em,
             case when k.movido_por is not null and k.movido_em > k.criado_em then k.movido_em end,
             k.ia_leu_ate, k.ia_motivo, u.ultima, u.conversas
        from public.zorvin_cartoes k
        join public.zorvin_funis f
          on f.ia_ligada
         and f.departamento_id = k.departamento_id
         and f.advogado_id is not distinct from k.advogado_id
         and (f.advogado_id is null or f.ativo)
        join public.contatos ct on ct.id = k.contato_id and ct.numero not like 'grupo:%'
        cross join lateral (
          select max(c.ultima_atividade) as ultima,
                 array_agg(c.id order by c.ultima_atividade desc nulls last) as conversas
            from public.conversas c
            join public.advogados a on a.id = c.advogado_id
           where c.contato_id = k.contato_id
             and case when k.advogado_id is not null then c.advogado_id = k.advogado_id
                      else a.departamento_id = k.departamento_id
                           and not exists (select 1 from public.zorvin_funis g
                                            where g.advogado_id = a.id and g.ativo)
                 end
        ) u
       where u.ultima is not null
         and u.ultima < now() - make_interval(mins => greatest(coalesce(p_quieto_min, 10), 0))
         and (k.ia_leu_ate is null or u.ultima > k.ia_leu_ate)
         and not (k.movido_por is not null and k.movido_em > k.criado_em and k.movido_em >= u.ultima)
       order by u.ultima desc, k.id
       limit greatest(least(coalesce(p_limite, 5), 50), 1)
    $f$
  $x$;

  -- ----------------------------------------------------------
  --  AS PERMISSÕES, num lugar só
  --
  --  Ligar a IA: quem entrou (a função confere se administra). O que a IA
  --  tem para ler: SÓ a ponte — ela devolve cliente de qualquer telefone, e
  --  aberta para quem entrou seria um atalho por cima das permissões.
  -- ----------------------------------------------------------
  foreach v_assin in array array[
    'public.zorvin_ia_do_funil(bigint, uuid, boolean, boolean)',
    'public.zorvin_funil_para_a_ia(integer, integer)'
  ] loop
    execute format('revoke all on function %s from public', v_assin);
    if v_anon then execute format('revoke all on function %s from anon', v_assin); end if;
    if v_srv then execute format('grant execute on function %s to service_role', v_assin); end if;
  end loop;
  if v_auth then
    execute 'revoke all on function public.zorvin_funil_para_a_ia(integer, integer) from authenticated';
    execute 'grant execute on function public.zorvin_ia_do_funil(bigint, uuid, boolean, boolean) to authenticated';
  end if;

  -- ----------------------------------------------------------
  --  A CONFERÊNCIA
  -- ----------------------------------------------------------
  insert into zorvin_conferencia_044
  select 'funis com a IA ligada'::text,
         (select count(*) from public.zorvin_funis where ia_ligada)::text
  union all
  select 'as colunas da IA existem',
         (exists (select 1 from information_schema.columns
                   where table_schema = 'public' and table_name = 'zorvin_cartoes' and column_name = 'ia_motivo')
          and exists (select 1 from information_schema.columns
                       where table_schema = 'public' and table_name = 'zorvin_cartoes' and column_name = 'ia_leu_ate')
          and exists (select 1 from information_schema.columns
                       where table_schema = 'public' and table_name = 'zorvin_movimentos' and column_name = 'pela_ia')
          and exists (select 1 from information_schema.columns
                       where table_schema = 'public' and table_name = 'zorvin_etapas' and column_name = 'descricao'))::text
  union all
  select 'só a ponte pergunta o que a IA tem para ler',
         (case when v_auth
               then not has_function_privilege('authenticated', 'public.zorvin_funil_para_a_ia(integer, integer)', 'execute')
               else true end
          and case when v_anon
                   then not has_function_privilege('anon', 'public.zorvin_ia_do_funil(bigint, uuid, boolean, boolean)', 'execute')
                   else true end)::text
  union all
  select 'quem entrou pode pedir para ligar a IA (a função confere se administra)',
         (case when v_auth
               then has_function_privilege('authenticated', 'public.zorvin_ia_do_funil(bigint, uuid, boolean, boolean)', 'execute')
               else true end)::text;
end
$ia$;

-- ----------------------------------------------------------
--  E A CONFERÊNCIA NO PAPEL DE QUEM ATENDE — a régua 4 do LEIA-ME: quem
--  entrou lê as colunas novas (o painel as pede pelo `*`), e a chave da IA.
-- ----------------------------------------------------------
do $conf$
declare
  v_resposta text;
begin
  if to_regclass('public.zorvin_funis') is null
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'zorvin_cartoes' and column_name = 'ia_motivo')
     or not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;
  begin
    perform set_config('role', 'authenticated', true);
    perform count(*), max(ia_leu_ate), max(ia_motivo) from public.zorvin_cartoes;
    perform count(*), bool_or(pela_ia), max(motivo) from public.zorvin_movimentos;
    perform count(*), max(descricao) from public.zorvin_etapas;
    perform count(*), bool_or(ia_ligada) from public.zorvin_funis;
    v_resposta := 'sim';
    execute 'reset role';
  exception when others then
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;
  insert into zorvin_conferencia_044 values ('quem entrou lê o que a IA fez', v_resposta);
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha.
select * from zorvin_conferencia_044;
