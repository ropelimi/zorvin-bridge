-- ============================================================
--  O REPASSE, E A LISTA DO "JÁ TRATEI" EM ORDEM ALFABÉTICA
--
--  Pedido do Rodrigo em 14/10: "No 'Já tratei' crie a opção 'REPASSE'. E
--  deixe tudo em ordem alfabética."
--
--  ------------------------------------------------------------
--  QUEM MANTÉM A ORDEM É O BANCO, e não cada tela
--
--  A lista aparece em quatro lugares: a janela do "Já tratei", a
--  administração, o histórico do cliente e o relatório. Os quatro já leem
--  `zorvin_assuntos.ordem`. Então a ordem alfabética mora AQUI, numa função
--  só, e um gatilho a refaz quando um assunto nasce ou muda de nome: o
--  assunto criado amanhã pela tela vai sozinho para o lugar dele, sem
--  nenhuma tela precisar saber disso. Ordenar em cada tela seria a mesma
--  regra escrita quatro vezes, para divergirem no primeiro conserto.
--
--  `ordem` deixa de ser "a ordem em que foram criados" e passa a ser a
--  posição alfabética. A tela nunca ofereceu mudá-la à mão, então ninguém
--  perde uma escolha.
--
--  ------------------------------------------------------------
--  "TUDO" INCLUI O OUTROS
--
--  O costume seria deixá-lo no fim, mas o pedido foi "tudo em ordem
--  alfabética": ele fica entre DOCUMENTOS JG e REPASSE. Deixar no fim "o
--  assunto que se chama OUTROS" seria uma segunda regra, presa a um nome que
--  quem compra o programa pode trocar — a mesma razão de a descrição
--  obrigatória ser uma MARCA (009), e não o nome.
--
--  ------------------------------------------------------------
--  A CHAVE DA ORDEM: maiúscula, minúscula e acento não decidem
--
--  "SUBSÍDIO" e "Subsidio" ficam juntos. O acento sai por `translate` e a
--  caixa por `lower`, NESSA ordem: `lower` num banco de collation "C" não
--  baixa letra acentuada. O resultado é comparado em "C", byte a byte, e a
--  ordem não depende da collation do banco — que a Supabase escolhe e a
--  prova não tem como imitar. Dois nomes que só diferem no acento desempatam
--  pelo nome e, por fim, pelo id: a mesma lista dá sempre a mesma ordem.
--
--  Ativos e desativados entram na MESMA conta: a administração mostra os
--  desativados no fim (ela ordena por `ativo` antes), e o relatório lista
--  assuntos de cliques antigos, que podem estar desativados.
--
--  ------------------------------------------------------------
--  O GATILHO
--
--  De instrução, e não de linha: um `insert` de vários assuntos refaz a ordem
--  uma vez. Dispara em `insert` e em `update` do NOME — desativar, reativar
--  ou ligar "pede descrição" não mudam a posição de ninguém. A renumeração só
--  mexe em `ordem`, então não dispara a si mesma.
--
--  Roda com os poderes de quem mexeu (`security invoker`): só quem
--  administra cria ou renomeia assunto (as políticas do 005), e é com essa
--  mesma permissão que as posições são refeitas. Quem não administra e tenta
--  renomear não muda linha nenhuma, e a renumeração dele também não. Uma
--  trava de transação põe em fila duas renumerações ao mesmo tempo: sem ela,
--  dois assuntos criados no mesmo segundo teriam as posições calculadas cada
--  uma sem ver o outro.
--
--  ------------------------------------------------------------
--  O REPASSE SÓ NASCE NA RODADA QUE CRIA A ORDEM — regra 5 do LEIA-ME
--
--  Rodar a pasta de novo depois de o escritório ter desativado ou renomeado
--  o REPASSE não pode trazê-lo de volta. A âncora é a função da ordem, que
--  não existia antes deste script. E, como o OUTROS do 009, um REPASSE que já
--  esteja ATIVO (criado à mão pela tela) é aproveitado, em vez de nascer um
--  segundo.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    005 — a tabela dos assuntos. Sem ela, desiste em silêncio.
-- ============================================================

