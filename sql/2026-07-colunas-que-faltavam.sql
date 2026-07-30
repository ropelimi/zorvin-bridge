-- ============================================================
--  AS COLUNAS QUE O PAINEL USA E O BANCO NUNCA TEVE.
--
--  Rode uma vez no Supabase do Zorvin:
--    Dashboard → SQL Editor → New query → cole tudo → Run
--
--  Pode rodar de novo sem medo.
-- ============================================================
--
--  POR QUE ESTE ARQUIVO EXISTE
--
--  O painel do Supabase estava marcando MILHARES de erros de Postgres por dia,
--  em fila constante, sem que nada aparecesse quebrado na tela. Os dois fatos
--  que explicam isso:
--
--  1. O painel tem recursos "opcionais" — "Fulano está atendendo", "está
--     digitando…" — escritos para não quebrar quando o SQL deles não foi
--     rodado: a consulta falha, o erro é ignorado, e o recurso fica dormente.
--
--  2. NENHUM arquivo SQL deste repositório jamais criou essas colunas.
--
--  Junte os dois com um relógio: enquanto uma conversa estivesse aberta, o
--  painel reescrevia `atendendo_em` DE 60 EM 60 SEGUNDOS, em cada aba aberta,
--  numa coluna que não existia. Duas pessoas com o Zorvin aberto o dia todo dão
--  algo perto de três mil erros por dia — que é a ordem de grandeza que apareceu
--  no relatório. Nada quebrava na tela, e por isso ninguém viu: o custo era o
--  log ficar inútil, porque um erro DE VERDADE se perderia no meio dessa fila.
--
--  O conserto tem duas metades, e as duas foram feitas:
--    - no código: cada recurso pergunta UMA vez; recusado, desliga até o
--      próximo F5 (ou restart da ponte), em vez de insistir para sempre;
--    - aqui: as colunas passam a existir, e aí os recursos simplesmente
--      funcionam, que é o que se queria desde o começo.
-- ------------------------------------------------------------


-- ------------------------------------------------------------
--  1. "FULANO ESTÁ ATENDENDO ESTA CONVERSA"
--
--  Evita duas pessoas respondendo a mesma conversa ao mesmo tempo. `atendendo_em`
--  é o pulso: o painel o renova a cada minuto e a tela considera "parado" quem
--  não dá sinal há alguns minutos — assim uma aba fechada no susto não deixa a
--  conversa travada com o nome de alguém para sempre.
-- ------------------------------------------------------------
alter table conversas add column if not exists atendendo_por text;
alter table conversas add column if not exists atendendo_em  timestamptz;


-- ------------------------------------------------------------
--  2. "ESTÁ DIGITANDO…"
--
--  Quem escreve é a ponte, ao receber o aviso de digitação do WhatsApp; o painel
--  só lê. Guarda ATÉ QUANDO vale, e não "quando começou": assim a informação
--  expira sozinha, sem depender de alguém mandar o aviso de que parou — que é o
--  aviso que costuma se perder.
-- ------------------------------------------------------------
alter table conversas add column if not exists digitando_ate timestamptz;


-- ------------------------------------------------------------
--  3. FIXAR CONVERSA NO TOPO
--
--  A lista é ordenada pela última mensagem: quem falou por último fica em cima.
--  É o certo no dia a dia e é exatamente o errado para as três ou quatro
--  conversas que precisam ficar à mão o tempo todo — elas descem sozinhas
--  conforme o resto do escritório conversa.
--
--  A marca é DA CONVERSA, não de quem fixou, e é de propósito: o Zorvin é
--  atendimento compartilhado, a conversa que importa hoje importa para a equipe
--  toda. Uma marca por pessoa pediria outra tabela e mais uma consulta em cada
--  carregamento da lista, para resolver um problema que este escritório não tem.
--
--  Sem `not null`: o `default false` já cobre as linhas de antes e as novas, e
--  uma coluna nula ordena junto com `false` do jeito que o painel usa. Ficar sem
--  a restrição evita que algum INSERT antigo que não cite a coluna passe a falhar.
-- ------------------------------------------------------------
alter table conversas add column if not exists fixada boolean default false;


-- ------------------------------------------------------------
--  4. CONFERÊNCIA
-- ------------------------------------------------------------
select column_name, data_type, column_default
  from information_schema.columns
 where table_schema = 'public' and table_name = 'conversas'
   and column_name in ('atendendo_por', 'atendendo_em', 'digitando_ate', 'fixada')
 order by column_name;
-- Esperado: quatro linhas.
--   atendendo_em  | timestamp with time zone |
--   atendendo_por | text                     |
--   digitando_ate | timestamp with time zone |
--   fixada        | boolean                  | false
