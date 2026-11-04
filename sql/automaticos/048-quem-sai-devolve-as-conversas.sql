-- ============================================================
--  QUEM SAI DEVOLVE AS CONVERSAS E AS TAREFAS
--
--  >>> A PONTE APLICA SOZINHA (sql/automaticos). <<<
--  Pode rodar de novo sem medo — a pasta inteira, na ordem (regra 5).
--
--  ------------------------------------------------------------
--  O QUE ISTO FAZ
--
--  Pedido do Rodrigo em 04/11, logo depois de quem saiu deixar de aparecer
--  nas listas de escolher (047): "Quando alguém sai, as conversas e tarefas
--  abertas devem voltar para 'Sem responsável'."
--
--  Desligar alguém (`usuarios.ativo` de verdadeiro para falso) tirava o
--  acesso e deixava no nome da pessoa tudo o que era dela. E o aviso de
--  mensagem nova de uma conversa com responsável vai SÓ para o responsável
--  (painel, 13/10): o cliente dela escreveria, e ninguém seria avisado.
--
--  Agora, NO MESMO INSTANTE em que a pessoa é desligada:
--    - toda conversa em que ela é a responsável fica sem responsável — as
--      finalizadas e as arquivadas também (ver logo abaixo);
--    - toda tarefa ABERTA para ela fica sem dono. A concluída fica como está:
--      é o registro de quem a fez.
--  E quando ela é religada (o engano, ou a volta), recebe de volta o que
--  ninguém pegou nesse meio-tempo.
--
--  TAMBÉM AS FINALIZADAS E AS ARQUIVADAS, e não só as abertas. No Zorvin elas
--  não estão fechadas para sempre: o cliente que escreve reabre a finalizada
--  (028), e a arquivada recebe a mensagem e continua na pasta (04/11). No
--  nome de quem saiu, o aviso iria para ela quando o cliente voltasse — e ela
--  não entra mais. Quem finalizou e quem respondeu continuam onde sempre
--  estiveram (os atendimentos, os "Já tratei", as mensagens).
--
--  QUEM DECIDE É O BANCO, num gatilho em `usuarios`, e não a ponte. Há três
--  jeitos de desligar alguém: a ponte, quando a pessoa some do Vantoro
--  (`desligarQuemSaiuDoVantoro`); a chave "Conta ativa", sem Vantoro; e o SQL
--  à mão. O gatilho vale para os três, e uma regra escrita em cada caminho
--  divergiria no primeiro conserto.
--
--  O GATILHO AGE COMO DONO DO BANCO (`security definer`). Quem administra
--  pode desligar alguém pela própria sessão (a política `usuarios_admin`), e
--  nesse papel o registro do que foi devolvido não se alcança: sem o poder de
--  dono, a arrumação falharia calada justamente ali.
--
--  DESLIGAR NUNCA ESPERA POR ISTO. A chamada vive num `exception when
--  others`: se devolver falhar, a pessoa é desligada assim mesmo, e o banco
--  anota um aviso. Tirar o acesso de quem saiu vale mais do que a arrumação
--  das conversas dela.
--
--  O QUE FOI DEVOLVIDO FICA ANOTADO (`zorvin_devolvidas_na_saida`), com o
--  "desde quando" e o "quem pôs" de antes. É o que deixa a volta devolver
--  tudo igual, e é o rastro de "por que esta conversa ficou sem dono?". A
--  tabela é só do banco e da ponte: ninguém do painel a lê nem escreve nela.
--
--  NA VOLTA, só volta:
--    - o que continua sem dono: a conversa que um colega assumiu fica com ele;
--    - a tarefa que continua aberta;
--    - o que foi devolvido POR ÚLTIMO: se a mesma conversa foi devolvida por
--      duas pessoas, ela é da que saiu depois, e não da primeira que voltar.
--  E o registro daquela saída fecha, voltando ou não: uma próxima saída anota
--  de novo.
--
--  É UMA GRAVAÇÃO EM LOTE, como o "Marcar todas como lidas": cada conversa
--  devolvida é um aviso do tempo real para cada aba aberta do escritório.
--  Medido em 04/11, a maior carteira tinha 171 conversas.
--
--  QUEM JÁ TINHA SAÍDO ANTES DESTE SCRIPT também devolve, ao instalar. Medido
--  em 04/11: uma pessoa desativada, sem nenhuma conversa e sem nenhuma tarefa
--  aberta — no escritório, isso não muda nada.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    `usuarios.ativo`, o responsável pela conversa (008) e as tarefas (018).
--    Sem um deles, não faz nada e diz.
-- ============================================================

