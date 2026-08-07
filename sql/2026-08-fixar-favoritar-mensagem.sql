-- ------------------------------------------------------------
--  FIXAR E FAVORITAR UMA MENSAGEM
--
--  Duas marcas por mensagem, e não por conversa. A estrela e o alfinete que já
--  existem são da CONVERSA inteira — servem para achar a pessoa, não o trecho.
--  Quem precisa voltar ao número que o cliente mandou às 14h de terça hoje rola
--  a conversa inteira procurando.
--
--    fixada   — o alfinete. Aparece numa barra no topo da conversa; clicar
--               leva até a mensagem.
--    favorita — a estrela. Fica na bolha, para marcar o que importa guardar.
--
--  A POLÍTICA DE ATUALIZAÇÃO É O QUE FALTAVA DE VERDADE.
--
--  A tabela `mensagens` tinha política de leitura e de inserção, e nenhuma de
--  atualização. Sem ela o Supabase não dá erro: ele simplesmente não altera
--  nada. O botão pareceria funcionar e a marca sumiria ao recarregar — o mesmo
--  silêncio que já custou caro na tela de Departamentos.
--
--  A política usa a mesma regra das outras: quem enxerga a conversa pode mexer
--  nas mensagens dela.
--
--  Rode INTEIRO no SQL Editor do Supabase.
-- ------------------------------------------------------------
alter table mensagens
  add column if not exists fixada boolean default false,
  add column if not exists favorita boolean default false;

drop policy if exists mensagens_atualizacao on mensagens;

create policy mensagens_atualizacao on mensagens for update to authenticated
using (exists (select 1 from conversas c where c.id = mensagens.conversa_id))
with check (exists (select 1 from conversas c where c.id = mensagens.conversa_id));