do $repasse$
declare
  v_primeira boolean := to_regprocedure('public.zorvin_ordenar_assuntos()') is null;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007:
  -- criada depois, o `select` da última linha estouraria num banco limpo.
  drop table if exists zorvin_conferencia_025;
  create temp table zorvin_conferencia_025 (item text, resposta text);

  if to_regclass('public.zorvin_assuntos') is null then
    insert into zorvin_conferencia_025
      values ('sem a tabela dos assuntos', 'rode o script 005 antes');
    raise notice 'Zorvin: sem zorvin_assuntos — script 025 não fez nada. Rode o 005 antes.';
    return;
  end if;

  -- A CHAVE: sem acento, sem caixa e sem os espaços das pontas.
  execute $f$
    create or replace function public.zorvin_chave_do_assunto(p_nome text) returns text
      language sql immutable set search_path = public as $c$
      select lower(translate(btrim(coalesce(p_nome, '')),
                             'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑáàâãäéèêëíìîïóòôõöúùûüçñ',
                             'AAAAAEEEEIIIIOOOOOUUUUCNaaaaaeeeeiiiiooooouuuucn'))
    $c$
  $f$;

  -- A ORDEM, numa função só. Muda só quem saiu do lugar.
  execute $f$
    create or replace function public.zorvin_ordenar_assuntos() returns void
      language plpgsql security invoker set search_path = public as $c$
    begin
      perform pg_advisory_xact_lock(hashtextextended('zorvin_ordenar_assuntos', 0));
      update public.zorvin_assuntos a
         set ordem = x.posicao
        from (select s.id,
                     row_number() over (
                       order by public.zorvin_chave_do_assunto(s.nome) collate "C",
                                s.nome collate "C", s.id) as posicao
                from public.zorvin_assuntos s) x
       where a.id = x.id
         and a.ordem is distinct from x.posicao;
    end
    $c$
  $f$;

  execute $f$
    create or replace function public.zorvin_assuntos_em_ordem() returns trigger
      language plpgsql security invoker set search_path = public as $c$
    begin
      perform public.zorvin_ordenar_assuntos();
      return null;
    end
    $c$
  $f$;
  -- QUEM PODE CHAMAR, escrito como no 017 e no 023: ninguém por padrão, e
  -- `authenticated` (e a ponte) nominalmente. O gatilho roda no papel de quem
  -- administra, e as funções que ele chama também — sem EXECUTE para
  -- `authenticated`, criar um assunto pela tela passaria a falhar inteiro.
  -- A função do gatilho não precisa de concessão: disparar não pede EXECUTE.
  execute 'revoke all on function public.zorvin_chave_do_assunto(text) from public';
  execute 'revoke all on function public.zorvin_ordenar_assuntos() from public';
  execute 'revoke all on function public.zorvin_assuntos_em_ordem() from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.zorvin_chave_do_assunto(text),
                                    public.zorvin_ordenar_assuntos(),
                                    public.zorvin_assuntos_em_ordem() from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.zorvin_chave_do_assunto(text),
                                       public.zorvin_ordenar_assuntos() to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.zorvin_chave_do_assunto(text),
                                       public.zorvin_ordenar_assuntos() to service_role';
  end if;

  execute 'drop trigger if exists zorvin_assuntos_em_ordem on public.zorvin_assuntos';
  execute 'create trigger zorvin_assuntos_em_ordem
             after insert or update of nome on public.zorvin_assuntos
             for each statement execute function public.zorvin_assuntos_em_ordem()';

  -- O REPASSE, depois do gatilho: ele já nasce no lugar dele.
  if v_primeira and not exists (select 1 from public.zorvin_assuntos
                                 where ativo and lower(btrim(nome)) = 'repasse') then
    insert into public.zorvin_assuntos (nome) values ('REPASSE');
  end if;

  -- A LISTA DE HOJE, de uma vez.
  perform public.zorvin_ordenar_assuntos();

  -- ----------------------------------------------------------
  --  A CONFERÊNCIA VAI DENTRO DO SCRIPT, e é a última linha dele.
  -- ----------------------------------------------------------
  --  O REPASSE QUE FALTA SÓ É DEFEITO NA PRIMEIRA RODADA. Numa rodada de
  --  novo, faltar quer dizer que o escritório o tirou de uso ou o renomeou
  --  pela tela — e a resposta diz isso sem pintar de vermelho uma escolha.
  insert into zorvin_conferencia_025
  select 'o REPASSE está na lista do “Já tratei”',
         case
           when exists (select 1 from public.zorvin_assuntos
                         where ativo and lower(btrim(nome)) = 'repasse') then 'true'
           when v_primeira then 'NÃO — o REPASSE não foi criado'
           else 'fora de uso ou renomeado pela tela — rodar de novo não o traz de volta'
         end
  union all
  select 'a lista está em ordem alfabética',
         (not exists (
            select 1
              from (select s.ordem,
                           row_number() over (
                             order by public.zorvin_chave_do_assunto(s.nome) collate "C",
                                      s.nome collate "C", s.id) as posicao
                      from public.zorvin_assuntos s) x
             where x.ordem is distinct from x.posicao))::text
  union all
  select 'os assuntos em uso, na ordem',
         (select string_agg(nome, ', ' order by ordem)
            from public.zorvin_assuntos where ativo);
end
$repasse$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_025;
