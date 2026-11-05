-- ============================================================
--  O COPILOTO APRENDE — com as conversas e com as correções da equipe
--
--  >>> A PONTE APLICA SOZINHA (sql/automaticos). <<<
--  Pode rodar de novo sem medo — a pasta inteira, na ordem (regra 5).
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido do Rodrigo em 05/11: "O Copiloto precisa ser mais inteligente e
--  sempre aprender [...] Faça ele ler todas as mensagens que temos no banco
--  de dados e aprender com as conversas, isso para cada departamento, cada
--  telefone." E o agente: a atendente pede uma mudança na sugestão ("não
--  podemos enviar o telefone do advogado"), o copiloto refaz a mensagem e
--  aprende a regra para o próximo cliente.
--
--  Decidido com ele: o que o copiloto aprende vale NA HORA (quem administra
--  vê tudo, corrige e apaga, e quem ensinou desfaz), e a correção vale para o
--  ESCRITÓRIO INTEIRO.
--
--  DUAS TABELAS:
--
--  `zorvin_copiloto_aprendido` — o que a ponte aprendeu lendo as conversas:
--  uma linha por telefone e uma por departamento. A ponte lê as mensagens em
--  pedaços, na ordem em que aconteceram, e reescreve as notas a cada pedaço.
--  `leu_ate` e `leu_ate_id` dizem até onde ela já leu (a hora e, para
--  desempatar as mensagens da mesma hora, o id).
--    - SÓ QUEM ADMINISTRA LÊ: as notas saem das conversas de todos os
--      telefones, e quem atende um telefone não lê o que se aprendeu nos
--      outros.
--    - PELA TELA, SÓ O TEXTO MUDA (corrigir, ou apagar escrevendo nada). Onde
--      a leitura está, só a ponte anda; começar do zero é a função
--      `zorvin_copiloto_ler_de_novo`, que confere quem administra.
--
--  `zorvin_copiloto_licoes` — as correções da equipe. Nasce pela ponte, na
--  rota que refaz a sugestão (`/copiloto/ajustar`), com quem ensinou: pela
--  tela ninguém cria lição. Quem entrou lê; quem administra corrige o texto;
--  quem administra e quem ensinou apagam.
--
--  QUEM CORRIGIU À MÃO E QUANDO são do gatilho, e não da tela (a régua do
--  024): `editado_por`/`editada_por` é a pessoa entrada no momento. A ponte
--  grava com a chave dela, sem pessoa, e não vira autora de nada.
--
--  E TRÊS FUNÇÕES:
--   - `zorvin_copiloto_para_aprender` — quem tem o que aprender agora. Só a
--     ponte chama. Ela também cria a linha do telefone e do departamento que
--     nasceram depois deste script.
--   - `zorvin_copiloto_pedaco` — o próximo pedaço de mensagens de uma linha.
--     Só a ponte chama: devolve mensagens de todos os telefones.
--   - `zorvin_copiloto_ler_de_novo` — começa a leitura de uma linha do zero.
--     Quem administra chama, pela tela.
--
--  O QUE A PONTE NÃO LÊ: as notas internas (a régua do copiloto: o que a
--  equipe escreve para não chegar ao cliente não vai parar perto de uma
--  sugestão), as mensagens apagadas, os avisos automáticos (037) e o que não
--  tem texto nem transcrição (a foto sem legenda, a figurinha).
--
--  O HISTÓRICO IMPORTADO DEPOIS fica de fora, e é decisão: a leitura anda pela
--  hora em que cada mensagem foi escrita, e uma mensagem antiga que entra hoje
--  (uma importação, um resgate) cai atrás do ponto onde a ponte já está.
--  Andar pela hora da gravação pediria uma coluna nova em `mensagens`, e as
--  mensagens de antes dela teriam todas a mesma hora, sem ordem nenhuma.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    `usuarios`, `conversas`, `mensagens`, `contatos`, `advogados`,
--    `departamentos`, `zorvin_admin()`, a transcrição (015) e o aviso
--    automático (037). Sem as tabelas, não faz nada e diz; sem as colunas de
--    `mensagens`, diz qual script falta.
-- ============================================================

