-- ------------------------------------------------------------
--  FIGURINHAS FAVORITAS
--
--  Hoje a galeria mostra TODA figurinha que passou pelo Zorvin — enviada ou
--  recebida. Parecia prático e não é: o acervo vira o histórico. Basta um
--  cliente mandar uma piada, um deboche ou uma figurinha imprópria para ela
--  ficar guardada à mão, na mesma lista que a equipe abre para responder outro
--  cliente. Num escritório de advocacia, mandar a figurinha errada por engano
--  é um problema de verdade.
--
--  A partir daqui a galeria é uma ESCOLHA. Quem quiser guardar uma figurinha
--  usa "Adicionar às figurinhas favoritas" no menu da mensagem; quem se
--  arrepender usa "Remover". Nada entra sozinho.
--
--  A lista é do ESCRITÓRIO, não de cada pessoa: quem atende hoje é quem
--  estiver na escala, e uma figurinha guardada pela Joana precisa estar à mão
--  da Beatriz. `adicionada_por` fica só como registro de quem guardou.
--
--  A URL é única: a mesma figurinha não entra duas vezes na lista.
--
--  E ATENÇÃO À POLÍTICA DE EXCLUSÃO.
--
--  Sem ela o Supabase não dá erro: ele simplesmente não apaga nada. O botão
--  "Remover" pareceria funcionar e a figurinha voltaria ao recarregar — o
--  mesmo silêncio que já custou caro em Departamentos e no Fixar/Favoritar.
--
--  Rode INTEIRO no SQL Editor do Supabase.
-- ------------------------------------------------------------
create table if not exists figurinhas_favoritas (
  id uuid primary key default gen_random_uuid(),
  midia_url text not null unique,
  midia_mime text,
  adicionada_por text,
  criado_em timestamptz not null default now()
);

alter table figurinhas_favoritas enable row level security;

drop policy if exists figurinhas_leitura on figurinhas_favoritas;
create policy figurinhas_leitura on figurinhas_favoritas
  for select to authenticated using (true);

drop policy if exists figurinhas_insercao on figurinhas_favoritas;
create policy figurinhas_insercao on figurinhas_favoritas
  for insert to authenticated with check (true);

drop policy if exists figurinhas_exclusao on figurinhas_favoritas;
create policy figurinhas_exclusao on figurinhas_favoritas
  for delete to authenticated using (true);
