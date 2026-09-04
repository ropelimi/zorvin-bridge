-- ============================================================
--  A CHAVE DA UAZAPI DEIXA DE FICAR À VISTA DE QUEM ESTÁ LOGADO
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ESTÁ ACONTECENDO HOJE
--
--  A tabela `advogados` guarda, além do nome e do número, as credenciais de
--  cada linha do escritório na Uazapi: `token`, `servidor` e `instancia`.
--
--  A regra de acesso dela é "todo mundo que está logado pode ler" — e ela vale
--  por LINHA, não por coluna. O painel pede só algumas colunas, mas a permissão
--  não obriga ninguém a pedir só elas.
--
--  Medido neste banco, em 03/09/2026:
--
--      grantee        privilege_type   column_name
--      -------------  ---------------  ---------------
--      authenticated  SELECT           token
--      authenticated  UPDATE           token
--      authenticated  INSERT           token
--      ... e o mesmo para servidor, instancia e todas as outras
--
--  Ou seja: qualquer atendente, usando a chave pública que está dentro do
--  JavaScript do painel mais a própria sessão, pede a tabela inteira pela API e
--  sai com o token de TODAS as linhas. Com ele, manda e lê mensagens por
--  qualquer telefone do escritório falando direto com a Uazapi — por fora do
--  Zorvin, por fora das permissões, e sem deixar rastro no painel.
--
--  Num escritório de advocacia isso não é um exagero de segurança: é a
--  possibilidade de alguém escrever a um cliente em nome de um advogado.
--
--  ------------------------------------------------------------
--  O QUE ESTE ARQUIVO FAZ
--
--  Tira a permissão da TABELA e devolve só as COLUNAS que o painel usa de
--  verdade. Nada some do banco: a ponte continua lendo tudo, porque ela usa a
--  chave de serviço, que não passa por estas regras.
--
--  O QUE O PAINEL USA, conferido linha por linha no código dele:
--
--      LER     id, nome, numero, foto_url, departamento_id, ativo
--              (`Painel.jsx` 2462 e 11106; `Departamentos.jsx` 71 — e `ativo`
--               e `nome` entram porque a consulta filtra e ordena por eles,
--               e para filtrar é preciso poder ler)
--
--      MUDAR   departamento_id
--              (`Departamentos.jsx` 233 — arrastar um telefone de um
--               departamento para outro; quem pode fazer isso continua sendo
--               só quem administra, pela regra de linha que já existe)
--
--  O QUE SAI, e por que ninguém sente falta:
--
--      token, servidor, instancia   as credenciais. Só a ponte precisa delas.
--      setor, frente_fixa           não aparecem em lugar nenhum do painel.
--      criado_em                    idem.
--      INSERT e DELETE              o painel nunca cria nem apaga telefone.
--
--  ------------------------------------------------------------
--  AS FUNÇÕES DO BANCO CONTINUAM FUNCIONANDO — e isto foi conferido
--
--  `pode_ver_conversa` e `meus_telefones` (as que decidem quem enxerga o quê)
--  são `security definer`: rodam com o poder de quem as criou, e não com o de
--  quem chama. Esta mudança não as alcança.
--
--  `painel_dashboard` roda como quem chama e toca `advogados` — mas só em
--  `select a.id ... where a.departamento_id = ...`. As duas colunas continuam
--  liberadas.
--
--  ------------------------------------------------------------
--  ISTO FOI MEDIDO, E NÃO DEDUZIDO
--
--  Antes de mandar este arquivo eu montei a réplica num Postgres 16 de verdade:
--  os papéis `anon` e `authenticated`, a tabela `advogados` com as mesmas doze
--  colunas, uma linha com um token de mentira, e a permissão no estado
--  inseguro de hoje (`grant select, insert, update, references` na tabela).
--
--  ANTES, com o papel `authenticated`:
--
--      select token from advogados;   ->  TOKEN-SECRETO-123
--
--  DEPOIS de rodar este arquivo, com o mesmo papel:
--
--      ler o token                        -> permission denied for table advogados
--      ler o servidor                     -> permission denied
--      select *                           -> permission denied
--      as 6 colunas que o painel pede     -> PASSOU
--      mover o telefone de departamento   -> PASSOU (inclusive devolvendo a linha,
--                                            que é como o painel faz)
--      mudar o token                      -> permission denied
--      criar um telefone                  -> permission denied
--      apagar um telefone                 -> permission denied
--
--  E o token continuou intacto no banco: isto tira o acesso, não o dado.
--
--  O `select *` recusado É ESPERADO e vale saber: se algum dia uma tela pedir
--  a tabela inteira, ela volta vazia. As quatro consultas que o painel faz hoje
--  pedem colunas nomeadas — foram conferidas uma a uma.
--
--  ------------------------------------------------------------
--  DEPOIS DE RODAR, TROQUE OS TOKENS NA UAZAPI
--
--  Este arquivo fecha a porta daqui para a frente. Ele não desfaz o que já
--  esteve à vista: qualquer pessoa que teve acesso ao painel até hoje pôde ler
--  os tokens. Trocá-los na Uazapi é o que os torna inúteis — e é a metade do
--  conserto que não se faz com SQL.
-- ============================================================