do $aprende$
declare
  v_anon   boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_auth   boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_srv    boolean := exists (select 1 from pg_roles where rolname = 'service_role');
  v_faltam text;
  v_assin  text;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007:
  -- criada depois, o `select` da última linha estouraria num banco limpo.
  drop table if exists zorvin_conferencia_050;
  create temp table zorvin_conferencia_050 (item text, resposta text);

  if to_regclass('public.usuarios') is null or to_regclass('public.conversas') is null
     or to_regclass('public.mensagens') is null or to_regclass('public.contatos') is null
     or to_regclass('public.advogados') is null or to_regclass('public.departamentos') is null
     or to_regprocedure('public.zorvin_admin()') is null then
    insert into zorvin_conferencia_050 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 050 não fez nada.';
    return;
  end if;

  -- AS COLUNAS QUE AS FUNÇÕES LEEM. Uma função `language sql` tem o corpo
  -- conferido ao ser criada: com uma coluna faltando, o script inteiro
  -- voltaria atrás sem dizer qual. Aqui ele diz.
  select string_agg(col, ', ') into v_faltam
    from unnest(array['texto', 'tipo', 'origem', 'criado_em', 'transcricao', 'automatica',
                      'apagada', 'midia_nome', 'resposta_previa']) as col
   where not exists (select 1 from information_schema.columns
                      where table_schema = 'public' and table_name = 'mensagens' and column_name = col);
  if v_faltam is not null then
    insert into zorvin_conferencia_050
      values ('as colunas de mensagens que o copiloto lê',
              'NÃO — falta ' || v_faltam || ' (rode o script 015 e o 037 antes)');
    return;
  end if;

  -- ------------------------------------------------------------
  -- O QUE A PONTE APRENDEU LENDO AS CONVERSAS
  -- ------------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_copiloto_aprendido (
      id               uuid primary key default gen_random_uuid(),
      escopo           text not null check (escopo in ('telefone', 'departamento')),
      advogado_id      uuid references public.advogados(id) on delete cascade,
      departamento_id  bigint references public.departamentos(id) on delete cascade,
      texto            text not null default '' check (length(texto) <= 8000),
      leu_ate          timestamptz,
      leu_ate_id       uuid,
      mensagens_lidas  integer not null default 0 check (mensagens_lidas >= 0),
      aprendido_em     timestamptz,
      atualizado_em    timestamptz not null default now(),
      editado_por      uuid references public.usuarios(id) on delete set null,
      editado_em       timestamptz,
      constraint zorvin_copiloto_aprendido_escopo check (
        (escopo = 'telefone' and advogado_id is not null and departamento_id is null)
        or (escopo = 'departamento' and departamento_id is not null and advogado_id is null)),
      constraint zorvin_copiloto_aprendido_ponto check ((leu_ate is null) = (leu_ate_id is null))
    )
  $x$;
  execute $x$
    comment on table public.zorvin_copiloto_aprendido is
      'O que o copiloto aprendeu lendo as conversas: uma linha por telefone e uma por '
      'departamento. A ponte lê as mensagens em pedaços e reescreve o texto; leu_ate e '
      'leu_ate_id dizem até onde ela leu. Só quem administra lê, e pela tela só o texto muda.'
  $x$;
  execute 'create unique index if not exists zorvin_copiloto_aprendido_telefone
             on public.zorvin_copiloto_aprendido (advogado_id) where escopo = ''telefone''';
  execute 'create unique index if not exists zorvin_copiloto_aprendido_departamento
             on public.zorvin_copiloto_aprendido (departamento_id) where escopo = ''departamento''';

  -- QUEM CORRIGIU À MÃO E QUANDO: do gatilho. Começar do zero (a leitura
  -- volta a nulo) não é correção de ninguém.
  execute $x$
    create or replace function public.zorvin_copiloto_aprendido_quem() returns trigger
      language plpgsql set search_path = public, auth as $f$
    begin
      new.atualizado_em := now();
      if auth.uid() is not null and new.texto is distinct from old.texto
         and new.leu_ate is not distinct from old.leu_ate then
        new.editado_por := auth.uid();
        new.editado_em := now();
      end if;
      return new;
    end
    $f$
  $x$;
  execute 'drop trigger if exists zorvin_copiloto_aprendido_quem on public.zorvin_copiloto_aprendido';
  execute 'create trigger zorvin_copiloto_aprendido_quem before update on public.zorvin_copiloto_aprendido
             for each row execute function public.zorvin_copiloto_aprendido_quem()';

  execute 'alter table public.zorvin_copiloto_aprendido enable row level security';
  if v_auth then
    execute 'drop policy if exists zorvin_copiloto_aprendido_leitura on public.zorvin_copiloto_aprendido';
    execute 'create policy zorvin_copiloto_aprendido_leitura on public.zorvin_copiloto_aprendido
               for select to authenticated using (public.zorvin_admin())';
    execute 'drop policy if exists zorvin_copiloto_aprendido_texto on public.zorvin_copiloto_aprendido';
    execute 'create policy zorvin_copiloto_aprendido_texto on public.zorvin_copiloto_aprendido
               for update to authenticated using (public.zorvin_admin()) with check (public.zorvin_admin())';
    -- A HERANÇA SAI INTEIRA antes de dar só o que a tela usa: `truncate` não
    -- passa pela regra de acesso (a lição do 041), e mudar onde a leitura está
    -- é da ponte. O texto é a única coluna que a tela muda.
    execute 'revoke all on public.zorvin_copiloto_aprendido from authenticated';
    execute 'grant select, update (texto) on public.zorvin_copiloto_aprendido to authenticated';
  end if;
  if v_anon then
    execute 'revoke all on public.zorvin_copiloto_aprendido from anon';
  end if;
  if v_srv then
    execute 'grant all on public.zorvin_copiloto_aprendido to service_role';
  end if;

  -- AS LINHAS DE HOJE: cada telefone, e cada departamento que tem telefone. As
  -- de amanhã nascem em `zorvin_copiloto_para_aprender`, com o mesmo `insert`.
  insert into public.zorvin_copiloto_aprendido (escopo, advogado_id)
    select 'telefone', a.id from public.advogados a
     where not exists (select 1 from public.zorvin_copiloto_aprendido x
                        where x.escopo = 'telefone' and x.advogado_id = a.id)
  on conflict do nothing;
  insert into public.zorvin_copiloto_aprendido (escopo, departamento_id)
    select 'departamento', d.id from public.departamentos d
     where exists (select 1 from public.advogados a where a.departamento_id = d.id)
       and not exists (select 1 from public.zorvin_copiloto_aprendido x
                        where x.escopo = 'departamento' and x.departamento_id = d.id)
  on conflict do nothing;

  -- ------------------------------------------------------------
  -- AS LIÇÕES DAS CORREÇÕES
  -- ------------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_copiloto_licoes (
      id           uuid primary key default gen_random_uuid(),
      texto        text not null check (length(btrim(texto)) between 1 and 500),
      pedido       text check (pedido is null or length(pedido) <= 500),
      conversa_id  uuid references public.conversas(id) on delete set null,
      criada_por   uuid references public.usuarios(id) on delete set null,
      criada_em    timestamptz not null default now(),
      editada_por  uuid references public.usuarios(id) on delete set null,
      editada_em   timestamptz
    )
  $x$;
  execute $x$
    comment on table public.zorvin_copiloto_licoes is
      'As correções que a equipe fez nas sugestões do copiloto ("não passamos o telefone '
      'do advogado"). Valem para o escritório inteiro, na hora. Nascem pela ponte '
      '(/copiloto/ajustar), com quem ensinou; quem administra corrige e apaga, e quem '
      'ensinou apaga a sua.'
  $x$;
  execute 'create index if not exists zorvin_copiloto_licoes_recentes
             on public.zorvin_copiloto_licoes (criada_em desc)';

  execute $x$
    create or replace function public.zorvin_copiloto_licao_quem() returns trigger
      language plpgsql set search_path = public, auth as $f$
    begin
      if auth.uid() is not null and new.texto is distinct from old.texto then
        new.editada_por := auth.uid();
        new.editada_em := now();
      end if;
      return new;
    end
    $f$
  $x$;
  execute 'drop trigger if exists zorvin_copiloto_licao_quem on public.zorvin_copiloto_licoes';
  execute 'create trigger zorvin_copiloto_licao_quem before update on public.zorvin_copiloto_licoes
             for each row execute function public.zorvin_copiloto_licao_quem()';

  execute 'alter table public.zorvin_copiloto_licoes enable row level security';
  if v_auth then
    execute 'drop policy if exists zorvin_copiloto_licoes_leitura on public.zorvin_copiloto_licoes';
    execute 'create policy zorvin_copiloto_licoes_leitura on public.zorvin_copiloto_licoes
               for select to authenticated using (true)';
    execute 'drop policy if exists zorvin_copiloto_licoes_texto on public.zorvin_copiloto_licoes';
    execute 'create policy zorvin_copiloto_licoes_texto on public.zorvin_copiloto_licoes
               for update to authenticated using (public.zorvin_admin()) with check (public.zorvin_admin())';
    execute 'drop policy if exists zorvin_copiloto_licoes_apagar on public.zorvin_copiloto_licoes';
    execute 'create policy zorvin_copiloto_licoes_apagar on public.zorvin_copiloto_licoes
               for delete to authenticated using (public.zorvin_admin() or criada_por = auth.uid())';
    -- SEM INSERT PARA QUEM ENTROU: a lição nasce na rota da ponte, que diz
    -- quem ensinou. Pela tela, alguém poderia escrever uma "lição" em nome de
    -- outra pessoa.
    execute 'revoke all on public.zorvin_copiloto_licoes from authenticated';
    execute 'grant select, update (texto), delete on public.zorvin_copiloto_licoes to authenticated';
  end if;
  if v_anon then
    execute 'revoke all on public.zorvin_copiloto_licoes from anon';
  end if;
  if v_srv then
    execute 'grant all on public.zorvin_copiloto_licoes to service_role';
  end if;

  -- ------------------------------------------------------------
  -- QUEM TEM O QUE APRENDER AGORA (só a ponte)
  --
  -- Uma linha entra quando tem pelo menos `p_minimo` mensagens por ler, ou
  -- quando tem alguma e a última leitura dela passou de `p_horas`: depois da
  -- primeira passada, o copiloto não chama a IA a cada três mensagens novas.
  -- A conta para em `p_minimo` (o `limit`): ninguém precisa do número exato.
  -- Quem nunca leu vem primeiro, e depois quem leu há mais tempo — todo
  -- telefone e todo departamento andam juntos, e não um de cada vez.
  -- ------------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_copiloto_para_aprender(p_minimo integer default 150,
                                                                    p_horas integer default 24)
      returns table (id uuid, escopo text, advogado_id uuid, departamento_id bigint, pendentes integer,
                     texto text, leu_ate timestamptz, leu_ate_id uuid, mensagens_lidas integer,
                     aprendido_em timestamptz, atualizado_em timestamptz)
      language plpgsql security invoker set search_path = public as $f$
    #variable_conflict use_column
    declare
      v_min integer := greatest(1, least(coalesce(p_minimo, 150), 5000));
    begin
      insert into public.zorvin_copiloto_aprendido (escopo, advogado_id)
        select 'telefone', a.id from public.advogados a
         where not exists (select 1 from public.zorvin_copiloto_aprendido x
                            where x.escopo = 'telefone' and x.advogado_id = a.id)
      on conflict do nothing;
      insert into public.zorvin_copiloto_aprendido (escopo, departamento_id)
        select 'departamento', d.id from public.departamentos d
         where exists (select 1 from public.advogados a where a.departamento_id = d.id)
           and not exists (select 1 from public.zorvin_copiloto_aprendido x
                            where x.escopo = 'departamento' and x.departamento_id = d.id)
      on conflict do nothing;

      return query
      with contas as (
        select x.id, x.escopo, x.advogado_id, x.departamento_id, x.texto, x.leu_ate, x.leu_ate_id,
               x.mensagens_lidas, x.aprendido_em, x.atualizado_em,
               (select count(*)::integer from (
                  select 1
                    from public.mensagens m
                    join public.conversas c on c.id = m.conversa_id
                    join public.advogados a on a.id = c.advogado_id
                   where case when x.escopo = 'telefone' then c.advogado_id = x.advogado_id
                              else a.departamento_id = x.departamento_id end
                     and (x.leu_ate is null or (m.criado_em, m.id) > (x.leu_ate, x.leu_ate_id))
                     and not coalesce(m.apagada, false) and not coalesce(m.automatica, false)
                     and (btrim(coalesce(m.texto, '')) <> '' or btrim(coalesce(m.transcricao, '')) <> '')
                   limit v_min) z) as pend
          from public.zorvin_copiloto_aprendido x
      )
      select k.id, k.escopo, k.advogado_id, k.departamento_id, k.pend, k.texto, k.leu_ate, k.leu_ate_id,
             k.mensagens_lidas, k.aprendido_em, k.atualizado_em
        from contas k
       where k.pend >= v_min
          or (k.pend > 0 and (k.aprendido_em is null
                              or k.aprendido_em < now() - make_interval(hours => greatest(1, coalesce(p_horas, 24)))))
       order by k.aprendido_em asc nulls first, k.id;
    end
    $f$
  $x$;

  -- ------------------------------------------------------------
  -- O PRÓXIMO PEDAÇO DE UMA LINHA (só a ponte)
  --
  -- Na ordem em que as mensagens aconteceram, a partir de onde a leitura
  -- parou; o id desempata as da mesma hora (o álbum de fotos, o histórico
  -- importado com minuto cheio). O nome do telefone e se é grupo vão junto:
  -- num departamento, a ponte diz por qual telefone cada conversa é. O número
  -- do contato não sai daqui.
  -- ------------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_copiloto_pedaco(p_aprendido uuid, p_limite integer default 400)
      returns table (id uuid, conversa_id uuid, origem text, tipo text, texto text, transcricao text,
                     midia_nome text, resposta_previa text, criado_em timestamptz, telefone text,
                     grupo boolean)
      language sql stable security invoker set search_path = public as $f$
      select m.id, m.conversa_id, m.origem, m.tipo, m.texto, m.transcricao, m.midia_nome,
             m.resposta_previa, m.criado_em, a.nome, coalesce(ct.numero like 'grupo:%', false)
        from public.zorvin_copiloto_aprendido x
        join public.advogados a
          on case when x.escopo = 'telefone' then a.id = x.advogado_id
                  else a.departamento_id = x.departamento_id end
        join public.conversas c on c.advogado_id = a.id
        left join public.contatos ct on ct.id = c.contato_id
        join public.mensagens m on m.conversa_id = c.id
       where x.id = p_aprendido
         and (x.leu_ate is null or (m.criado_em, m.id) > (x.leu_ate, x.leu_ate_id))
         and not coalesce(m.apagada, false) and not coalesce(m.automatica, false)
         and (btrim(coalesce(m.texto, '')) <> '' or btrim(coalesce(m.transcricao, '')) <> '')
       order by m.criado_em, m.id
       limit greatest(1, least(coalesce(p_limite, 400), 1000))
    $f$
  $x$;

  -- ------------------------------------------------------------
  -- COMEÇAR DO ZERO (quem administra, pela tela)
  --
  -- Apaga o texto e volta a leitura ao começo: a próxima rodada da ponte lê
  -- aquele telefone ou departamento inteiro de novo. A ponte que estava no
  -- meio de um pedaço não grava por cima: ela confere `atualizado_em`, que
  -- esta gravação muda. Depois de começar do zero, não há correção de
  -- ninguém para mostrar.
  -- ------------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_copiloto_ler_de_novo(p_id uuid) returns boolean
      language plpgsql security definer set search_path = public as $f$
    declare
      v_n integer;
    begin
      if not coalesce(public.zorvin_admin(), false) then
        raise exception 'Só quem administra pede para o copiloto ler tudo de novo.' using errcode = '42501';
      end if;
      update public.zorvin_copiloto_aprendido
         set texto = '', leu_ate = null, leu_ate_id = null, mensagens_lidas = 0, aprendido_em = null
       where id = p_id;
      get diagnostics v_n = row_count;
      update public.zorvin_copiloto_aprendido set editado_por = null, editado_em = null where id = p_id;
      return v_n > 0;
    end
    $f$
  $x$;

  -- QUEM ALCANÇA CADA FUNÇÃO. As duas da leitura devolvem mensagens de todos
  -- os telefones: só a ponte. Os gatilhos disparam sem a permissão de
  -- executar (a nota do 032), e saem de todo mundo.
  foreach v_assin in array array['public.zorvin_copiloto_para_aprender(integer, integer)',
                                 'public.zorvin_copiloto_pedaco(uuid, integer)',
                                 'public.zorvin_copiloto_aprendido_quem()',
                                 'public.zorvin_copiloto_licao_quem()'] loop
    execute format('revoke all on function %s from public', v_assin);
    if v_anon then execute format('revoke all on function %s from anon', v_assin); end if;
    if v_auth then execute format('revoke all on function %s from authenticated', v_assin); end if;
  end loop;
  if v_srv then
    execute 'grant execute on function public.zorvin_copiloto_para_aprender(integer, integer) to service_role';
    execute 'grant execute on function public.zorvin_copiloto_pedaco(uuid, integer) to service_role';
  end if;
  execute 'revoke all on function public.zorvin_copiloto_ler_de_novo(uuid) from public';
  if v_anon then execute 'revoke all on function public.zorvin_copiloto_ler_de_novo(uuid) from anon'; end if;
  if v_auth then execute 'grant execute on function public.zorvin_copiloto_ler_de_novo(uuid) to authenticated'; end if;
  if v_srv then execute 'grant execute on function public.zorvin_copiloto_ler_de_novo(uuid) to service_role'; end if;

  -- ------------------------------------------------------------
  -- A CONFERÊNCIA
  -- ------------------------------------------------------------
  insert into zorvin_conferencia_050 values
    ('o que o copiloto aprende tem onde morar',
     (to_regclass('public.zorvin_copiloto_aprendido') is not null
      and to_regclass('public.zorvin_copiloto_licoes') is not null)::text),
    ('telefones prontos para a leitura',
     (select count(*) from public.zorvin_copiloto_aprendido where escopo = 'telefone')::text),
    ('departamentos prontos para a leitura',
     (select count(*) from public.zorvin_copiloto_aprendido where escopo = 'departamento')::text),
    ('mensagens que o copiloto vai ler',
     (select count(*) from public.mensagens m
       where not coalesce(m.apagada, false) and not coalesce(m.automatica, false)
         and (btrim(coalesce(m.texto, '')) <> '' or btrim(coalesce(m.transcricao, '')) <> ''))::text),
    ('lições que a equipe já ensinou',
     (select count(*) from public.zorvin_copiloto_licoes)::text);

  if v_auth then
    insert into zorvin_conferencia_050 values
      ('só a ponte pergunta quem tem o que aprender, e lê os pedaços',
       (not has_function_privilege('authenticated', 'public.zorvin_copiloto_para_aprender(integer, integer)', 'execute')
        and not has_function_privilege('authenticated', 'public.zorvin_copiloto_pedaco(uuid, integer)', 'execute'))::text),
      ('quem entrou não cria lição pela tela, e só muda o texto do que foi aprendido',
       (not has_table_privilege('authenticated', 'public.zorvin_copiloto_licoes', 'insert')
        and not has_table_privilege('authenticated', 'public.zorvin_copiloto_aprendido', 'insert')
        and not has_table_privilege('authenticated', 'public.zorvin_copiloto_aprendido', 'delete')
        and not has_column_privilege('authenticated', 'public.zorvin_copiloto_aprendido', 'leu_ate', 'update')
        and has_column_privilege('authenticated', 'public.zorvin_copiloto_aprendido', 'texto', 'update'))::text),
      ('quem administra pede para ler tudo de novo',
       has_function_privilege('authenticated', 'public.zorvin_copiloto_ler_de_novo(uuid)', 'execute')::text);
  end if;
  if v_anon then
    insert into zorvin_conferencia_050 values
      ('quem não entrou não alcança nada disto',
       (not has_table_privilege('anon', 'public.zorvin_copiloto_aprendido', 'select')
        and not has_table_privilege('anon', 'public.zorvin_copiloto_licoes', 'select')
        and not has_function_privilege('anon', 'public.zorvin_copiloto_ler_de_novo(uuid)', 'execute')
        and not has_function_privilege('anon', 'public.zorvin_copiloto_pedaco(uuid, integer)', 'execute'))::text);
  end if;
  if v_srv then
    insert into zorvin_conferencia_050 values
      ('a ponte pergunta e lê',
       (has_function_privilege('service_role', 'public.zorvin_copiloto_para_aprender(integer, integer)', 'execute')
        and has_function_privilege('service_role', 'public.zorvin_copiloto_pedaco(uuid, integer)', 'execute'))::text);
  end if;
