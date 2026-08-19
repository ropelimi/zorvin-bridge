-- ============================================================
--  A FOTO DE QUEM FICOU SEM FOTO NO CADASTRO
--
--  O relato: a mesma pessoa aparece COM foto na lista de quem participou de
--  uma conversa e SEM foto na lista de outra.
--
--  A tela procura a foto em duas fontes, nesta ordem:
--
--    1. `usuarios.foto_url` — a foto de hoje, a mesma em toda conversa;
--    2. `mensagens.enviado_por_foto` — a cópia que viajou junto com AQUELA
--       mensagem, tirada no dia em que ela foi enviada.
--
--  Quem tem a primeira aparece igual em todo lugar. Quem NÃO tem cai na
--  segunda — e aí depende de qual mensagem está aberta: numa conversa a cópia
--  existe, na outra não, e a mesma pessoa aparece de dois jeitos.
--
--  Por que alguém ficaria sem a primeira? O preenchimento anterior copiou a
--  foto de `auth.users`, que é onde o painel a grava. Quem entrou por um
--  caminho que não passou por ali, ou trocou a foto antes de a coluna existir,
--  ficou de fora. Foram 16 de 21 no escritório — cinco pessoas.
--
--  A CÓPIA NAS MENSAGENS RESOLVE, e é uma fonte legítima: aquela foto foi
--  mesmo a foto da pessoa, num dia em que ela escreveu. Pega-se a mais
--  recente, que é a mais parecida com a de hoje.
--
--  Rodar no SQL Editor do Supabase. Seguro rodar de novo — só toca em quem
--  ainda está sem foto, então não atropela quem já trocou a dele.
-- ============================================================

set search_path = public;


-- ------------------------------------------------------------
--  ANTES — quantos estão sem foto
-- ------------------------------------------------------------
select count(*) filter (where foto_url is null) as sem_foto,
       count(*)                                 as no_total
  from usuarios;


-- ------------------------------------------------------------
--  O PREENCHIMENTO
--
--  `distinct on (enviado_por_id)` com `order by ... criado_em desc` é o jeito
--  do Postgres de dizer "a linha mais recente de cada pessoa" — e ele lê pelo
--  índice, em vez de ordenar a tabela inteira de mensagens.
-- ------------------------------------------------------------
with ultima_foto as (
  select distinct on (m.enviado_por_id)
         m.enviado_por_id as usuario_id,
         m.enviado_por_foto as foto
    from mensagens m
   where m.enviado_por_id is not null
     and m.enviado_por_foto is not null
     and m.enviado_por_foto <> ''
   order by m.enviado_por_id, m.criado_em desc
)
update usuarios u
   set foto_url = f.foto
  from ultima_foto f
 where u.id = f.usuario_id
   and u.foto_url is null;

-- E o mesmo pelas NOTAS, para quem só escreveu nota e nunca mensagem.
with ultima_foto as (
  select distinct on (n.autor_id)
         n.autor_id as usuario_id,
         n.autor_foto as foto
    from notas n
   where n.autor_id is not null
     and n.autor_foto is not null
     and n.autor_foto <> ''
   order by n.autor_id, n.criado_em desc
)
update usuarios u
   set foto_url = f.foto
  from ultima_foto f
 where u.id = f.usuario_id
   and u.foto_url is null;


-- ------------------------------------------------------------
--  CONFERÊNCIA — rode e leia
--
--  `sem_foto` são as pessoas que nunca tiveram foto nenhuma, em lugar nenhum.
--  Para elas continua a bolinha com as iniciais, que é o certo — e elas mesmas
--  resolvem em Configurações → Perfil, que agora vale para o histórico inteiro.
-- ------------------------------------------------------------
select count(*) filter (where foto_url is not null) as com_foto,
       count(*) filter (where foto_url is null)     as sem_foto,
       count(*)                                     as no_total
  from usuarios;

-- Quem continua sem foto, pelo nome — para saber a quem pedir.
select nome from usuarios where foto_url is null order by nome;
