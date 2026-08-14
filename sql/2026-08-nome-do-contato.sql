-- O NOME QUE A EQUIPE DÁ AO CONTATO, SEM PRECISAR DE CADASTRO NO VANTORO.
--
-- Rodar no SQL Editor do Supabase. Idempotente.
--
-- O caso é o de vendas: chega um lead, a pessoa se identifica na conversa, e o
-- WhatsApp mostra o apelido que ela escolheu no aparelho ("Deus", "Eu", o nome
-- da loja). Dá para arrumar isso hoje, mas só criando um cadastro no Vantoro —
-- e a maior parte dos leads nunca vira cliente. Cadastro criado só para
-- consertar um nome é lixo entrando na base do escritório.
--
-- Agora são TRÊS nomes, e cada um responde uma pergunta diferente:
--
--   `nome`         o que o WhatsApp mandou. É o registro do que chegou, e não
--                  se apaga: é ele que aparece para quem ainda não foi tocado
--                  por ninguém.
--   `nome_zorvin`  o que a EQUIPE escreveu aqui dentro. Vale para quem não tem
--                  cadastro — leads, em geral.
--   `vantoro_nome` o do CADASTRO. Continua mandando quando existe: quem virou
--                  cliente é conhecido pelo nome da ficha, e o painel não é
--                  dono do nome de ninguém que o Vantoro já conhece.
--
-- A ordem é essa mesma na tela: cadastro, depois o da equipe, depois o do
-- WhatsApp, depois o número.

alter table contatos add column if not exists nome_zorvin text;

comment on column contatos.nome_zorvin is
  'Nome dado pela equipe no Zorvin. Vale para quem não tem cadastro no Vantoro.';

-- A tela passa a ESCREVER em `contatos` (antes só a ponte escrevia). Sem esta
-- regra o `update` volta vazio e sem erro — o Supabase responde "0 linhas
-- alteradas" para o que a política não deixa ver, e a tela mostraria o nome
-- novo até a página ser recarregada.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;
  execute 'drop policy if exists contatos_atualizacao on contatos';
  execute 'create policy contatos_atualizacao on contatos for update to authenticated using (true) with check (true)';
end;
$$;
