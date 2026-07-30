-- ============================================================
--  "NÃO CONSEGUI ABRIR A CONVERSA" — a política que faltava desde sempre.
--
--  Rode uma vez no Supabase do Zorvin:
--    Dashboard → SQL Editor → New query → cole tudo → Run
--
--  Pode rodar de novo sem medo.
-- ============================================================
--
--  O QUE ACONTECIA
--
--  Cadastrar um contato novo e clicar em "Salvar e conversar" respondia
--  "Não consegui abrir a conversa". Abrir a conversa de quem JÁ tinha uma
--  funcionava — e é essa diferença que aponta a causa.
--
--  A tabela `conversas` tem segurança por linha (RLS) ligada, com três
--  políticas: LER, ATUALIZAR e nenhuma para INSERIR. Sem política de inserção,
--  o banco recusa qualquer linha nova — e recusa em silêncio, do jeito que o RLS
--  faz: não é erro de permissão que apareça bonito na tela, é simplesmente "não
--  deu". Abrir uma conversa que já existe é um UPDATE (permitido); abrir uma
--  conversa nova é um INSERT (recusado).
--
--  Faltava desde que o RLS foi ligado, no SQL de departamentos. Não é sequela do
--  arquivo dos grupos: aquele recriou as políticas exatamente como estavam,
--  inclusive a ausência desta.
--
--  A MESMA falta pega também a IMPORTAÇÃO de histórico do WhatsApp, que cria uma
--  conversa por arquivo importado. Quem tentou importar e viu falhar sem
--  explicação era isto.
--
--  A REGRA da política nova é a mesma das outras, e é a única que faz sentido:
--  você pode abrir conversa em um telefone que você tem permissão de ver. Não é
--  afrouxar nada — é escrever a permissão que já valia para ler e atualizar.
-- ------------------------------------------------------------

drop policy if exists conversas_insercao on conversas;

create policy conversas_insercao on conversas for insert to authenticated
with check (pode_ver_conversa(advogado_id));


-- ------------------------------------------------------------
--  CONFERÊNCIA
-- ------------------------------------------------------------
select tablename, policyname, cmd
  from pg_policies
 where schemaname = 'public' and tablename = 'conversas'
 order by cmd, policyname;
-- Esperado: três linhas — INSERT (conversas_insercao), SELECT (conversas_leitura)
-- e UPDATE (conversas_escrita).
