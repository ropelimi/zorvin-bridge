-- ============================================================
--  O GRUPO INTEIRO EM CADA CAIXA — a metade que ficou para trás
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--
--  ------------------------------------------------------------
--  O QUE ISTO CONSERTA, e o que já estava consertado
--
--  Até o dia 02/09 o banco exigia o `id_uazapi` único no banco INTEIRO. Num
--  grupo com dois telefones nossos a mesma mensagem chega DUAS vezes — uma por
--  telefone, com o mesmo identificador —, e a segunda era descartada em
--  silêncio. Cada telefone ficou com um PEDAÇO da discussão.
--
--  O índice já foi trocado por (conversa_id, id_uazapi) e a ponte já grava
--  assim: DAQUI PARA A FRENTE toda mensagem de grupo cai nas duas caixas. O que
--  este arquivo faz é o mesmo, RETROATIVAMENTE, para o que ficou para trás.
--
--  MEDIDO NO ESCRITÓRIO, em 02/09, no grupo "Suporte Legal Mail - Max
--  Canaverde": 85 mensagens existiam em UM telefone só, e 2 nos dois. Cada
--  lado estava enxergando cerca de metade da conversa.
--
--  ------------------------------------------------------------
--  POR QUE COPIAR, E NÃO MOSTRAR A CAIXA DO OUTRO
--
--  A outra saída era o painel passar a ler, num grupo, as conversas dos outros
--  telefones. Isso abriria uma EXCEÇÃO na regra de acesso — "cada um vê as
--  conversas dos seus telefones" —, e exceção em regra de acesso se escreve
--  com cuidado, não de passagem.
--
--  Copiar não abre exceção nenhuma: cada um continua lendo só a sua caixa. E é
--  legítimo porque O APARELHO JÁ RECEBEU AQUILO: o telefone do Dr. Max está no
--  grupo e recebeu as 43 mensagens no WhatsApp. Nós é que falhamos em gravá-las.
--  Copiar devolve o que era dele, e não mostra nada de ninguém.
--
--  ------------------------------------------------------------
--  AS TRÊS ARMADILHAS, e como cada uma é desarmada
--
--  1. GRUPO COM TRÊS TELEFONES NOSSOS. Se a mensagem está em dois deles e
--     falta no terceiro, a consulta produz DUAS linhas iguais para o terceiro
--     — uma vinda de cada origem.
--
--     EU ESCREVI AQUI QUE O `distinct on` ERA O QUE SALVAVA DISSO, E ESTAVA
--     ERRADO. Sabotei o arquivo tirando o `distinct on`, rodei na réplica com
--     o grupo de três, e ele copiou as 6 sem erro nenhum: quem desarma é o
--     `on conflict do nothing`. Ao contrário do `do update` — que aborta com
--     "cannot affect row a second time" —, o `do nothing` engole a repetição
--     dentro do próprio comando.
--
--     O `distinct on` FICA, por outro motivo, menor e verdadeiro: quando as
--     duas origens divergem (por exemplo, um `enviado_por` diferente), ele
--     escolhe a MAIS ANTIGA em vez de deixar o banco escolher sozinho.
--
--  2. O GATILHO DAS NÃO LIDAS. O Zorvin tem um gatilho em `mensagens` que
--     atualiza a conversa a cada linha inserida, e ele SOMA em `nao_lidas`.
--     Sem cuidado, esta redistribuição marcaria 43 mensagens antigas como não
--     lidas nos dois telefones — um sino tocando por conversa que a equipe já
--     leu, e nenhuma delas nova. As contagens são guardadas antes e devolvidas
--     no fim.
--
--  3. MENSAGEM SEM IDENTIFICADOR. Sem `id_uazapi` não há como saber se é a
--     mesma mensagem, e copiar seria inventar. Ficam de fora.
--
--  E DUAS FRONTEIRAS: só contatos que começam com `grupo:` (conversa de uma
--  pessoa nunca é tocada — lá o mesmo identificador em duas caixas não existe),
--  e a lista de colunas é lida do PRÓPRIO BANCO, para o script não depender de
--  eu saber de cor o formato da tabela.
--
--  RODAR DE NOVO NÃO FAZ NADA: `on conflict do nothing` na chave que o #126
--  criou. A segunda execução diz "0 copiadas".
--
--  TESTADO NUM POSTGRES 16, numa réplica com o gatilho, o índice único, um
--  grupo de três telefones, um grupo de um telefone só, uma conversa
--  particular e uma mensagem sem identificador. O que a réplica mostrou:
--
--    a caixa de cada telefone fica com a discussão inteira   sim
--    a conversa particular                                   intocada
--    a mensagem sem identificador                            não copiada
--    autor e horário das cópias                              preservados
--    o sino de não lidas                                     mudo
--    rodar de novo                                           "0 copiadas"
--
--  E as duas defesas foram SABOTADAS, uma de cada vez:
--    sem devolver as não lidas  -> 5 sinos tocaram em mensagens de agosto
--    sem o `distinct on`        -> nada quebrou (foi o que me corrigiu acima)
-- ============================================================

