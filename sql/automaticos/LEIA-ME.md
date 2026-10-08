# Os scripts que a ponte aplica sozinha

**Todo script de banco novo vem para cá.** A ponte aplica os que faltam quando
sobe, uma vez cada, na ordem do nome do arquivo.

A pasta de cima (`sql/`) é **história**: 55 arquivos que já foram rodados à mão
no editor do Supabase e continuam lá para consulta. Nada ali é reaplicado, e não
se deve mover um arquivo de lá para cá — no banco do escritório ele já rodou, e
a ponte não tem como saber disso.

## Como nomear

    001-o-que-o-script-faz.sql
    002-outra-coisa.sql

O número manda na ordem, e a ordem importa: um script quase sempre supõe que o
anterior passou. O nome em português é para o arquivo dizer sozinho o que faz —
é o que o log vai repetir quando algo der errado às sete da manhã.

## As regras ao escrever um

1. **Rodável duas vezes sem estrago.** `create table if not exists`,
   `add column if not exists`, `drop policy if exists` antes de `create policy`.
   Um script que quebra na segunda vez é um script que quebra no dia em que
   alguém restaurar um backup.

2. **Tabela nova nasce com a política junto.** É a armadilha nº 5 do CLAUDE.md:
   sem política, o painel lê vazio e não diz nada; com a política errada, `anon`
   lê tudo. As duas já aconteceram aqui.

3. **Não se edita script já aplicado.** A ponte guarda a impressão digital
   (`sha256`) do que aplicou; mudando o arquivo depois, ela **para** e diz qual
   foi. Conserto de script aplicado é o próximo número, nunca uma edição.

4. **Função que o painel chama é conferida NO PAPEL de quem atende.** A
   conferência roda como dona do banco, que alcança todas as colunas; o painel
   roda como `authenticated`, que não alcança a chave da Uazapi em
   `advogados`. O 011 passou na conferência e morreu na tela com
   `permission denied for table advogados` por causa de um `to_jsonb(a)`. Ver
   como o 012 chama a função com `set_config('role', 'authenticated', true)`.

5. **"Pode rodar de novo sem medo" vale para a pasta INTEIRA, na ordem — não
   para um script velho sozinho.** Medido na auditoria de 07/10: o 004 e o 005
   fazem `create or replace` das funções da espera nas versões DELES; rodar o
   004 de novo, sozinho, depois do 006, desfaz a carência de 30 minutos e
   devolve à fila toda conversa tirada pelo "Já tratei". O 009 rodado de novo
   recria o "OUTROS" se alguém o renomeou ou desativou. Se for preciso rodar um
   antigo, rode **todos daquele em diante, na ordem**. E daqui para a frente:
   **a versão de referência de uma função compartilhada mora só no script
   mais novo que a recria** (o gatilho da espera, hoje, é o do 020), e um
   script que semeia linha (como o "OUTROS") só semeia na rodada que CRIA a
   coluna ou a tabela.

6. **A última linha é a conferência, e `false` quer dizer defeito.** É o
   `select` que responde "deu certo?" — no editor da Supabase ele é o que
   aparece ao apertar Run, e na ponte ele fica guardado em
   `zorvin_scripts_aplicados.conferencia` e aparece no painel de quem
   administra. A convenção, que a ponte usa para destacar o que não fechou:
   `true` e "sim" são o certo; **`false`, um valor que começa com "NÃO" e um
   "rode o script…" são o defeito**. Contagens e nomes são informação, e não
   pesam. Então: notícia boa não começa com "não" ("nenhuma — a faixa some",
   e não "não há linha caída").

Quem precisar de algo que não roda dentro de transação (`create index
concurrently`) escreve `-- sem-transacao` na **primeira linha** do arquivo.

## Como ligar

No Render, no serviço da ponte:

- `DATABASE_URL` — o endereço do **Session pooler** do Supabase (no painel da
  Supabase, **Connect → Session pooler**), **colado como veio**, com
  `[YOUR-PASSWORD]` dentro. Tem de ser esse, e não o direto nem o de transação:
  o direto só responde por IPv6 e a Render não alcança (armadilha nº 1), e o de
  transação (porta 6543) solta a trava no meio do caminho — a ponte o recusa
  antes de tentar.
- `DATABASE_PASSWORD` — a senha do **banco** (Project Settings → Database; não é
  a de entrar no site da Supabase). À parte do endereço, porque senha com `@`,
  `#`, `/` ou `?` escrita dentro dele o parte no lugar errado.
- `SCRIPTS_AUTOMATICOS` — `conferir` (o padrão: só diz o que rodaria) ou
  `aplicar`.
- `SCRIPTS_RODADOS_A_MAO` — num banco que já tem o Zorvin, o número do último
  script desta pasta que **já foi colado à mão**, escrito como no nome do
  arquivo (`020`, e não `20`). Na primeira vez a ponte anota de 001 até ele
  **sem rodar nenhum**; depois disso a variável é ignorada e pode sair. `0` quer
  dizer "nenhum". **Sem ela, num banco que já tem o Zorvin e nenhum registro, a
  ponte não aplica nada** — esquecer a variável não pode ser o jeito de rodar
  tudo de novo.

**Sem `DATABASE_URL` nada disto acontece** e as mudanças de banco continuam
sendo coladas à mão, exatamente como sempre foram.

## Onde ver o que aconteceu

No painel, para quem administra: **Departamentos → Estrutura → Atualizações do
banco**. Lá aparecem a situação da última subida da ponte, o que entrou, o que
foi colado à mão, e a conferência de cada script. Se algo falhar, quem
administra vê também uma linha na faixa vermelha do alto.
