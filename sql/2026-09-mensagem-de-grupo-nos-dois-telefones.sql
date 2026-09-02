-- ============================================================
--  A MESMA MENSAGEM DE GRUPO, NOS DOIS TELEFONES QUE ESTÃO NELE
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--
--  ------------------------------------------------------------
--  O RELATO, com dois prints, em 02/09
--
--  O grupo "Suporte Legal Mail - Max Canaverde" tem DOIS telefones nossos
--  dentro: o do Dr. Max e o do Estratégico. Abrindo a mesma conversa por um e
--  por outro, as mensagens são DIFERENTES — e não se repetem:
--
--     17:30  só no Estratégico   Eduarda: "esse processo foi excluído hoje…"
--     17:45  só no Max           Estratégico: "Bem e você?"
--     17:46  só no Estratégico   "@100236… podemos excluir essa regra…"
--     17:55  só no Estratégico   "Excluir esse regra"
--     18:04  só no Max           Eduarda: "Podemos excluir essa regra…"
--     14:51  só no Max           Estratégico: "pode excluir essa regra…"
--
--  Cada lado tem um pedaço da discussão, e nenhum tem a conversa inteira. Até a
--  última mensagem da lista é outra em cada telefone.
--
--  ------------------------------------------------------------
--  A CAUSA, medida
--
--      CREATE UNIQUE INDEX mensagens_id_uazapi_key
--        ON public.mensagens USING btree (id_uazapi);
--
--  `id_uazapi` é o identificador que o WhatsApp dá à mensagem, e ele é ÚNICO NO
--  BANCO INTEIRO. Isso está certo enquanto cada mensagem chega a um telefone
--  nosso só. Num grupo com dois dos nossos, a MESMA mensagem chega DUAS vezes —
--  uma por telefone — com o MESMO identificador.
--
--  A ponte grava com `ignoreDuplicates`. A primeira que chega entra, na conversa
--  daquele telefone; a segunda bate no índice e é descartada. Em silêncio: há
--  no código um aviso para "duas mensagens diferentes com a mesma chave", e ele
--  se cala justamente quando o texto é igual — que é o caso aqui.
--
--  ------------------------------------------------------------
--  O CONSERTO: a unicidade passa a ser POR CONVERSA
--
--  A pergunta que o índice responde deixa de ser "esta mensagem já existe no
--  Zorvin?" e passa a ser "esta mensagem já existe NESTA conversa?" — que é a
--  pergunta certa. Cada telefone nosso tem a sua caixa; a mesma mensagem do
--  WhatsApp legitimamente aparece nas duas quando os dois estão no grupo.
--
--  TROCAR DE GLOBAL PARA COMPOSTO NÃO PODE FALHAR POR DADO EXISTENTE: o índice
--  global é MAIS ESTRITO que o composto, então tudo o que cabia nele cabe no
--  novo. Não há linha a corrigir antes.
--
--  E A ORDEM IMPORTA: o novo é criado ANTES de o antigo sair. Entre um comando
--  e outro chega mensagem, e um instante sem índice nenhum é um instante em que
--  a repetição de verdade (o mesmo webhook entregue duas vezes) entra duplicada
--  na tela.
--
--  ------------------------------------------------------------
--  O QUE ISTO NÃO FAZ
--
--  Não devolve o que já se perdeu. As mensagens descartadas nunca foram
--  gravadas — não há de onde tirá-las aqui dentro. Elas continuam existindo no
--  WhatsApp, e a ponte sabe reler o histórico de uma conversa pela Uazapi: é
--  por ali que o passado volta, e não por SQL.
-- ============================================================

-- ------------------------------------------------------------
--  1) O RETRATO DE ANTES — rode e guarde.
-- ------------------------------------------------------------
select indexname as indice, indexdef as definicao
  from pg_indexes
 where schemaname = 'public' and tablename = 'mensagens'
   and indexdef ilike '%id_uazapi%';

-- Quantas mensagens existem hoje, para conferir depois que nenhuma sumiu.
select count(*) as mensagens, count(distinct id_uazapi) as identificadores
  from public.mensagens;


-- ------------------------------------------------------------
--  2) A TROCA
--
--     `concurrently` está DE FORA de propósito: ele não roda dentro de uma
--     transação, e o editor do Supabase envolve tudo numa. Com a tabela no
--     tamanho desta (dezenas de milhares de linhas), a criação leva segundos e
--     as mensagens que chegarem nesse intervalo ESPERAM e entram — `create
--     index` bloqueia a gravação, não a rejeita.
-- ------------------------------------------------------------
create unique index if not exists mensagens_conversa_id_uazapi_key
  on public.mensagens (conversa_id, id_uazapi);

drop index if exists public.mensagens_id_uazapi_key;


-- ------------------------------------------------------------
--  3) O RETRATO DE DEPOIS
--
--     `identificadores` pode ficar MENOR que `mensagens` daqui para a frente —
--     é justamente isso que o conserto permite: o mesmo identificador em duas
--     conversas. Hoje, logo depois de rodar, os dois números continuam iguais.
-- ------------------------------------------------------------
select indexname as indice, indexdef as definicao
  from pg_indexes
 where schemaname = 'public' and tablename = 'mensagens'
   and indexdef ilike '%id_uazapi%';

select count(*) as mensagens, count(distinct id_uazapi) as identificadores
  from public.mensagens;


-- ------------------------------------------------------------
--  COMO DESFAZER
--
--  Só é possível enquanto nenhuma mensagem de grupo tiver sido gravada duas
--  vezes — depois disso o índice global não pode mais ser criado, e forçá-lo
--  significaria APAGAR as cópias. A consulta abaixo diz se ainda dá:
--
--    select count(*) from (
--      select id_uazapi from public.mensagens
--       group by id_uazapi having count(*) > 1) x;
--
--  Se der zero:
--    create unique index mensagens_id_uazapi_key on public.mensagens (id_uazapi);
--    drop index public.mensagens_conversa_id_uazapi_key;
-- ------------------------------------------------------------
