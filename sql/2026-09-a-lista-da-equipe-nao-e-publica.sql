-- ============================================================
--  A LISTA DA EQUIPE NÃO É PÚBLICA
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ISTO CONSERTA
--
--  A vista `equipe` mostra três colunas seguras de `usuarios` (id, nome,
--  foto_url) para quem está dentro do painel. Ela existe de propósito, e o
--  desenho está certo: `usuarios_leitura` deixa cada pessoa ler só a própria
--  linha, e o painel precisa do nome e da foto de TODOS para assinar as
--  mensagens antigas — inclusive as anteriores à coluna `enviado_por_id`.
--
--  O erro não é a vista. É ela estar liberada para `anon`, o papel de quem NÃO
--  entrou, cuja chave vai no código da página e está à vista de qualquer um que
--  abra o painel no navegador. Medido em 09/09: 21 linhas devolvidas a `anon`.
--
--  E como a vista foi criada SEM `security_invoker`, ela roda com os poderes da
--  dona (`postgres`), e a regra de acesso de `usuarios` não vale por dentro
--  dela — nem para ler, nem para escrever. Sendo uma consulta simples de uma
--  tabela só, o Postgres a trata como gravável: escrever nela cai em `usuarios`
--  por baixo, sem passar por `usuarios_admin`.
--
--  ------------------------------------------------------------
--  O QUE **NÃO** É O CONSERTO, e por quê
--
--  Ligar `security_invoker` na vista, que foi a primeira ideia. Ela passaria a
--  obedecer `usuarios_leitura`, e cada atendente veria só a PRÓPRIA linha: nome
--  e foto de todos os outros sumiriam das mensagens antigas. Sem erro na tela,
--  sem aviso — vinte e uma linhas viram uma, e a leitura da `equipe` no painel
--  trata a falha com `if (error) return`, então nem no console apareceria algo.
--
--  É o desfecho de 04/09 outra vez: a tela desenhando AUSÊNCIA no lugar de
--  falha. A vista definidora é o desenho certo aqui; o que sobra é fechar a
--  porta para quem não entrou.
-- ============================================================

-- ------------------------------------------------------------
--  1) ANTES — o retrato, para comparar depois
-- ------------------------------------------------------------
select 'a vista aceita escrita?' as pergunta,
       pg_relation_is_updatable('public.equipe'::regclass, true) <> 0 as resposta
union all
select 'quem não entrou alcança a vista?',
       has_table_privilege('anon', 'public.equipe', 'SELECT')
union all
select 'quem não entrou pode escrever nela?',
       has_table_privilege('anon', 'public.equipe', 'UPDATE')
    or has_table_privilege('anon', 'public.equipe', 'DELETE')
    or has_table_privilege('anon', 'public.equipe', 'INSERT');


-- ------------------------------------------------------------
--  2) A MUDANÇA
--
--  `anon` sai inteiro: nada no painel roda antes de entrar.
--
--  `authenticated` fica só com a leitura. Escrever pela vista nunca foi usado
--  por nada — e por ela a escrita não passa pela regra de acesso, então era um
--  caminho aberto para reescrever a ficha de qualquer pessoa sem ser admin.
-- ------------------------------------------------------------
revoke all on public.equipe from anon;
revoke all on public.equipe from authenticated;
grant select on public.equipe to authenticated;


-- ------------------------------------------------------------
--  3) A FILA: DISPENSAR AVISO DE FALHA É COISA DE QUEM ESTÁ DENTRO
--
--  `painel dispensa aviso de falha` valia para `{anon, authenticated}` — a
--  única das 42 políticas do banco que incluía quem não entrou. Ela deixa pegar
--  um item da fila com `status = 'erro'` e marcá-lo como `descartada`.
--
--  Não é roubo de dado; é pior de um jeito específico. Alguém de fora faria
--  SUMIR TODAS AS BOLHAS VERMELHAS do escritório de uma vez, e a equipe passaria
--  a acreditar que as mensagens saíram. O aviso de que uma mensagem não chegou
--  ao cliente é exatamente o que aquela bolha existe para dar.
--
--  A política é recriada IGUAL — mesmo nome, mesma condição, mesmo destino.
--  Muda só para quem ela vale. O painel dispensa o erro estando logado, então
--  nada muda para quem usa.
-- ------------------------------------------------------------
drop policy if exists "painel dispensa aviso de falha" on public.fila_envio;
create policy "painel dispensa aviso de falha"
  on public.fila_envio
  for update
  to authenticated
  using      (status = 'erro')
  with check (status = 'descartada');


-- ------------------------------------------------------------
--  4) CONFERÊNCIA — rode e leia
-- ------------------------------------------------------------
select 'quem não entrou NÃO alcança mais a equipe' as item,
       not has_table_privilege('anon', 'public.equipe', 'SELECT') as ok
union all
select 'nem escreve nela',
       not (has_table_privilege('anon', 'public.equipe', 'UPDATE')
         or has_table_privilege('anon', 'public.equipe', 'DELETE')
         or has_table_privilege('anon', 'public.equipe', 'INSERT'))
union all
select 'quem está dentro continua LENDO a equipe',
       has_table_privilege('authenticated', 'public.equipe', 'SELECT')
union all
select 'e não escreve mais nela',
       not (has_table_privilege('authenticated', 'public.equipe', 'UPDATE')
         or has_table_privilege('authenticated', 'public.equipe', 'DELETE')
         or has_table_privilege('authenticated', 'public.equipe', 'INSERT'))
union all
select 'nenhuma política vale mais para quem não entrou',
       not exists (select 1 from pg_policies
                    where schemaname = 'public' and roles::text ~ '(anon|public)');


-- ------------------------------------------------------------
--  5) A PROVA DE FOGO — a equipe, lida por quem não entrou
--
--  Antes desta mudança isto devolvia 21. Agora tem de dar ERRO de permissão.
--  Erro aqui é a boa notícia.
-- ------------------------------------------------------------
set local role anon;
select count(*) from public.equipe;
reset role;


-- ------------------------------------------------------------
--  DEPOIS DE RODAR — o que conferir no painel
--
--  Abra uma conversa antiga com mensagens de vários atendentes e veja se os
--  NOMES E AS FOTOS continuam aparecendo. É a única coisa que esta vista
--  alimenta, e o sintoma de uma quebra aqui é silencioso: os nomes somem, e
--  nada na tela diz por quê.
--
--  Desfazer, se sumirem:
--      grant select on public.equipe to authenticated;
-- ------------------------------------------------------------
