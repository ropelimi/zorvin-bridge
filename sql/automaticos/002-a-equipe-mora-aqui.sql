-- ============================================================
--  A EQUIPE MORA AQUI — a permissão de cada pessoa, sem depender do Vantoro
--
--  ------------------------------------------------------------
--  O QUE ELE CONSERTA
--
--  A tela de permissões do painel lê a lista de gente do Vantoro e escreve a
--  permissão no Vantoro. Quem compra o Zorvin sem ter Vantoro entra (o script
--  001 resolveu isso) e é administrador — mas não tem como cadastrar mais
--  ninguém, nem dizer o que cada pessoa alcança. Um sistema de atendimento em
--  equipe com uma pessoa só.
--
--  Esta coluna é onde essa resposta passa a morar quando não há Vantoro.
--
--  ------------------------------------------------------------
--  POR QUE UMA COLUNA `jsonb`, E NÃO TABELAS NOVAS
--
--  A resposta que o Vantoro devolve tem quatro campos, e a ponte já sabe
--  traduzi-los em linhas de `permissoes` — é a `aplicarPermissoes`, que é
--  delicada e está provada (ela compara antes de escrever, para ninguém ficar
--  cego no meio de uma rodada). Guardando os MESMOS quatro campos, essa
--  tradução continua valendo sem uma linha alterada:
--
--    {
--      "definido":      true,            -- alguém já decidiu (≠ "não vê nada")
--      "so_telefones":  false,           -- o corte fino ganha do grosso
--      "departamentos": ["comercial"],   -- por slug
--      "telefones":     ["5511..."]      -- por chave do número
--    }
--
--  Tabelas novas guardariam a mesma coisa em outro formato e exigiriam uma
--  segunda tradução — dois caminhos para a mesma decisão, que é como se
--  constroem as divergências que ninguém explica depois.
--
--  `permissoes` continua sendo a verdade que as políticas do banco leem. Esta
--  coluna é a INTENÇÃO de quem administra; aquelas linhas são o EFEITO.
--
--  ------------------------------------------------------------
--  NADA MUDA PARA QUEM TEM VANTORO
--
--  Com `VANTORO_API_URL` configurada, a ponte continua perguntando e gravando
--  lá, e esta coluna fica vazia. Ela não é lida nesse caminho — e não poderia
--  ser: manter duas listas de gente iguais é coisa que ninguém faz por muito
--  tempo, e foi por isso que o Vantoro virou a fonte.
--
--  ------------------------------------------------------------
--  CONFERÊNCIA (depois de aplicado)
--
--    select column_name, data_type from information_schema.columns
--     where table_name = 'usuarios' and column_name = 'acesso';
--    -- deve devolver: acesso | jsonb
--
--  DESFAZER
--
--    alter table public.usuarios drop column if exists acesso;
-- ============================================================

alter table public.usuarios
  add column if not exists acesso jsonb;

comment on column public.usuarios.acesso is
  'Sem Vantoro: o que quem administra decidiu que esta pessoa alcança. '
  '{definido, so_telefones, departamentos[slug], telefones[chave]}. '
  'É a INTENÇÃO; as linhas de `permissoes` são o EFEITO.';