do $saida$
declare
  v_anon      boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_auth      boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_pessoa    record;
  v_devolvido jsonb;
  v_conversas bigint := 0;
  v_tarefas   bigint := 0;
  v_sequencia text;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007:
  -- criada depois, o `select` da última linha estouraria num banco limpo.
  drop table if exists zorvin_conferencia_048;
  create temp table zorvin_conferencia_048 (item text, resposta text);

  if to_regclass('public.usuarios') is null
     or to_regclass('public.conversas') is null
     or to_regclass('public.zorvin_tarefas') is null
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'usuarios'
                       and column_name = 'ativo')
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'conversas'
                       and column_name = 'responsavel_id') then
    insert into zorvin_conferencia_048
      values ('sem usuarios.ativo, o responsável (008) ou as tarefas (018)', 'nada a fazer aqui');
    raise notice 'Zorvin: sem usuarios.ativo, o responsável (008) ou as tarefas (018) — script 048 não fez nada.';
    return;
  end if;

  -- ----------------------------------------------------------
  --  O REGISTRO do que foi devolvido
  -- ----------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_devolvidas_na_saida (
      id               bigint generated always as identity primary key,
      pessoa_id        uuid not null references public.usuarios(id) on delete cascade,
      conversa_id      uuid references public.conversas(id) on delete cascade,
      tarefa_id        uuid references public.zorvin_tarefas(id) on delete cascade,
      responsavel_em   timestamptz,
      responsavel_por  uuid,
      devolvida_em     timestamptz not null default now(),
      voltou_em        timestamptz,
      constraint zorvin_devolvidas_uma_coisa_so
        check ((conversa_id is null) <> (tarefa_id is null))
    )
  $x$;
  execute $x$
    comment on table public.zorvin_devolvidas_na_saida is
      'O que voltou para "Sem responsável" quando a pessoa foi desligada: cada '
      'conversa (com o "desde quando" e o "quem pôs" de antes) e cada tarefa '
      'aberta. Quando ela é religada, o que ninguém pegou volta para ela, e o '
      'registro fecha (voltou_em). Só o banco e a ponte alcançam esta tabela.'
  $x$;
  execute 'create index if not exists zorvin_devolvidas_por_pessoa
             on public.zorvin_devolvidas_na_saida (pessoa_id) where voltou_em is null';
  execute 'create index if not exists zorvin_devolvidas_por_conversa
             on public.zorvin_devolvidas_na_saida (conversa_id, id) where conversa_id is not null';
  execute 'create index if not exists zorvin_devolvidas_por_tarefa
             on public.zorvin_devolvidas_na_saida (tarefa_id, id) where tarefa_id is not null';

  -- SÓ DO BANCO E DA PONTE: a regra de acesso ligada e nenhuma política, e a
  -- herança da Supabase (que dá tudo a quem entra) tirada — a armadilha nº 5.
  execute 'alter table public.zorvin_devolvidas_na_saida enable row level security';
  execute 'revoke all on public.zorvin_devolvidas_na_saida from public';
  v_sequencia := pg_get_serial_sequence('public.zorvin_devolvidas_na_saida', 'id');
  if v_anon then
    execute 'revoke all on public.zorvin_devolvidas_na_saida from anon';
    execute format('revoke all on sequence %s from anon', v_sequencia);
  end if;
  if v_auth then
    execute 'revoke all on public.zorvin_devolvidas_na_saida from authenticated';
    execute format('revoke all on sequence %s from authenticated', v_sequencia);
  end if;

  -- ----------------------------------------------------------
  --  DEVOLVER o que estava no nome de quem saiu
  --
  --  A conversa leva o "desde quando" e o "quem pôs" de antes para o registro
  --  — o `returning` de um `update` dá a linha NOVA, e é a subconsulta do
  --  `from` que guarda a de antes. Sem responsável é como o painel escreve
  --  "Deixar sem responsável": as três colunas nulas.
  --
  --  A condição vai NA gravação (`c.responsavel_id = p_pessoa`): a conversa
  --  que um colega assumiu no mesmo instante fica com ele, e não é anotada.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_devolver_o_que_era_de(p_pessoa uuid)
    returns jsonb language plpgsql set search_path = public, pg_temp as $f$
    declare
      v_conversas bigint := 0;
      v_tarefas   bigint := 0;
    begin
      with soltas as (
        update public.conversas c
           set responsavel_id = null, responsavel_em = null, responsavel_por = null
          from (select id, responsavel_em as em, responsavel_por as por
                  from public.conversas where responsavel_id = p_pessoa) antes
         where c.id = antes.id and c.responsavel_id = p_pessoa
        returning c.id, antes.em, antes.por
      )
      insert into public.zorvin_devolvidas_na_saida
             (pessoa_id, conversa_id, responsavel_em, responsavel_por)
      select p_pessoa, s.id, s.em, s.por from soltas s;
      get diagnostics v_conversas = row_count;

      with soltas as (
        update public.zorvin_tarefas t set para_quem = null
         where t.para_quem = p_pessoa and t.feita_em is null
        returning t.id
      )
      insert into public.zorvin_devolvidas_na_saida (pessoa_id, tarefa_id)
      select p_pessoa, s.id from soltas s;
      get diagnostics v_tarefas = row_count;

      return jsonb_build_object('conversas', v_conversas, 'tarefas', v_tarefas);
    end
    $f$
  $x$;
  execute $x$
    comment on function public.zorvin_devolver_o_que_era_de(uuid) is
      'Toda conversa em que a pessoa é a responsável fica sem responsável, e toda '
      'tarefa aberta dela fica sem dono, com registro. Chamada pelo gatilho de quem '
      'é desligado; ninguém do painel a chama.'
  $x$;

  -- ----------------------------------------------------------
  --  A VOLTA: o que ninguém pegou volta para quem voltou
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_devolver_a_quem_voltou(p_pessoa uuid)
    returns jsonb language plpgsql set search_path = public, pg_temp as $f$
    declare
      v_conversas bigint := 0;
      v_tarefas   bigint := 0;
    begin
      update public.conversas c
         set responsavel_id  = p_pessoa,
             responsavel_em  = coalesce(d.responsavel_em, now()),
             responsavel_por = d.responsavel_por
        from public.zorvin_devolvidas_na_saida d
       where d.pessoa_id = p_pessoa and d.voltou_em is null
         and d.conversa_id = c.id and c.responsavel_id is null
         and not exists (select 1 from public.zorvin_devolvidas_na_saida mais_nova
                          where mais_nova.conversa_id = d.conversa_id and mais_nova.id > d.id);
      get diagnostics v_conversas = row_count;

      update public.zorvin_tarefas t
         set para_quem = p_pessoa
        from public.zorvin_devolvidas_na_saida d
       where d.pessoa_id = p_pessoa and d.voltou_em is null
         and d.tarefa_id = t.id and t.para_quem is null and t.feita_em is null
         and not exists (select 1 from public.zorvin_devolvidas_na_saida mais_nova
                          where mais_nova.tarefa_id = d.tarefa_id and mais_nova.id > d.id);
      get diagnostics v_tarefas = row_count;

      -- O REGISTRO DESTA SAÍDA FECHA, voltando ou não: o que um colega pegou
      -- continua com ele, e uma próxima saída anota de novo.
      update public.zorvin_devolvidas_na_saida set voltou_em = now()
       where pessoa_id = p_pessoa and voltou_em is null;

      return jsonb_build_object('conversas', v_conversas, 'tarefas', v_tarefas);
    end
    $f$
  $x$;
  execute $x$
    comment on function public.zorvin_devolver_a_quem_voltou(uuid) is
      'Quem é religado recebe de volta as conversas e as tarefas abertas que '
      'voltaram para "Sem responsável" quando saiu, se ninguém as pegou. Chamada '
      'pelo gatilho; ninguém do painel a chama.'
  $x$;

  -- ----------------------------------------------------------
  --  O GATILHO
  --
  --  SÓ O FALSO DESLIGA, a régua de toda a ponte: o nulo é "ninguém disse".
  --  E o `when` deixa de fora a gravação que não muda nada — a entrada de cada
  --  pessoa regrava a linha dela com o mesmo `ativo`.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_quem_sai_devolve()
    returns trigger language plpgsql security definer set search_path = public, pg_temp as $f$
    begin
      if new.ativo is false and old.ativo is not false then
        begin
          perform public.zorvin_devolver_o_que_era_de(new.id);
        exception when others then
          raise warning 'Zorvin: % foi desligado, e as conversas e tarefas dele NÃO voltaram para "Sem responsável" (%: %)',
            new.id, sqlstate, sqlerrm;
        end;
      elsif old.ativo is false and new.ativo is not false then
        begin
          perform public.zorvin_devolver_a_quem_voltou(new.id);
        exception when others then
          raise warning 'Zorvin: % foi religado, e o que era dele NÃO voltou (%: %)',
            new.id, sqlstate, sqlerrm;
        end;
      end if;
      return null;
    end
    $f$
  $x$;
  execute 'drop trigger if exists zorvin_quem_sai_devolve on public.usuarios';
  execute 'create trigger zorvin_quem_sai_devolve
             after update of ativo on public.usuarios
             for each row
             when (old.ativo is distinct from new.ativo)
             execute function public.zorvin_quem_sai_devolve()';

  -- NINGUÉM DO PAINEL CHAMA ESTAS FUNÇÕES. O gatilho dispara sem a permissão
  -- de executar (o Postgres a confere ao criar o gatilho, e não ao disparar —
  -- a nota do 032), e quem entra não pode devolver as conversas de um colega
  -- por uma porta de dono.
  execute 'revoke all on function public.zorvin_devolver_o_que_era_de(uuid) from public';
  execute 'revoke all on function public.zorvin_devolver_a_quem_voltou(uuid) from public';
  execute 'revoke all on function public.zorvin_quem_sai_devolve() from public';
  if v_anon then
    execute 'revoke all on function public.zorvin_devolver_o_que_era_de(uuid) from anon';
    execute 'revoke all on function public.zorvin_devolver_a_quem_voltou(uuid) from anon';
    execute 'revoke all on function public.zorvin_quem_sai_devolve() from anon';
  end if;
  if v_auth then
    execute 'revoke all on function public.zorvin_devolver_o_que_era_de(uuid) from authenticated';
    execute 'revoke all on function public.zorvin_devolver_a_quem_voltou(uuid) from authenticated';
    execute 'revoke all on function public.zorvin_quem_sai_devolve() from authenticated';
  end if;

  -- ----------------------------------------------------------
  --  QUEM JÁ TINHA SAÍDO devolve agora. Sem o `exception` do gatilho, de
  --  propósito: um defeito aqui tem de aparecer na instalação, e não sumir.
  -- ----------------------------------------------------------
  for v_pessoa in select id from public.usuarios where ativo is false loop
    v_devolvido := public.zorvin_devolver_o_que_era_de(v_pessoa.id);
    v_conversas := v_conversas + coalesce((v_devolvido ->> 'conversas')::bigint, 0);
    v_tarefas := v_tarefas + coalesce((v_devolvido ->> 'tarefas')::bigint, 0);
  end loop;

  -- ----------------------------------------------------------
  --  A CONFERÊNCIA
  -- ----------------------------------------------------------
  insert into zorvin_conferencia_048 values
    ('quem é desligado devolve as conversas e as tarefas abertas',
     exists (select 1 from pg_trigger
              where tgname = 'zorvin_quem_sai_devolve'
                and tgrelid = 'public.usuarios'::regclass and not tgisinternal)::text),
    ('o gatilho age como dono do banco (vale também para quem desliga pela tela)',
     (select p.prosecdef from pg_proc p
       where p.oid = 'public.zorvin_quem_sai_devolve()'::regprocedure)::text),
    ('conversas que voltaram agora para "Sem responsável", de quem já tinha saído',
     v_conversas::text),
    ('tarefas abertas que voltaram agora para "Sem dono", de quem já tinha saído',
     v_tarefas::text),
    ('nenhuma conversa no nome de quem saiu',
     (not exists (select 1 from public.conversas c
                    join public.usuarios u on u.id = c.responsavel_id
                   where u.ativo is false))::text),
    ('nenhuma tarefa aberta no nome de quem saiu',
     (not exists (select 1 from public.zorvin_tarefas t
                    join public.usuarios u on u.id = t.para_quem
                   where u.ativo is false and t.feita_em is null))::text),
    ('o registro do que foi devolvido tem a regra de acesso ligada',
     (select c.relrowsecurity from pg_class c
       where c.oid = 'public.zorvin_devolvidas_na_saida'::regclass)::text);

  -- QUEM ALCANÇA O QUÊ, perguntado ao banco — e não chamando: a chamada pode
  -- estourar por outro motivo (a lição do 041).
  if v_auth then
    insert into zorvin_conferencia_048 values
      ('quem entrou não lê nem escreve o registro, e não chama as funções de devolver',
       (not has_table_privilege('authenticated', 'public.zorvin_devolvidas_na_saida', 'select')
        and not has_table_privilege('authenticated', 'public.zorvin_devolvidas_na_saida', 'insert')
        and not has_table_privilege('authenticated', 'public.zorvin_devolvidas_na_saida', 'update')
        and not has_table_privilege('authenticated', 'public.zorvin_devolvidas_na_saida', 'delete')
        and not has_function_privilege('authenticated', 'public.zorvin_devolver_o_que_era_de(uuid)', 'execute')
        and not has_function_privilege('authenticated', 'public.zorvin_devolver_a_quem_voltou(uuid)', 'execute'))::text);
  end if;
  if v_anon then
    insert into zorvin_conferencia_048 values
      ('quem não entrou não alcança o registro nem as funções de devolver',
       (not has_table_privilege('anon', 'public.zorvin_devolvidas_na_saida', 'select')
        and not has_table_privilege('anon', 'public.zorvin_devolvidas_na_saida', 'insert')
        and not has_function_privilege('anon', 'public.zorvin_devolver_o_que_era_de(uuid)', 'execute')
        and not has_function_privilege('anon', 'public.zorvin_devolver_a_quem_voltou(uuid)', 'execute'))::text);
  end if;
end
$saida$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_048;