end
$aprende$;

-- ----------------------------------------------------------
--  E A CONFERÊNCIA NO PAPEL DE QUEM ATENDE — a régua 4 do LEIA-ME. Quem não
--  administra não lê o que foi aprendido (zero linhas, sem erro) e lê as
--  lições; quem administra lê tudo. A troca de papel volta atrás sozinha.
-- ----------------------------------------------------------
do $conf$
declare
  v_admin   uuid;
  v_total   integer;
  v_viu     integer;
  v_resposta text;
begin
  if to_regclass('public.zorvin_copiloto_aprendido') is null
     or not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;
  select count(*) into v_total from public.zorvin_copiloto_aprendido;
  begin
    perform set_config('request.jwt.claim.sub', '', true);
    perform set_config('role', 'authenticated', true);
    execute 'select count(*) from public.zorvin_copiloto_aprendido' into v_viu;
    execute 'select count(*) from public.zorvin_copiloto_licoes';
    execute 'reset role';
    v_resposta := case when v_viu = 0 then 'true'
                       else 'NÃO — quem não administra leu ' || v_viu || ' linha(s) do que foi aprendido' end;
  exception when others then
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;
  insert into zorvin_conferencia_050 values
    ('quem atende lê as lições, e não o que foi aprendido nos telefones', v_resposta);

  select id into v_admin from public.usuarios where admin and coalesce(ativo, true) limit 1;
  if v_admin is null then
    return;
  end if;
  begin
    perform set_config('request.jwt.claim.sub', v_admin::text, true);
    perform set_config('role', 'authenticated', true);
    execute 'select count(*) from public.zorvin_copiloto_aprendido' into v_viu;
    execute 'reset role';
    perform set_config('request.jwt.claim.sub', '', true);
    v_resposta := case when v_viu = v_total then 'true'
                       else 'NÃO — quem administra leu ' || v_viu || ' de ' || v_total || ' linhas' end;
  exception when others then
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;
  insert into zorvin_conferencia_050 values
    ('quem administra lê o que foi aprendido em todos os telefones', v_resposta);
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_050;