-- ------------------------------------------------------------
--  1) O RETRATO DE ANTES — rode e guarde a saída
--
--     Esperado: uma linha para cada coluna e cada tipo de permissão,
--     incluindo `token` com SELECT, INSERT e UPDATE.
-- ------------------------------------------------------------
select grantee, privilege_type, column_name
  from information_schema.column_privileges
 where table_schema = 'public' and table_name = 'advogados'
   and grantee in ('authenticated', 'anon')
 order by grantee, column_name, privilege_type;


-- ------------------------------------------------------------
--  2) A TROCA
--
--     `revoke all` tira tanto a permissão dada na tabela inteira quanto as
--     dadas coluna a coluna — e não dá para saber, olhando a consulta acima,
--     qual das duas foi usada aqui. Tirar as duas resolve sem adivinhar.
--
--     `anon` é quem não fez login. Ele não deveria alcançar nada mesmo (as
--     regras de linha são todas para `authenticated`), mas uma permissão
--     esquecida ali é justamente o tipo de porta que ninguém procura.
-- ------------------------------------------------------------
revoke all on table public.advogados from authenticated;
revoke all on table public.advogados from anon;

-- O que a tela precisa LER.
grant select (id, nome, numero, foto_url, departamento_id, ativo)
  on public.advogados to authenticated;

-- O que a tela precisa MUDAR: só o departamento do telefone.
-- Quem pode fazer isso continua sendo só quem administra — a regra de linha
-- `advogados_admin` não mudou, e é ela que decide QUEM. Esta permissão decide
-- O QUÊ, e as duas valem juntas.
grant update (departamento_id) on public.advogados to authenticated;


-- ------------------------------------------------------------
--  3) A CONFERÊNCIA — rode e leia
--
--     A primeira linha é a que importa: `token_a_vista` tem de ser `false`.
-- ------------------------------------------------------------
select 'a chave da Uazapi ainda está à vista?' as pergunta,
       exists(select 1 from information_schema.column_privileges
               where table_schema = 'public' and table_name = 'advogados'
                 and grantee in ('authenticated', 'anon')
                 and column_name in ('token', 'servidor', 'instancia')) as token_a_vista
union all
select 'a tela consegue ler o telefone?',
       -- `distinct` porque a mesma coluna pode aparecer mais de uma vez aqui
       -- (uma linha por quem concedeu). Contando sem ele, um banco com dois
       -- concedentes daria 12 e a conferência diria "não" com tudo certo.
       (select count(distinct column_name) = 6 from information_schema.column_privileges
         where table_schema = 'public' and table_name = 'advogados'
           and grantee = 'authenticated' and privilege_type = 'SELECT'
           and column_name in ('id', 'nome', 'numero', 'foto_url', 'departamento_id', 'ativo'))
union all
select 'quem administra consegue mover o telefone de departamento?',
       exists(select 1 from information_schema.column_privileges
               where table_schema = 'public' and table_name = 'advogados'
                 and grantee = 'authenticated' and privilege_type = 'UPDATE'
                 and column_name = 'departamento_id');

-- E o retrato de depois, para comparar com o de antes:
select grantee, privilege_type, column_name
  from information_schema.column_privileges
 where table_schema = 'public' and table_name = 'advogados'
   and grantee in ('authenticated', 'anon')
 order by grantee, column_name, privilege_type;


-- ------------------------------------------------------------
--  4) DEPOIS DE RODAR, CONFIRA NO PAINEL (leva um minuto)
--
--     Entre com uma conta que NÃO administra e veja se:
--       - a lista de telefones aparece no alto da coluna da esquerda;
--       - as conversas de um telefone abrem normalmente;
--       - o Painel (a tela de números) desenha os cartões.
--
--     Entre com a sua conta de administrador e veja se:
--       - a tela "Departamentos e acessos" lista os telefones;
--       - arrastar um telefone para outro departamento continua funcionando.
--
--     Se alguma lista aparecer VAZIA, é uma coluna que faltou nesta liberação —
--     e o sintoma do RLS é esse mesmo: vazio, sem erro. Me diga qual tela e eu
--     acrescento a coluna.
-- ------------------------------------------------------------


-- ------------------------------------------------------------
--  COMO DESFAZER, se algo parecer errado
--
--     Volta ao estado de antes deste arquivo (que é o estado inseguro):
--
--       grant select, insert, update, references on public.advogados
--         to authenticated;
-- ------------------------------------------------------------
