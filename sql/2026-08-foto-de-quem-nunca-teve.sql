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
--  ---------------------------------------------------------------
--  CORREÇÃO DA VERSÃO ANTERIOR DESTE ARQUIVO
--
--  Ela lia `notas.autor_foto`, e essa coluna NÃO EXISTE. Nunca existiu: o
--  painel tenta gravá-la e, quando o banco recusa, grava a nota sem ela — é
--  por isso que ninguém nunca percebeu.
--
--  E o estrago não ficou na metade das notas: o editor do Supabase roda tudo
--  numa transação só, então o erro derrubou junto o preenchimento pelas
--  MENSAGENS, que estava certo. Ninguém ficou com foto.
--
--  Agora cada metade só roda se as colunas de que ela precisa existirem, e o
--  fim diz o que rodou e o que foi pulado. Uma consulta que se escreve para
--  rodar "no banco de produção" tem de aguentar o banco de produção ser
--  diferente do que se imaginou.
--  ---------------------------------------------------------------
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
--  `distinct on (...)` com `order by ... criado_em desc` é o jeito do Postgres
--  de dizer "a linha mais recente de cada pessoa".
--
--  As duas metades vão dentro de um `do`, com a consulta montada em texto: sem
--  isso, o Postgres recusa o arquivo inteiro ao ANALISAR uma coluna que não
--  existe, mesmo que a linha nunca fosse rodar. É o que aconteceu.
-- ------------------------------------------------------------
do $$
declare
  tem_col boolean;
  quantas int;
begin
  -- ---- pelas MENSAGENS ----
  select count(*) = 2 into tem_col from information_schema.columns
   where table_schema = 'public' and table_name = 'mensagens'
     and column_name in ('enviado_por_id', 'enviado_por_foto');

  if tem_col then
    execute $q$
      with ultima_foto as (
        select distinct on (m.enviado_por_id)
               m.enviado_por_id as usuario_id, m.enviado_por_foto as foto
          from mensagens m
         where m.enviado_por_id is not null
           and m.enviado_por_foto is not null and m.enviado_por_foto <> ''
         order by m.enviado_por_id, m.criado_em desc
      )
      update usuarios u set foto_url = f.foto
        from ultima_foto f
       where u.id = f.usuario_id and u.foto_url is null
    $q$;
    get diagnostics quantas = row_count;
    raise notice 'pelas mensagens: % pessoa(s) ganharam foto', quantas;
  else
    raise notice 'pelas mensagens: PULADO (a tabela não tem as colunas)';
  end if;

  -- ---- pelas NOTAS ----
  --
  -- `notas.autor_foto` não existe nesta base, e é aqui que a versão anterior
  -- quebrava. Fica no arquivo porque a coluna pode existir noutra instalação —
  -- e porque, existindo, ela é a única fonte para quem só escreveu notas.
  select count(*) = 2 into tem_col from information_schema.columns
   where table_schema = 'public' and table_name = 'notas'
     and column_name in ('autor_id', 'autor_foto');

  if tem_col then
    execute $q$
      with ultima_foto as (
        select distinct on (n.autor_id)
               n.autor_id as usuario_id, n.autor_foto as foto
          from notas n
         where n.autor_id is not null
           and n.autor_foto is not null and n.autor_foto <> ''
         order by n.autor_id, n.criado_em desc
      )
      update usuarios u set foto_url = f.foto
        from ultima_foto f
       where u.id = f.usuario_id and u.foto_url is null
    $q$;
    get diagnostics quantas = row_count;
    raise notice 'pelas notas: % pessoa(s) ganharam foto', quantas;
  else
    raise notice 'pelas notas: PULADO (a tabela não guarda foto de autor)';
  end if;
end $$;


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