-- ------------------------------------------------------------
--  1) O RETRATO DE ANTES — rode e guarde.
-- ------------------------------------------------------------
select c.nome as grupo, a.nome as de_quem, count(m.id) as mensagens
  from public.contatos c
  join public.conversas conv on conv.contato_id = c.id
  join public.advogados a    on a.id = conv.advogado_id
  left join public.mensagens m on m.conversa_id = conv.id
 where c.numero like 'grupo:%'
 group by c.nome, a.nome
 order by c.nome, a.nome;


-- ------------------------------------------------------------
--  2) A REDISTRIBUIÇÃO
-- ------------------------------------------------------------
do $$
declare
  colunas   text;
  colunas_m text;
  copiadas  bigint;
begin
  -- A LISTA DE COLUNAS VEM DO BANCO. Escrevê-la à mão significa que toda
  -- coluna nova de `mensagens` some silenciosamente nas cópias — e ninguém
  -- descobre, porque a linha existe e só está incompleta.
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position),
         string_agg('m.' || quote_ident(column_name), ', ' order by ordinal_position)
    into colunas, colunas_m
    from information_schema.columns
   where table_schema = 'public' and table_name = 'mensagens'
     and column_name not in ('id', 'conversa_id')
     and is_generated = 'NEVER';

  -- As não lidas de agora, para devolver no fim (armadilha 2).
  create temp table nao_lidas_antes on commit drop as
    select id, nao_lidas from public.conversas;

  execute format($f$
    insert into public.mensagens (conversa_id, %1$s)
    select distinct on (destino.id, m.id_uazapi) destino.id, %2$s
      from public.mensagens m
      join public.conversas origem   on origem.id = m.conversa_id
      join public.contatos  c        on c.id = origem.contato_id
      join public.conversas destino  on destino.contato_id = c.id
                                    and destino.id <> origem.id
     where c.numero like 'grupo:%%'
       and m.id_uazapi is not null
     order by destino.id, m.id_uazapi, m.criado_em
    on conflict (conversa_id, id_uazapi) do nothing
  $f$, colunas, colunas_m);

  get diagnostics copiadas = row_count;
  raise notice 'Mensagens copiadas para a caixa que as perdeu: %', copiadas;

  -- Armadilha 2: devolve as não lidas ao que eram. Redistribuir o passado não
  -- é mensagem nova, e um sino tocando por conversa já lida faz a equipe parar
  -- de acreditar no sino.
  update public.conversas cv
     set nao_lidas = a.nao_lidas
    from nao_lidas_antes a
   where a.id = cv.id and cv.nao_lidas is distinct from a.nao_lidas;
  raise notice 'Contagens de não lidas devolvidas ao que eram.';
end $$;


-- ------------------------------------------------------------
--  3) O RETRATO DE DEPOIS
--
--     Em cada grupo, os telefones têm de mostrar o MESMO número — é isso que
--     quer dizer "cada um com a discussão inteira".
-- ------------------------------------------------------------
select c.nome as grupo, a.nome as de_quem, count(m.id) as mensagens
  from public.contatos c
  join public.conversas conv on conv.contato_id = c.id
  join public.advogados a    on a.id = conv.advogado_id
  left join public.mensagens m on m.conversa_id = conv.id
 where c.numero like 'grupo:%'
 group by c.nome, a.nome
 order by c.nome, a.nome;

-- E a medida que motivou tudo: quantas mensagens ainda existem em um lado só.
-- Depois disto, `em_um_lado_so` tem de ser ZERO em todo grupo com mais de um
-- telefone nosso — fora as mensagens sem identificador, que não dá para casar.
with copias as (
  select c.nome as grupo, m.id_uazapi,
         count(distinct conv.advogado_id) as em_quantos
    from public.mensagens m
    join public.conversas conv on conv.id = m.conversa_id
    join public.contatos  c    on c.id = conv.contato_id
   where c.numero like 'grupo:%' and m.id_uazapi is not null
   group by c.nome, m.id_uazapi
), telefones as (
  select c.nome as grupo, count(distinct conv.advogado_id) as quantos
    from public.conversas conv
    join public.contatos c on c.id = conv.contato_id
   where c.numero like 'grupo:%'
   group by c.nome
)
select t.grupo, t.quantos as telefones_nossos,
       count(*) filter (where p.em_quantos < t.quantos) as em_um_lado_so,
       count(*) filter (where p.em_quantos = t.quantos) as em_todas_as_caixas
  from telefones t join copias p on p.grupo = t.grupo
 group by t.grupo, t.quantos
 order by t.grupo;


-- ------------------------------------------------------------
--  COMO DESFAZER
--
--  As cópias são as linhas mais novas de cada par (conversa, id_uazapi) — o
--  `id` delas é maior que o da original. Isto apaga só as cópias:
--
--    delete from public.mensagens m
--     using (select conversa_id, id_uazapi, min(id) as primeira
--              from public.mensagens group by conversa_id, id_uazapi) x
--     where m.conversa_id = x.conversa_id and m.id_uazapi = x.id_uazapi
--       and m.id > x.primeira;
--
--  ATENÇÃO: isto vale enquanto NADA mais tiver sido inserido depois. Como o
--  índice único já impede duas linhas com o mesmo par, na prática este delete
--  não acha nada — cada par é único. Para desfazer de verdade é preciso saber
--  QUAIS foram copiadas, e é por isso que o passo 1 existe: os números de
--  antes são o que permite conferir se algo saiu do esperado.
-- ------------------------------------------------------------
