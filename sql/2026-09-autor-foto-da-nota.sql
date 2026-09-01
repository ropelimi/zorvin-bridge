-- ============================================================
--  A COLUNA `notas.autor_foto`, que o painel grava desde sempre
--  e que nunca existiu neste banco.
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  (Já foi rodada no banco do escritório em 01/09/2026. Este arquivo fica
--   para quem montar uma instalação nova, e para o registro.)
--
--  ------------------------------------------------------------
--  SEJA CLARO SOBRE O QUE ISTO RESOLVE
--
--  NÃO é o defeito de 01/09. Aquele era do painel, e está corrigido lá: uma
--  coluna que falta passa a custar UMA coluna, em vez de levar o processo e o
--  `autor_id` junto (PR #194 do zorvin-painel).
--
--  Vale a pena registrar como os dois se ligam, porque é uma lição sobre
--  tolerância. Esta coluna nunca existiu, o painel a gravava assim mesmo, e o
--  banco recusava. O painel tolerava a recusa — e a tolerância, mal escrita,
--  descartava junto o vínculo da nota com o processo. Resultado medido: 289
--  notas, ZERO com processo. Um recurso que a equipe usava todo dia e que
--  nunca funcionou uma vez sequer.
--
--  Ou seja: a coluna ausente era inofensiva; o CONTORNO dela é que custou o
--  recurso. Foi por isso que o conserto de verdade foi no painel, e não aqui.
--
--  ------------------------------------------------------------
--  O QUE ESTE ARQUIVO RESOLVE, e são duas coisas menores e reais
--
--   1. A PRIMEIRA NOTA DE CADA SESSÃO do navegador ainda custa uma gravação
--      recusada. O painel descobre que a coluna não existe, guarda isso e não
--      pergunta de novo — mas a descoberta custa uma ida ao banco e deixa uma
--      linha de ERRO no registro do Postgres. Com a coluna, some. Um dia de
--      escritório com várias abas são dezenas dessas linhas, no mesmo lugar
--      onde um erro DE VERDADE precisaria ser visto.
--
--   2. A FOTO DE QUEM ESCREVEU FICA GRAVADA NA NOTA. A tela mostra a foto de
--      HOJE, tirada de `usuarios` pelo `autor_id` — que é melhor e é o caminho
--      normal. Esta coluna é o ÚLTIMO recurso: a nota de alguém cuja conta foi
--      APAGADA, em que não há mais de onde tirar rosto nenhum.
--
--  ------------------------------------------------------------
--  E O QUE ELE NÃO FAZ
--
--  Não conserta nenhuma das 289 notas que já existem. A coluna nasce vazia
--  para todas, porque a foto daquele dia nunca foi guardada em lugar nenhum.
--  Não há o que recuperar, e fingir que há seria pior.
--
--  Pelo mesmo motivo, as notas antigas continuam sem `autor_id` e sem
--  processo. O que muda é dali para a frente.
-- ============================================================

alter table public.notas add column if not exists autor_foto text;

comment on column public.notas.autor_foto is
  'A foto de quem escreveu, no dia em que escreveu. É o ÚLTIMO recurso: a tela '
  'prefere a foto de hoje, buscada em usuarios pelo autor_id. Esta só aparece '
  'quando a conta de quem escreveu não existe mais.';


-- ------------------------------------------------------------
--  CONFERÊNCIA
--
--  `com autor_id` e `com processo` vêm ZERO num banco que viveu com o defeito:
--  são as notas antigas, e elas não têm conserto. O que prova que passou a
--  funcionar é escrever uma nota NOVA com processo vinculado e ver os dois
--  números subirem.
-- ------------------------------------------------------------
select 'coluna autor_foto' as item,
       (exists(select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'notas'
                  and column_name = 'autor_foto'))::text as situacao
union all
select 'notas no total',  (select count(*)::text        from public.notas)
union all
select 'com autor_id',    (select count(autor_id)::text from public.notas)
union all
select 'com processo',    (select count(processo_id)::text from public.notas);
