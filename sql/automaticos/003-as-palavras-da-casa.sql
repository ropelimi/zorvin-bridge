-- ============================================================
--  AS PALAVRAS DA CASA — como esta instalação chama quem é dono de um telefone
--
--  ------------------------------------------------------------
--  O QUE ELE CONSERTA
--
--  O painel diz "advogado" em oito frases: "ADVOGADO (dono destas conversas)",
--  "Escolha o advogado…", "QUAL NOME É VOCÊ (o advogado) NAS CONVERSAS?". Para
--  o escritório está certo. Para uma clínica, uma imobiliária ou uma equipe de
--  vendas, o programa passa a falar de uma profissão que não é a deles — na
--  primeira tela, no lugar mais visível.
--
--  Esta tabela é onde a palavra passa a morar.
--
--  ------------------------------------------------------------
--  POR QUE UMA TABELA, E NÃO UMA VARIÁVEL DE AMBIENTE
--
--  Variável de ambiente só muda com nova publicação, e quem compra o programa
--  não publica nada — ele abre a tela e escreve. Uma palavra que exige chamar
--  o fornecedor para ser trocada é, na prática, uma palavra fixa.
--
--  ------------------------------------------------------------
--  POR QUE "PROCESSO" NÃO ESTÁ AQUI
--
--  Medido em 15/09: toda frase visível com "processo" está atrás de uma porta
--  do Vantoro — o seletor de processo da nota, o vínculo, os avisos. O Vantoro
--  é o sistema do próprio escritório, onde a palavra é sempre "processo". Um
--  botão para trocar uma palavra que só aparece quando o Vantoro está ligado
--  seria um botão que ninguém pode usar.
--
--  ------------------------------------------------------------
--  UMA LINHA SÓ, E É PROPOSITAL
--
--  `id` é fixo em `true` com `check (id)`: não há como inserir uma segunda
--  linha. Duas linhas de configuração viram a pergunta "qual delas vale", e a
--  resposta é sempre descoberta tarde, com metade da tela dizendo uma coisa e
--  metade dizendo outra.
--
--  ------------------------------------------------------------
--  O GÊNERO É COLUNA, E NÃO ADIVINHAÇÃO
--
--  As frases concordam: "o advogado" / "a médica", "um advogado" / "uma
--  médica", "dono" / "dona", "selecionado" / "selecionada". Deduzir o gênero
--  da terminação erraria em "gerente", "assistente", "representante" — e erro
--  de concordância na primeira tela é o tipo de coisa que faz um comprador
--  achar que o programa é amador.
--
--  ------------------------------------------------------------
--  QUEM LÊ E QUEM ESCREVE
--
--  Lê: qualquer pessoa que entrou — a palavra aparece na tela de todo mundo.
--  Escreve: só quem administra, pela mesma `zorvin_admin()` que as outras
--  políticas usam (ela já exige `admin E ativo`).
--
--  A POLÍTICA VAI JUNTO com a tabela, que é a armadilha nº 1 do CLAUDE.md:
--  tabela nova sem política é o painel vendo vazio, sem erro nenhum.
--
--  ------------------------------------------------------------
--  CONFERÊNCIA (depois de aplicado)
--
--    select * from public.zorvin_palavras;
--    -- deve devolver uma linha: t | advogado | advogados | m
--
--  DESFAZER
--
--    drop table if exists public.zorvin_palavras;
-- ============================================================

create table if not exists public.zorvin_palavras (
  id          boolean primary key default true check (id),
  singular    text not null default 'advogado',
  plural      text not null default 'advogados',
  genero      text not null default 'm' check (genero in ('m', 'f')),
  atualizado  timestamptz not null default now()
);

comment on table public.zorvin_palavras is
  'Como esta instalação chama quem é dono de um telefone. Uma linha só '
  '(`check (id)`). O painel usa os padrões quando a tabela não existe.';

-- A LINHA NASCE COM O PADRÃO DE HOJE, e não vazia: uma tabela vazia faria a
-- tela cair no padrão de qualquer jeito, e aí não haveria o que editar na
-- tela de administração — o comprador veria um campo em branco sem saber que
-- ele manda em alguma coisa.
insert into public.zorvin_palavras (id) values (true)
  on conflict (id) do nothing;

alter table public.zorvin_palavras enable row level security;

drop policy if exists zorvin_palavras_leitura on public.zorvin_palavras;
create policy zorvin_palavras_leitura on public.zorvin_palavras
  for select to authenticated using (true);

-- ESCRITA SEPARADA DA LEITURA, e não uma política `for all`: `for all` daria
-- DELETE junto, e apagar a linha é o único jeito de esta tabela ficar num
-- estado que nenhum código descreve.
drop policy if exists zorvin_palavras_escrita on public.zorvin_palavras;
create policy zorvin_palavras_escrita on public.zorvin_palavras
  for update to authenticated
  using (public.zorvin_admin()) with check (public.zorvin_admin());

grant select on public.zorvin_palavras to authenticated;
grant update on public.zorvin_palavras to authenticated;
