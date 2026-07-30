-- ============================================================
--  A TABELA `grupos` SAI DE VEZ — e com ela a etiqueta que ninguém criou.
--
--  Rode uma vez no Supabase do Zorvin, DEPOIS de:
--    1. 2026-07-sem-grupos.sql (tirou o grupo da PERMISSÃO), e
--    2. o deploy do painel e da Ponte que pararam de citar a tabela.
--
--    Dashboard → SQL Editor → New query → cole tudo → Run
--
--  Pode rodar de novo sem medo.
-- ============================================================
--
--  POR QUE AGORA
--
--  O `2026-07-sem-grupos.sql` tirou o grupo da permissão e escreveu, com todas
--  as letras, o que NÃO fazia: "não apaga a tabela `grupos` nem a coluna
--  `conversas.grupo_id`. Elas ficam, sem uso, até o painel parar de citá-las.
--  Apagar coluna que uma tela ainda lê derruba a tela."
--
--  O painel parou. Ele não desenha mais o selo do grupo na conversa, não mostra
--  mais as abas de filtro por grupo, e a tela de Departamentos não cria nem
--  renomeia grupo nenhum. A Ponte parou de gravar `conversas.grupo_id` a cada
--  mensagem. Este arquivo é a última parte, a que só podia vir depois.
--
--  E POR QUE ISSO IMPORTAVA
--
--  Na lista de conversas, o selo do grupo ficava idêntico às tags que a equipe
--  cria à mão — mesma forma, mesmo tamanho, mesma cor viva. A diferença é que
--  uma foi escolhida por alguém e a outra o sistema inventou: os grupos nasciam
--  de um INSERT da migração e de um gatilho que dava um balaio a todo
--  departamento novo. O pior deles, "Sem identificar", é o balaio de quem ainda
--  não tem ficha no cadastro — ou seja, caía em quase toda conversa. Uma
--  etiqueta dizendo "não sei" em cada linha da lista.
-- ------------------------------------------------------------


-- ------------------------------------------------------------
--  0. NA ORDEM CERTA, OU NÃO RODA
--
--  Se `permissoes.grupo_id` ainda existe, o passo anterior não foi dado: há
--  permissão viva apontando para grupo, e apagar a tabela agora tiraria acesso
--  de gente sem migrar nada. Parar aqui com um recado é melhor do que apagar
--  metade e deixar alguém sem enxergar conversa amanhã.
-- ------------------------------------------------------------
do $ordem$
begin
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'permissoes'
       and column_name = 'grupo_id')
  then
    raise exception 'Rode antes o 2026-07-sem-grupos.sql: ainda há permissão por grupo.';
  end if;
end $ordem$;


-- ------------------------------------------------------------
--  1. O GATILHO QUE CRIAVA GRUPO SOZINHO
--
--  Já sai no arquivo anterior; repetido aqui porque este precisa valer sozinho
--  em um banco que tenha recebido só parte da história.
-- ------------------------------------------------------------
drop trigger  if exists departamento_ganha_balaio on departamentos;
drop function if exists grupo_padrao_do_departamento();


-- ------------------------------------------------------------
--  2. A CONVERSA DEIXA DE APONTAR PARA GRUPO
--
--  `grupo_fixado` era "alguém moveu esta conversa à mão, não mexa" — respeito a
--  uma decisão que não existe mais, porque não há para onde mover.
-- ------------------------------------------------------------
drop index if exists conversas_grupo_idx;
alter table conversas drop column if exists grupo_id;
alter table conversas drop column if exists grupo_fixado;


-- ------------------------------------------------------------
--  3. A TABELA
--
--  Sem `cascade`: a esta altura não deve sobrar nada apontando para ela, e se
--  sobrar é melhor o banco reclamar do que apagar junto uma coisa que ninguém
--  lembrou de conferir.
-- ------------------------------------------------------------
drop table if exists grupos;


-- ------------------------------------------------------------
--  4. CONFERÊNCIA
-- ------------------------------------------------------------
select
  to_regclass('public.grupos')                                    as tabela_grupos,
  (select count(*) from information_schema.columns
    where table_schema = 'public' and table_name = 'conversas'
      and column_name in ('grupo_id', 'grupo_fixado'))            as colunas_na_conversa;
-- Esperado: tabela_grupos = (vazio) e colunas_na_conversa = 0.
