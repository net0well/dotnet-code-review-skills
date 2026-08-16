# Auditoria técnica: acesso a dados (EF Core / EF6)

Auditoria de corretude factual das partes de acesso a dados da skill `dotnet-code-review`.
Data: 2026-08-14. Nenhum arquivo auditado foi alterado.

## Arquivos e seções auditados

| Arquivo | Seções |
|---|---|
| `.../dotnet-code-review/designpatterns/references/dotnet-moderno.md` | "Entity Framework Core" (linhas 90-108), mais as linhas de acesso a dados espalhadas em "Async e concorrência" (37, 42), "DI e lifetimes" (65-88) e "CancellationToken" (52-59) |
| `.../dotnet-code-review/designpatterns/references/catalogo-patterns.md` | "Repository e Unit of Work" (284-303), "Specification" (306-309), "CQRS" (311-314), mais as linhas de dados em "Padrões mal implementados" (343, 355) e "Proxy"/"Iterator" (152-156, 234-237) |
| `.../dotnet-code-review/designpatterns-legacy/references/smells-legado.md` | "Acesso a dados" (97-109), "Entity Framework 6" (111-124) |

## Resumo executivo

Os três documentos estão, no geral, tecnicamente sólidos: as linhas de maior valor (`ToList()` antes de `Where()`, `SaveChanges` em loop, `DbContext` não thread safe, SQL concatenado, `DbContext` com vida de aplicação, lazy loading em `foreach` no EF6, `AsNoTracking` existe no EF6) estão corretas. Os problemas se concentram em **mecanismo mal descrito** (o sintoma certo pela razão errada, o que faz o revisor procurar a coisa errada no código) e em **recomendações sem ressalva** que, aplicadas literalmente, causam perda de dado.

Os cinco achados mais graves, em ordem:

1. **(b) B1** — `ExecuteUpdateAsync`/`ExecuteDeleteAsync` recomendados como 🟡 "round trip extra", sem uma palavra sobre bypass de interceptor, de token de concorrência e de cascade. Num projeto com soft delete por interceptor, seguir essa linha do documento apaga dado em definitivo.
2. **(c) C1/C2** — concorrência otimista e tracking de grafo desanexado não aparecem em nenhum dos três arquivos. São os dois defeitos de *dado* mais comuns em review real de EF Core (atualização perdida silenciosa e `Update(dtoMapeado)` zerando colunas).
3. **(a) A7 / (d) D5** — a parte legada mistura as duas versões: em EF6, `Skip` sem `OrderBy` **lança** `NotSupportedException` (não é "resultado imprevisível", isso é EF Core); e a linha de `DbEntityValidationException` não avisa que EF Core removeu a validação automática, que é o bug nº 1 de migração EF6→EF Core.
4. **(a) A1 / (d) D1** — "acesso a navegação dentro de `foreach` = N+1" descreve a mecânica do EF6. Em EF Core, sem proxies, a navegação não emite query: devolve `null`/vazio, ou vem preenchida pela metade por relationship fixup. O achado é 🔴 pelos dois lados, mas a evidência que o revisor precisa buscar é outra.
5. **(a) A2 / (b) B2** — explosão cartesiana é atribuída a `Include` "em cascata profunda" (que não explode nada) em vez de a `Include` de coleções irmãs; e `AsSplitQuery()` é oferecido como correção sem as ressalvas de consistência entre as queries e de ordenação determinística com `Skip/Take`.

---

## (a) Erros factuais

### A1. "Acesso a navegação dentro de `foreach`" descrito com a mecânica do EF6

**Arquivo:** `dotnet-moderno.md:96`

**Trecho:**
> `| Acesso a navegação dentro de foreach | 🔴 | N+1: uma query por item | Include() ou projeção com Select() |`

**O que está errado:** EF Core não tem lazy loading implícito. Sem `Microsoft.EntityFrameworkCore.Proxies` + `UseLazyLoadingProxies()` (ou `ILazyLoader` injetado), ler `pedido.Cliente` dentro do `foreach` **não emite query nenhuma**: devolve `null` numa referência e coleção vazia numa coleção. Existem então três cenários distintos, e o documento descreve só um:

- proxies ligados → N+1 de verdade (o caso descrito);
- proxies desligados → `NullReferenceException` ou, pior, dado silenciosamente errado (total zerado, lista vazia);
- proxies desligados mas as entidades relacionadas já carregadas por outra query no mesmo `DbContext` → o *relationship fixup* do change tracker preenche as navegações **parcialmente**, com apenas o subconjunto que já está rastreado. O resultado passa em teste (onde só há uma query) e falha em produção, e muda conforme a ordem das queries anteriores.

N+1 de verdade em EF Core sem proxies vem de outra forma: uma chamada `await db.X.Where(...)` **dentro** do loop, ou `Entry(e).Reference(...).LoadAsync()` no loop.

**Correção sugerida (substituir a linha por duas):**

```
| Query ao banco (`Where`, `Load`, `First`) dentro de `foreach` | 🔴 | N+1: uma ida ao banco por item | Uma query só, com `Include()` ou projeção; ou carregar as chaves e fazer um `Where(x => ids.Contains(x.Id))` |
| Navegação lida sem `Include` nem projeção | 🔴 | Com proxies: N+1. Sem proxies: `null`/coleção vazia, ou preenchimento parcial por relationship fixup — dado errado sem erro | `Include()` explícito, ou projetar o que precisa com `Select()` |
```

E acrescentar a instrução de review: **primeiro verifique se `UseLazyLoadingProxies()` está registrado**, porque isso decide qual dos dois defeitos você está olhando.

---

### A2. Explosão cartesiana atribuída a profundidade, não a coleções irmãs

**Arquivo:** `dotnet-moderno.md:103`

**Trecho:**
> `| Include em cascata profunda | 🟠 | Explosão cartesiana de linhas | AsSplitQuery() ou projeção |`

**O que está errado:** profundidade não causa explosão. `Include(o => o.Cliente).ThenInclude(c => c.Endereco)` é uma cadeia de JOINs para o lado "um": uma linha por pedido, zero duplicação. O que explode é **mais de um `Include` de coleção alcançável na mesma query**, seja como irmãos no mesmo nível, seja coleção dentro de coleção:

```csharp
db.Pedidos
  .Include(p => p.Itens)      // 10 itens
  .Include(p => p.Pagamentos) // 3 pagamentos
```

produz 10 × 3 = 30 linhas por pedido, e **cada** uma das 30 repete todas as colunas de `Pedidos` (e de qualquer referência incluída). Com um `nvarchar(max)` de observação no pedido, o tráfego multiplica por 30. Esse é o custo real, e ele é de *largura* (colunas repetidas), não só de contagem de linhas.

**Correção sugerida:**

```
| Duas ou mais coleções incluídas na mesma query (irmãs ou aninhadas) | 🟠 | Explosão cartesiana: linhas = produto das coleções, e cada linha repete todas as colunas do pai | Projeção com `Select()` (primeira opção), ou `AsSplitQuery()` com as ressalvas de consistência |
| `Include` de cadeia de referências (`ThenInclude` para lado "um") | 🟢 | Não duplica linha; é um JOIN por nível | Não é achado, salvo se traz colunas que não vão ser usadas |
```

Ver também **B2** (as ressalvas de `AsSplitQuery`).

---

### A3. `AsNoTracking()`: motivo impreciso, custo omitido, e recomendação redundante em projeção

**Arquivo:** `dotnet-moderno.md:98`

**Trecho:**
> `| Leitura sem AsNoTracking() | 🟠 | Custo de change tracking desnecessário, e risco de mutação acidental | AsNoTracking() em consultas de leitura |`

**Três imprecisões:**

1. **"Risco de mutação acidental"** — `AsNoTracking()` não impede mutação nenhuma; o objeto continua mutável. O que muda é que a mutação **não é persistida** por um `SaveChanges` posterior. Dito como está, sugere proteção que não existe.
2. **Redundante em projeção** — EF Core só rastreia instâncias de *tipos de entidade* presentes no resultado. `Select(x => new PedidoDto { ... })` já não rastreia nada, e `AsNoTracking()` ali é ruído. Como a linha 99 do mesmo documento recomenda projetar para DTO, as duas linhas juntas produzem uma recomendação vazia. (`AsNoTracking` só importa quando a projeção **contém entidades**, ex.: `Select(x => new { x, x.Total })`.)
3. **Custo omitido** — `AsNoTracking()` desliga a *identity resolution*: a mesma linha do banco vira N instâncias CLR distintas quando aparece por caminhos diferentes do grafo. Isso quebra `ReferenceEquals`, duplica memória em grafos com muitas referências ao mesmo pai, e produz resultados confusos em agregação em memória. Para isso existe `AsNoTrackingWithIdentityResolution()` (EF Core 5+).

**Correção sugerida:**

```
| Query que materializa entidades num caminho só de leitura, sem `AsNoTracking()` | 🟠 | Change tracking pago sem uso, e mutação acidental fica persistível pelo próximo `SaveChanges` | `AsNoTracking()`; `AsNoTrackingWithIdentityResolution()` se o grafo tem referências repetidas |
| `AsNoTracking()` em query que já projeta para DTO | 🟢 | Projeção para tipo não-entidade não é rastreada: a chamada não faz nada | Remover (ruído), não é defeito |
```

Ver **B3** para o perigo de aplicar isso em varredura.

---

### A4. `Skip/Take` sem `OrderBy`: mecanismo e correção incompletos

**Arquivo:** `dotnet-moderno.md:101`

**Trecho:**
> `| Paginação com Skip/Take sem OrderBy | 🟠 | Ordem não determinística, itens repetidos ou perdidos entre páginas | OrderBy estável antes |`

**O que falta / está impreciso:**

- **EF Core não exige `OrderBy`.** Ele registra o evento `CoreEventId.RowLimitingOperationWithoutOrderByWarning` e, no SQL Server (onde `OFFSET/FETCH` exige `ORDER BY`), **emite `ORDER BY (SELECT 1)`**. Ou seja: não falha, ordena arbitrariamente, e o log de warning é a única pista. Vale dizer isso, porque o revisor pode achar que "se compilou e rodou, está ordenado".
- **`OrderBy` sozinho não corrige.** Ordenar por coluna não única (`CreatedAt`, `Nome`, `Status`) continua instável entre páginas: o banco é livre para desempatar diferente em cada execução. É obrigatório um **desempate único**. "OrderBy estável" é ambíguo demais para virar regra de review.
- **Falta o custo de `OFFSET`.** `Skip(n)` é O(n) no servidor: a página 500 lê e descarta 10.000 linhas.

**Correção sugerida:**

```
| `Skip`/`Take` sem `OrderBy` | 🟠 | EF Core não falha: emite `ORDER BY (SELECT 1)` no SQL Server e só loga `RowLimitingOperationWithoutOrderByWarning`. Páginas embaralham, com item repetido e item perdido | `OrderBy` **com desempate único**: `.OrderByDescending(x => x.CreatedAt).ThenBy(x => x.Id)` |
| `Skip` com offset grande em lista infinita/exportação | 🟠 | `OFFSET n` lê e descarta n linhas: custo cresce com a página | Keyset pagination: `Where(x => x.CreatedAt < @c || (x.CreatedAt == @c && x.Id < @i))` |
```

---

### A5. Comentário de `SaveAsync()` no anti-padrão de Repository descreve o mecanismo errado

**Arquivo:** `catalogo-patterns.md:300`

**Trecho:**
> `Task SaveAsync();                    // commit por entidade, destrói a transação`

**O que está errado:** no arranjo normal (um `DbContext` scoped compartilhado por todos os repositórios), `repo.SaveAsync()` **não** faz commit "por entidade". Ele chama `SaveChangesAsync()` e descarrega **todo o change tracker**: alterações pendentes de outros repositórios, de outros agregados, de um caso de uso ainda pela metade. O defeito é mais grave e de natureza diferente do que o comentário diz — não é granularidade excessiva, é *efeito colateral não local*. Um `pedidoRepo.SaveAsync()` grava também o cliente que outro serviço tinha alterado e ainda não validado.

O cenário "commit por entidade / transações independentes" só ocorre no arranjo pior ainda, em que cada repositório tem o seu próprio `DbContext` — e aí nenhuma das gravações é atômica com as outras, e não há como fazer rollback conjunto.

**Correção sugerida do comentário:**

```csharp
Task SaveAsync();  // com DbContext compartilhado, descarrega TODO o change tracker,
                   // inclusive alterações pendentes de outros agregados.
                   // Com um DbContext por repositório, cada Save é uma transação
                   // separada e não existe rollback conjunto. Os dois arranjos são ruins.
```

---

### A6. Specification: "sem risco de divergirem" é falso

**Arquivo:** `catalogo-patterns.md:308`

**Trecho:**
> **Ganho real:** dar **nome de negócio** à regra e usá-la nos dois mundos, no banco via `Expression<Func<T,bool>>` e em memória via `IsSatisfiedBy`, sem risco de divergirem.

**Dois eixos de divergência, ambos reais:**

1. **Traduzibilidade.** Desde EF Core 3.0 não há fallback silencioso para avaliação no cliente em `Where`: uma expressão que roda perfeitamente em memória lança `InvalidOperationException: The LINQ expression ... could not be translated` quando usada na query. Casos típicos dentro de uma spec de negócio: `string.Equals(a, b, StringComparison.OrdinalIgnoreCase)`, chamada a método próprio (`x.Documento.EhValido()`), acesso a propriedade calculada não mapeada (ver **C-projeção**, item C9), aritmética de `TimeSpan`, e composição via `.Compile()` dentro de outra expressão.
2. **Semântica.** Mesmo quando traduz, o resultado pode diferir:
   - comparação de string: `==` no SQL Server segue a **collation** da coluna (por padrão case- e accent-insensitive em bancos brasileiros: `Latin1_General_CI_AI`), enquanto em memória `==` é ordinal e case-sensitive. `"José" == "JOSE"` é `true` no banco e `false` em C#;
   - lógica de três valores: `x.Cancelado != true` inclui as linhas com `NULL` em C# (após conversão de nullable) e **exclui** no SQL;
   - precisão: `decimal` e `datetime2` truncam conforme o tipo da coluna, então uma comparação de igualdade pode bater em memória e não bater no banco.

**Correção sugerida:** trocar "sem risco de divergirem" por:

> **Ganho real:** dar nome de negócio à regra e ter **uma única fonte de verdade** — `IsSatisfiedBy(e) => ToExpression().Compile()(e)`. Nunca reimplemente a regra em código imperativo ao lado da expressão, porque as duas divergem na primeira manutenção.
>
> **Armadilhas a verificar em review:**
> - a expressão precisa ser **traduzível**: método próprio, `StringComparison`, propriedade calculada não mapeada → `InvalidOperationException` em runtime (EF Core 3.0+ não avalia no cliente em `Where`);
> - a mesma spec pode dar resultado **diferente** no banco e em memória por collation (case/acento), por `NULL` de três valores, e por precisão de coluna. Toda spec usada em query precisa de teste de integração contra o banco real;
> - compor specs exige **rebind de parâmetro**: `Expression.AndAlso(a.Body, b.Body)` com parâmetros diferentes gera expressão inválida. Use um `ExpressionVisitor` para substituir o parâmetro, ou uma biblioteca que já faça isso.

---

### A7. EF6: `Skip` sem `OrderBy` não é "imprevisível", é exceção

**Arquivo:** `smells-legado.md:122`

**Trecho:**
> `| Skip/Take sem OrderBy | 🟠 | EF6 exige ordenação para paginar, e sem ela o resultado é imprevisível |`

**O que está errado:** a linha se contradiz e importa semântica do EF Core. Em LINQ to Entities (EF6), `Skip` sobre fonte não ordenada **lança em runtime**:

> `NotSupportedException: The method 'Skip' is only supported for sorted input in LINQ to Entities. The method 'OrderBy' must be called before the method 'Skip'.`

Portanto não existe, em EF6, um `Skip` sem `OrderBy` que rode e devolva página embaralhada. O que existe e é genuinamente não determinístico em EF6 é **`Take` sozinho, sem `Skip` e sem `OrderBy`** — permitido, e devolve N linhas arbitrárias. "Sem ela o resultado é imprevisível" descreve o EF Core, que aceita os dois operadores e apenas registra warning.

**Correção sugerida:**

```
| `Skip` sem `OrderBy` (EF6) | 🔴 | `NotSupportedException` em runtime: LINQ to Entities só aceita `Skip` sobre fonte ordenada. Costuma aparecer só na página 2 | `OrderBy` com desempate único antes do `Skip` |
| `Take` sem `OrderBy` (EF6) | 🟠 | Permitido, devolve N linhas arbitrárias | `OrderBy` com desempate único |
```

E, na comparação com o documento moderno, deixar explícito: **EF Core removeu essa restrição** (aceita `Skip`/`Take` sem ordenação, emite `ORDER BY (SELECT 1)` no SQL Server e loga warning). Ver **D-tabela**.

---

### A8. Legado: `dr["valor"].ToString()` não lança — o mecanismo e a severidade estão trocados

**Arquivo:** `smells-legado.md:107`

**Trecho:**
> `| dr["valor"].ToString() sem checar DBNull | 🔴 | Verificar IsDBNull |`

**Dois erros:**

1. **`DBNull.Value.ToString()` devolve `string.Empty`. Não lança nada.** Nessa forma exata o defeito é *silencioso*: `""` no lugar de "ausente", que depois vira `0` num parse, ou passa por uma checagem `!= null`, ou é gravado como string vazia. É um 🟠 de dado errado, não um 🔴 de exceção. Marcar como crash faz o revisor procurar o sintoma errado.
   As formas que **realmente lançam** são o cast e os getters tipados, e essas faltam na tabela:
   - `(int)dr["valor"]` / `(DateTime)dr["d"]` → `InvalidCastException`;
   - `dr.GetString(i)`, `GetInt32(i)`, `GetDateTime(i)` sobre `NULL` → `SqlNullValueException`;
   - `Convert.ToInt32(dr["v"])` e `Convert.ToDateTime(dr["v"])` → `InvalidCastException` (note a assimetria: `Convert.ToString(DBNull.Value)` devolve `""`).
2. **A correção, como escrita, não compila no caso mais provável.** `IDataRecord.IsDBNull` / `DbDataReader.IsDBNull` só têm sobrecarga **por ordinal**; não existe `IsDBNull("valor")`. Quem lê por nome precisa de `dr.IsDBNull(dr.GetOrdinal("valor"))`, `dr["valor"] == DBNull.Value`, `Convert.IsDBNull(dr["valor"])` ou `dr["valor"] as string`.

**Correção sugerida:**

```
| Cast direto ou getter tipado sobre coluna anulável (`(int)dr["v"]`, `dr.GetString(i)`, `Convert.ToInt32(...)`) | 🔴 | `InvalidCastException` / `SqlNullValueException` em produção quando a coluna vem `NULL` | `dr.IsDBNull(ordinal)` antes, ou `dr["v"] as string` / `dr["v"] == DBNull.Value ? null : ...`. Não existe sobrecarga de `IsDBNull` por nome de coluna |
| `dr["v"].ToString()` sobre coluna anulável | 🟠 | Não lança: `DBNull.Value.ToString()` é `""`. O bug é silencioso — "ausente" vira string vazia e se propaga | Distinguir ausente de vazio explicitamente |
```

---

### A9. "`DbContext` já é Repository e já é Unit of Work": correto, mas a conclusão precisa de precisão

**Arquivo:** `catalogo-patterns.md:286`

**Trecho:**
> **Ponto mais importante:** o `DbContext` do EF Core **já é** Repository (`DbSet<T>`) e **já é** Unit of Work (`SaveChangesAsync`).

**Veredito: a afirmação está certa** — é a formulação da própria documentação da Microsoft, e o `ChangeTracker` completa o trio implementando Identity Map. Não é um erro factual. Mas três precisões faltam, e são justamente as que decidem quando a conclusão ("envolver costuma ser trabalho sem retorno") não vale:

1. **`DbSet<T>` é repositório genérico por tabela, não repositório de agregado.** Ele não sabe carregar/salvar um agregado inteiro com seus filhos, não impõe invariante de fronteira, e expõe `IQueryable`, o que permite a qualquer camada compor qualquer query sobre qualquer tabela. Em DDD isso não substitui um repositório de agregado — o próprio documento reconhece na linha 288, mas a frase de abertura é forte demais e é a que o revisor vai citar.
2. **A UoW do `DbContext` tem fronteira estreita.** É atômica **por chamada** de `SaveChangesAsync` e **por instância** de contexto: duas chamadas não formam uma transação (precisa `BeginTransactionAsync` explícito), dois contextos nunca formam uma, e nada fora do banco entra nela (mensagem publicada, arquivo escrito, chamada HTTP) — daí Outbox, que o documento cita corretamente em outra seção (linha 193).
3. **Ele só é UoW se o escopo for curto.** Preso em singleton, ou vivo por um endpoint longo, o `DbContext` deixa de ser unidade de trabalho e passa a ser cache global com dado obsoleto (o documento marca isso em `dotnet-moderno.md:65`). Vale ligar as duas afirmações.

**Correção sugerida:** manter a frase e acrescentar, logo abaixo:

> Precisão que evita citação equivocada: `DbSet<T>` é repositório **genérico por tabela** (e vaza `IQueryable`), não repositório de agregado; e a UoW do `DbContext` é atômica **por chamada de `SaveChangesAsync` e por instância**, não cobre duas chamadas nem efeitos fora do banco.

---

### A10. "`await` dentro de `foreach` sobre `IEnumerable` de banco": subdiagnóstico, e a correção proposta troca um bug por outro

**Arquivo:** `dotnet-moderno.md:42`

**Trecho:**
> `| await dentro de foreach sobre IEnumerable de banco | 🟠 | Pode manter conexão aberta por muito tempo | Materializar antes, ou usar IAsyncEnumerable deliberadamente |`

**O que está errado:** com EF Core, se você awaita **outra operação do mesmo `DbContext`** enquanto enumera um `IQueryable`/`IAsyncEnumerable` ainda não materializado, o resultado normal não é "conexão aberta por muito tempo", é exceção:

> `InvalidOperationException: A second operation was started on this context instance before a previous operation completed.`

(No SQL Server soma-se a limitação de um único result set por conexão sem `MultipleActiveResultSets=True`.) É um 🔴 determinístico, não um 🟠 de risco. E a correção "materializar antes" resolve para conjunto pequeno, mas em tabela grande troca a exceção por consumo de memória e por uma transação/leitura longa.

**Correção sugerida:**

```
| Outra operação do mesmo `DbContext` awaitada dentro de `foreach`/`await foreach` sobre query não materializada | 🔴 | `InvalidOperationException: A second operation was started on this context instance...` | Materializar em página/lote de chaves e processar por lote; ou um segundo contexto via `IDbContextFactory<T>` para as operações internas; ou `AsAsyncEnumerable()` sem nenhuma outra operação no mesmo contexto durante a enumeração |
```

---

### Afirmações verificadas e **corretas** (não mexer)

Registro do que foi conferido e passou, para o documento não ser "corrigido" por engano depois:

| Afirmação | Onde | Nota |
|---|---|---|
| `ToList()` antes de `Where()` traz a tabela e filtra em memória | moderno:97, legado:117 | Correto nas duas versões |
| `SaveChanges` em loop: uma transação por item, sem atomicidade | moderno:100, legado:119 | Correto — mas ver **B4** e **D4** |
| `DbContext` não é thread safe; `Task.WhenAll` sobre contexto compartilhado é 🔴 | moderno:37, 106; legado:91 | Correto, e consistente entre os documentos |
| Interpolação em `FromSqlRaw`/`ExecuteSqlCommand` é SQL injection | moderno:102, legado:121 | Correto. Nota: o caso que engana é a interpolação atribuída a uma `string` antes — o compilador já concatenou, e `FromSql` não tem mais o que parametrizar |
| Scoped em Singleton prende `DbContext`, acumula tracking e vaza dado entre requisições | moderno:65, catalogo:267 | Correto |
| `IServiceScopeFactory` obrigatório em `BackgroundService` que usa `DbContext` | moderno:67, 218 | Correto (mas o exemplo tem defeito: ver **B5**) |
| Lazy loading dentro de `foreach` em EF6 é N+1 🔴 | legado:115 | Correto, e é o caso comum em EF6 (lazy é o padrão lá) |
| `AsNoTracking()` existe em EF6 | legado:118 | Correto (`System.Data.Entity`, desde EF 4.1) |
| `DbEntityValidationException` não diz qual propriedade falhou | legado:123 | Correto: a mensagem é genérica, o detalhe está em `EntityValidationErrors` |
| `static DbContext`/conexão compartilhada é 🔴 | legado:91 | Correto |
| ADO.NET sem `using` vaza conexão e esgota o pool | legado:102 | Correto |
| `IN (...)` concatenado em loop | legado:108 | Correto (acrescentar o limite de 2100 parâmetros do SQL Server) |
| Iterar `IQueryable` depois de descartar o contexto lança | catalogo:236 | Correto (`ObjectDisposedException` em EF Core; em EF6 a mensagem é `The ObjectContext instance has been disposed...`) |
| Lazy loading proxies são Proxy virtual, e em `foreach` dão N+1 | catalogo:154-155 | Correto |
| `ChangeTracker` guarda valores originais (Memento) | catalogo:249 | Correto — e é exatamente o que `ExecuteUpdate` não usa (**B1**) |
| Repository só vale com agregado, query de negócio nomeada ou troca real de fonte | catalogo:288-290 | Correto e bem calibrado |
| CQRS não é event sourcing e não exige bancos separados | catalogo:314 | Correto |

---

## (b) Conselho perigoso

### B1. 🔴 `ExecuteUpdateAsync` / `ExecuteDeleteAsync` recomendados como 🟡 sem nenhuma ressalva

**Arquivo:** `dotnet-moderno.md:104-105`

**Trecho:**
> `| Update lendo a entidade só para alterar um campo | 🟡 | Round trip extra | ExecuteUpdateAsync |`
> `| Delete carregando entidades | 🟡 | Round trip extra | ExecuteDeleteAsync |`

**Por que é perigoso:** esses dois métodos (EF Core 7+) **não passam pelo change tracker nem pelo `SaveChanges`**. Consequências, todas silenciosas:

| O que é ignorado | Consequência concreta |
|---|---|
| `ISaveChangesInterceptor` / override de `SaveChangesAsync` | Auditoria (`UpdatedAt`, `UpdatedBy`) não é preenchida. **Soft delete implementado por interceptor deixa de funcionar: `ExecuteDeleteAsync` emite `DELETE` de verdade** — perda de dado irrecuperável, no código que o documento recomenda escrever |
| Token de concorrência (`rowversion` / `IsConcurrencyToken`) | Não é verificado. Nunca lança `DbUpdateConcurrencyException`: sobrescreve a alteração de outro usuário sem avisar |
| Eventos de domínio despachados no `SaveChanges` | Não disparam. Integração, cache e projeções ficam dessincronizadas |
| Cascade delete **do EF Core** (`ClientCascade`, e o cascade que o EF faria carregando os filhos) | `ExecuteDelete` conta apenas com o `ON DELETE` do banco. Sem ele: `FOREIGN KEY constraint` violation, ou órfãos |
| Estado do change tracker | Entidades já rastreadas ficam **obsoletas**. Um `SaveChangesAsync()` depois no mesmo contexto pode reescrever o valor antigo por cima |
| Escopo transacional | Cada chamada é a sua própria transação, salvo se houver `BeginTransactionAsync` explícito. Misturado com `SaveChanges`, perde atomicidade |

Além disso: exige EF Core 7+, e não funciona em entidades mapeadas para mais de uma tabela (TPT, table splitting, parte dos owned types).

**Correção sugerida (substituir as duas linhas):**

```
| Ler a entidade só para mudar um campo, em atualização em massa (`WHERE` atinge muitas linhas) | 🟡 | Round trip e materialização desnecessários | `ExecuteUpdateAsync`, **se** as ressalvas abaixo não se aplicam |
| `ExecuteUpdateAsync`/`ExecuteDeleteAsync` num projeto que tem interceptor de auditoria, soft delete, token de concorrência ou evento de domínio | 🔴 | Passa por fora de tudo isso. Soft delete por interceptor vira DELETE físico | Voltar ao caminho `SaveChanges`, ou replicar explicitamente o efeito no `SetProperty` (e nunca para delete lógico) |
| `ExecuteUpdate/Delete` seguido de `SaveChanges` no mesmo contexto sem transação explícita | 🟠 | Duas transações, e o change tracker ficou obsoleto — risco de reescrever o valor antigo | `BeginTransactionAsync` envolvendo as duas, e `ChangeTracker.Clear()` ou recarga depois |
```

Pergunta de review a acrescentar: *"este projeto tem interceptor de `SaveChanges`, filtro global de soft delete ou `rowversion`? Se sim, `ExecuteUpdate/Delete` é proibido nesse caminho."*

---

### B2. 🟠 `AsSplitQuery()` como correção padrão, sem as ressalvas

**Arquivo:** `dotnet-moderno.md:103`

**Por que é perigoso:**

1. **Consistência.** Split query emite **N+1 queries independentes** (uma para o pai, uma por coleção). No isolamento padrão (`READ COMMITTED`), sem transação envolvendo o conjunto, um commit concorrente entre elas produz um grafo **inconsistente**: pai da versão antiga com filhos da nova, ou filho que já não pertence ao pai. Single query não tem esse problema. Quem precisa do grafo coerente tem de abrir transação (com o custo de lock que vem com ela).
2. **`Skip`/`Take` + split query exige ordenação determinística.** Sem desempate único, a query dos filhos pagina/ordena diferente da do pai e o resultado é **dado errado**, não só embaralhado. É a interação direta com **A4**.
3. **Custo de latência.** Mais round trips. Em grafo pequeno, ou em rede de latência alta, split query é **mais lenta** que a explosão que ela evita. É trade-off medido, não regra.
4. **Ordem de preferência invertida.** A correção de primeira linha é **projeção com `Select`**: ela não traz colunas repetidas, não precisa de split, não tem problema de consistência, e resolve o caso que dominava (devolver DTO). `AsSplitQuery` é para quando você realmente precisa do grafo de entidades rastreadas.

**Correção sugerida:** trocar "`AsSplitQuery()` ou projeção" por "**Projeção com `Select()`**; `AsSplitQuery()` só quando precisa do grafo rastreado — e aí verifique: ordenação com desempate único se houver `Skip`/`Take`, e transação se o grafo tiver de ser coerente; meça, porque em grafo pequeno split é mais lento".

---

### B3. 🟠 `AsNoTracking()` recomendado como varredura ("em consultas de leitura")

**Arquivo:** `dotnet-moderno.md:98`

**Por que é perigoso:** o pedido "adicione `AsNoTracking()` nas leituras" num PR gera, na prática:

1. **O bug mais comum de todos:** alguém acrescenta `AsNoTracking()` numa query cujo resultado é depois modificado e salvo. `SaveChangesAsync()` retorna `0` e **não grava nada**, sem erro, sem log. O comportamento passa em teste unitário com mock e falha em produção. Classificar como "consulta de leitura" depende de ler todo o fluxo, não a linha.
2. **Reanexar depois é pior:** a "correção" seguinte costuma ser `db.Update(entidadeNaoRastreada)`, que marca **todas** as colunas como modificadas (ver **C2**) — troca o no-op por sobrescrita de dado.
3. **Lazy loading para de funcionar** em entidade não rastreada: a navegação fica `null` silenciosamente.
4. **Perde identity resolution:** duplicação de instâncias e de memória em grafo com muitas referências ao mesmo pai.
5. **Ruído em projeção** (ver **A3**).

**Correção sugerida:** transformar em decisão de arquitetura em vez de achado linha a linha:

> `AsNoTracking` é decisão de **caminho**, não de linha. Duas formas defensáveis: (1) aplicar no lado de leitura (query handlers do CQRS), onde o contrato é "nada aqui é salvo"; (2) inverter o padrão do contexto com `UseQueryTrackingBehavior(QueryTrackingBehavior.NoTracking)` e marcar explicitamente `AsTracking()` nos caminhos de escrita. O que **não** funciona é espalhar `AsNoTracking()` por inspeção de linha: onde o resultado for modificado depois, `SaveChanges` grava zero linhas e não avisa.

---

### B4. 🟠 "Um `SaveChangesAsync` no fim" sem limite de volume

**Arquivo:** `dotnet-moderno.md:100`

**Por que é perigoso:** correto para dezenas de entidades, ruim para dezenas de milhares:

- **transação longa** → locks retidos, escalonamento de lock, bloqueio de outras requisições, `Timeout expired`;
- **change tracker gigante** → memória e `DetectChanges` custando cada vez mais;
- **limites do provider** → 2100 parâmetros por comando no SQL Server; EF Core quebra em lotes (`MaxBatchSize`, 42 por padrão no provider do SQL Server), mas tudo dentro da mesma transação;
- **semântica de falha muda** → antes, 500 de 1000 itens tinham sido gravados e o job podia retomar; agora falha tudo. Para importação, isso pode ser exatamente o que você **não** quer.

**Correção sugerida:**

```
| `SaveChangesAsync` dentro de loop | 🔴 | Uma transação por item; lento e sem atomicidade | Um `SaveChangesAsync` no fim **se o volume é pequeno** |
| Um único `SaveChangesAsync` para milhares de entidades | 🟠 | Transação longa, locks, memória de tracking, e falha no fim perde o lote inteiro | Lotes de 500-1000 com `ChangeTracker.Clear()` (ou contexto novo) entre lotes, checkpoint idempotente, e `AddRange` em vez de `Add` em loop. Acima disso, `SqlBulkCopy` ou biblioteca de bulk |
```

---

### B5. 🟠 O exemplo "correto" de `BackgroundService` com `DbContext` tem três defeitos, um deles contrariando o próprio documento

**Arquivo:** `dotnet-moderno.md:73-88`

**Trecho:**
```csharp
while (!stoppingToken.IsCancellationRequested)
{
    using var scope = scopeFactory.CreateScope();
    var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
    await db.SaveChangesAsync(stoppingToken);
    await Task.Delay(TimeSpan.FromMinutes(5), stoppingToken);
}
```

**Problemas:**

1. **`Task.Delay` está dentro do escopo.** `using var scope` só é descartado no fim da iteração, então o escopo — e o `AppDbContext`, e todos os serviços scoped — fica vivo **5 minutos por iteração sem fazer nada**. Com `AddDbContextPool` você prende uma instância do pool durante a espera; se algum serviço scoped abre `DbConnection` na construção, prende conexão do pool ADO.NET. É exatamente o oposto do "abrir o mais tarde e fechar o quanto antes" que o documento legado recomenda (`smells-legado.md:109`).
2. **Não tem `try/catch` no loop**, contrariando a linha 216 do próprio arquivo (`ExecuteAsync` sem `try/catch` no loop = 🔴). Um `DbUpdateException` transitório mata o serviço em silêncio.
3. **`SaveChangesAsync` sem nenhuma alteração pendente é no-op.** Como exemplo didático, sugere que "salvar" é o trabalho da iteração.

**Correção sugerida:**

```csharp
public sealed class Reconciler(IServiceScopeFactory scopeFactory, ILogger<Reconciler> log)
    : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMinutes(5));
        while (await timer.WaitForNextTickAsync(stoppingToken))
        {
            try
            {
                // escopo vive só o tempo do trabalho, nunca o tempo da espera
                await using var scope = scopeFactory.CreateAsyncScope();
                var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

                var pendentes = await db.Pedidos
                    .Where(p => p.Status == Status.Pendente)
                    .ToListAsync(stoppingToken);

                foreach (var p in pendentes) p.Reconciliar();
                await db.SaveChangesAsync(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;                       // shutdown: não é erro
            }
            catch (Exception ex)
            {
                log.LogError(ex, "Falha na reconciliação; tentando na próxima janela");
            }
        }
    }
}
```

---

### B6. 🟠 "Repository devolvendo `IReadOnlyList<T>` materializado" aplicado a tudo produz o 🔴 da linha de baixo

**Arquivo:** `catalogo-patterns.md:343` (versus `catalogo-patterns.md:303` e `355`)

**Trechos em conflito:**
> linha 343: `| Repository devolvendo IQueryable<T> (🟠) | ... | Métodos com intenção de negócio devolvendo IReadOnlyList<T> materializado |`
> linha 303: "Meio-termo que funciona: **Repository para escrita** e **query direta com projeção para leitura**."
> linha 355: `| Generic Repository com GetAll() alimentando filtro em memória (🔴) |`

**Por que é perigoso:** aplicada a **toda** leitura, a regra da linha 343 obriga o repositório a materializar entidades antes de qualquer filtro, ordenação, paginação ou projeção que o consumidor precise — que é literalmente o 🔴 da linha 355. E repositório que devolve entidades materializadas **não consegue projetar**, então volta a trazer todas as colunas (o 🟠 de `dotnet-moderno.md:99`). O revisor que ler só a tabela de "padrões mal implementados" vai aplicar a regra errada, porque a linha 303 está longe e não é referenciada.

**Correção sugerida:** tornar o escopo explícito na própria linha:

```
| Repository devolvendo `IQueryable<T>` (🟠) | Não abstrai nada, vaza EF para todas as camadas, e o consumidor compõe query que quebra em runtime | **No lado de escrita/agregado:** métodos com intenção de negócio devolvendo o agregado materializado. **No lado de leitura:** não use repositório — query com `Select()` para DTO, paginada, direto no `DbContext` (ver "Repository e Unit of Work"). Materializar entidade para depois filtrar em memória é o 🔴 da última linha desta tabela |
```

---

### B7. 🟠 Extrair `Where` de negócio para Specification sem exigir teste de integração

**Arquivo:** `catalogo-patterns.md:306-309`

**Por que é perigoso:** o refactor "mova esse `Where` para uma `Specification`" parece neutro, mas move a expressão para um ponto onde ela pode ser composta com outras e reutilizada em memória. A partir daí, um caminho que funcionava passa a poder lançar `InvalidOperationException` de tradução em runtime (ver **A6**), e a versão em memória pode discordar da versão no banco por collation e por `NULL`. É uma mudança que exige teste contra banco real, e o documento a apresenta como ganho puro.

**Correção sugerida:** acrescentar à seção Specification: *"Refactor que move um `Where` de negócio para spec só entra com teste de integração contra o banco real cobrindo a spec, porque muda o ponto de falha para runtime (tradução) e expõe diferença de semântica entre SQL e CLR."*

---

### B8. 🟠 "Transação sem `using` ou sem rollback no `catch`": rollback incondicional mascara a exceção original

**Arquivo:** `smells-legado.md:104`

**Trecho:**
> `| Transação sem using ou sem rollback no catch | 🔴 | using (var tx = conn.BeginTransaction()) com commit explícito |`

**Por que é perigoso:** `Rollback()` incondicional no `catch` lança quando o servidor **já** abortou a transação — deadlock (erro 1205), erro de severidade alta, timeout de comando:

> `InvalidOperationException: This SqlTransaction has completed; it is no longer usable.`

Essa exceção substitui a original dentro do `catch` e você perde a causa raiz do incidente. O `Dispose` do `using` já faz rollback do que não foi commitado, então rollback explícito é opcional; quando existir, precisa ser defensivo.

**Correção sugerida:**

```csharp
using var tx = conn.BeginTransaction();
try
{
    // ... comandos com tx atribuída
    tx.Commit();
}
catch
{
    try { tx.Rollback(); }
    catch (Exception rbEx) { log.Warn(rbEx, "Rollback falhou (transação já abortada pelo servidor)"); }
    throw;   // preserva a exceção original
}
```

E na tabela: *"o `using` já faz rollback; rollback explícito no `catch` precisa estar dentro do seu próprio `try`, senão um deadlock troca a exceção real por `This SqlTransaction has completed`"*.

---

### B9. 🟡 "`SqlCommand` sem `CommandTimeout`" sem avisar sobre `CommandTimeout = 0`

**Arquivo:** `smells-legado.md:103`

**Por que é perigoso:** a "correção" que aparece na prática é `CommandTimeout = 0`, que significa **espera infinita**: a query lenta deixa de dar erro e passa a pendurar a requisição, retendo a conexão do pool até o recycle do IIS. Um timeout finito e explícito é o objetivo; zero é pior que o default de 30s. Vale também dizer que `Connect Timeout` (connection string) e `CommandTimeout` são coisas diferentes e que só o segundo cobre query lenta, e onde configurar: EF6 `context.Database.CommandTimeout`, EF Core `UseSqlServer(o => o.CommandTimeout(n))`.

---

## (c) Lacunas críticas

Armadilhas que aparecem em code review real de EF Core e não estão em nenhum dos três arquivos.

### C1. 🔴 Concorrência otimista — ausente nos três documentos

A lacuna mais grave. Nenhuma menção a `rowversion`, `IsConcurrencyToken`, `DbUpdateConcurrencyException` ou 409.

Sem token configurado, EF Core gera `UPDATE ... SET ... WHERE Id = @id`. Dois usuários editando a mesma tela: o segundo `SaveChanges` sobrescreve o primeiro, **sem erro, sem log, sem rastro**. É o defeito de dado mais comum em CRUD com edição por humanos, e é invisível em teste.

**Linhas a acrescentar (documento moderno):**

```
| Entidade editável concorrentemente sem token de concorrência | 🔴 | Atualização perdida silenciosa: o último `SaveChanges` sobrescreve o anterior | `[Timestamp] public byte[] RowVersion` (ou `IsConcurrencyToken()` numa coluna de versão), e o token trafega no DTO de edição |
| `DbUpdateConcurrencyException` não tratada na borda | 🟠 | Conflito legítimo vira 500 | Traduzir para 409 + `ProblemDetails`; para resolver, reler com `entry.GetDatabaseValues()` e decidir (store wins / client wins / mesclar). Nunca reenviar o mesmo payload em retry cego |
| `ExecuteUpdateAsync` em entidade com token de concorrência | 🔴 | O token não é verificado: sobrescreve sem conflito (ver B1) | Caminho `SaveChanges` |
```

**Linha a acrescentar (documento legado):** em EF6 é a mesma coisa, com `[Timestamp]`, `DbUpdateConcurrencyException`, e resolução via `((IObjectContextAdapter)ctx).ObjectContext.Refresh(RefreshMode.StoreWins, entidade)`.

### C2. 🔴 Tracking de grafo desanexado (`Update`, `Attach`, `Entry(x).State = Modified`) — ausente

A segunda lacuna mais grave, e a que mais destrói dado em API REST.

- **`db.Update(entidade)` num grafo desanexado marca TODAS as propriedades como `Modified`.** O `UPDATE` inclui todas as colunas. Se o DTO recebido no `PUT` não trouxe um campo (porque a tela não o edita), ele vai para `null`/default e **apaga o dado existente**. Padrão `_mapper.Map<Pedido>(dto)` seguido de `db.Update(...)` é achado 🔴 quase automático.
- **`Update`/`Attach` percorrem o grafo** (`TrackGraph`): filho com chave gerada em valor default é marcado `Added` → **INSERT duplicado**; filho que a UI removeu simplesmente não é apagado → órfão ou violação de FK.
- **`InvalidOperationException: The instance of entity type 'X' cannot be tracked because another instance with the same key value ... is already being tracked`** — mesma entidade vinda de duas queries, ou `AsNoTracking()` seguido de `Attach` (ligação direta com **B3**).
- Forma correta: **carregar o agregado rastreado por id, aplicar as mudanças e deixar o EF calcular o delta** (`entry.CurrentValues.SetValues(dto)` para os campos escalares que a tela edita; coleções reconciliadas por chave com `Remove` explícito).

```
| `db.Update(entidadeMapeadaDeDto)` / `Entry(x).State = Modified` em grafo desanexado | 🔴 | Marca todas as colunas como modificadas: campo ausente no DTO vira `null` no banco. Filhos sem chave viram INSERT duplicado, filhos removidos ficam órfãos | Carregar o agregado rastreado por id e aplicar as mudanças (`CurrentValues.SetValues`), reconciliando coleção por chave |
| Mesma entidade rastreada duas vezes (duas queries, ou `AsNoTracking` + `Attach`) | 🟠 | `The instance of entity type ... cannot be tracked because another instance with the same key value is already being tracked` | Uma query por unidade de trabalho, ou `ChangeTracker.Clear()` entre etapas |
```

O mesmo defeito existe em EF6 (`db.Entry(model).State = EntityState.Modified` na action `Edit` clássica do MVC, com o model vindo do form) e falta no documento legado — ver **D-tabela**.

### C3. 🟠 Migrations: o documento pára em "gerar migration"

`dotnet-moderno.md:107` cobre só a ausência de migration. Faltam os itens que realmente causam incidente:

- **Revisar o C# gerado antes de commitar.** Rename de propriedade é detectado como `DropColumn` + `AddColumn` → **perda silenciosa de dado**. Mudança de tipo ou de nulidade pode falhar contra dado existente. `DropColumn` com índice/constraint dependente.
- **Deploy compatível (expand/contract).** Durante o rollout, a versão anterior do código convive com o schema novo. Coluna nova tem de nascer nullable, com backfill, e só virar obrigatória num deploy seguinte. Migration que renomeia ou remove coluna em uso derruba as instâncias antigas.
- **`Database.Migrate()` na subida com N instâncias** → corrida. Preferir uma etapa única no pipeline com `dotnet ef migrations script --idempotent`.
- **Misturar `EnsureCreated()` com migrations** → banco sem `__EFMigrationsHistory`, e nenhuma migration aplica depois.
- **EF Core 9:** `Migrate()` passa a **falhar** quando o modelo divergiu da última migration (`PendingModelChangesWarning`). Vale exigir `dotnet ef migrations has-pending-model-changes` no CI — é o detector automático do achado da linha 107.
- **Migration com dado** (`MigrationBuilder.Sql`) versus seed idempotente, e migration de dado que não é reversível no `Down`.

### C4. 🔴 Transações e execution strategy (retry) — ausentes

- **`EnableRetryOnFailure()` + `BeginTransactionAsync()` lança:**
  > `InvalidOperationException: The configured execution strategy 'SqlServerRetryingExecutionStrategy' does not support user-initiated transactions. Use the execution strategy returned by 'DbContext.Database.CreateExecutionStrategy()'...`

  Achado frequentíssimo em código Azure SQL, e não está em nenhum lugar. Forma correta:

  ```csharp
  var strategy = db.Database.CreateExecutionStrategy();
  await strategy.ExecuteAsync(async () =>
  {
      await using var tx = await db.Database.BeginTransactionAsync(ct);
      // ...
      await db.SaveChangesAsync(ct);
      await tx.CommitAsync(ct);
  });
  ```
- **Retry reexecuta o bloco inteiro:** tudo dentro do `ExecuteAsync` precisa ser idempotente e reentrante. Publicar mensagem, incrementar contador em memória ou escrever arquivo lá dentro pode acontecer duas vezes.
- **Duas chamadas de `SaveChanges` sem transação explícita são duas transações.** Se a segunda falha, a primeira ficou gravada. É o caso comum de "salva o pedido, depois salva o log de auditoria".
- **`SaveChanges` + efeito externo** (publicar em fila, chamar API) não é atômico → Outbox. O `catalogo-patterns.md:193` cita Outbox no contexto de Observer, mas a tabela de EF Core nunca liga as duas coisas.
- **`TransactionScope`** funciona com EF Core, mas sem `TransactionScopeAsyncFlowOption.Enabled` não flui pelo `await`.

### C5. 🟠 Pooling: `AddDbContextPool` e o pool de conexões ADO.NET — ausentes

- **`AddDbContextPool<T>` reaproveita instâncias do `DbContext` entre requisições.** Estado guardado em campo do contexto (`_tenantId`, usuário atual injetado no construtor, lista de eventos de domínio acumulados) **não é resetado**, e serviço scoped injetado no construtor do contexto fica preso ao escopo da **primeira** requisição. Resultado: vazamento de dado entre requisições e, em multi-tenant, entre tenants — 🔴. Só use pooling com contexto sem estado, ou implemente o reset (`IResettableService`).
- **Pool de conexões ADO.NET:** `Max Pool Size` 100 por connection string + credencial. O sintoma `Timeout expired. The timeout period elapsed prior to obtaining a connection from the pool` é quase sempre escopo/contexto vivo demais, `await` esquecido, streaming longo, ou escopo não descartado — ligação direta com **B5**. Nunca "resolver" com `Pooling=false` nem aumentando o pool sem achar o vazamento.
- **Um `DbContext` usa uma conexão por vez.** Paralelizar exige `AddDbContextFactory` + `CreateDbContext()` por ramo — que é o *mecanismo* que falta na correção de `dotnet-moderno.md:106` ("um contexto por unidade de trabalho" não diz como).

### C6. 🟠 Interceptors, filtros globais e soft delete — ausentes

- **Auditoria** (`CreatedAt/By`, `UpdatedAt/By`) escrita à mão em cada handler é esquecida em algum caminho; o lugar é `ISaveChangesInterceptor` ou override de `SaveChangesAsync`.
- **Soft delete:** `HasQueryFilter(e => !e.IsDeleted)` + interceptor convertendo `Deleted` em `Modified`. Armadilhas para o review:
  - o filtro **não** se aplica a `FromSql` puro nem a `ExecuteDelete` (→ **B1**);
  - filtro numa entidade **referenciada** por navegação obrigatória faz o `Include` devolver `null` numa propriedade não anulável;
  - **índice único + soft delete** impede reinserção do mesmo valor lógico → índice filtrado (`WHERE IsDeleted = 0`);
  - `IgnoreQueryFilters()` esquecido em tela de administração e relatório → números que não fecham.
- **Multi-tenant por filtro global:** o filtro captura o `tenantId` do escopo **no momento em que o modelo é construído/o contexto é criado**. Com `AddDbContextPool` ou contexto de vida longa, ele congela no valor da primeira requisição → **vazamento entre tenants**, 🔴, e é um dos incidentes de segurança mais caros dessa lista.

### C7. 🟠 Propriedade calculada em projeção e tradução de expressão — ausente

O documento recomenda projetar com `Select()` (linha 99) sem dizer o que acontece quando a projeção toca uma propriedade calculada não mapeada. A regra real, que vale escrever:

| Onde a propriedade calculada aparece | O que acontece |
|---|---|
| `Where`, `OrderBy`, `GroupBy`, `Sum`, `Any` | `InvalidOperationException: The LINQ expression ... could not be translated`. EF Core 3.0+ não avalia no cliente fora da projeção final |
| Projeção final (`Select(x => new Dto { N = x.NomeCompleto })`) | **Funciona, e é uma armadilha:** EF Core não consegue olhar dentro do getter, então materializa a **entidade inteira** (todas as colunas mapeadas, e rastreada) para executar o getter no cliente. A projeção que existia para não trazer tudo passa a trazer tudo |
| Getter que usa navegação (`Itens.Sum(...)`) | Sem `Include`, a coleção está vazia → total zerado sem erro (mesma raiz de **A1**) |

Correções: inlinear a expressão na projeção; ou expor `public static Expression<Func<Cliente, string>> NomeCompletoExpr` e reutilizá-la; ou mapear como coluna computada persistida (`HasComputedColumnSql(..., stored: true)`), que ainda ganha índice.

Complemento na mesma linha: **`Include` é descartado quando a projeção final não devolve a entidade.** `.Include(x => x.Itens).Select(x => new Dto { ... })` — o `Include` não faz nada (evento `IncludeIgnoredWarning` nas versões que apenas avisam). Combinar os dois é sinal de que o autor não sabe qual dos dois está valendo.

### C8. 🟠 Modelagem e schema — completamente ausentes nos três arquivos

Nenhuma menção a precisão, tamanho, índice ou value converter. São achados objetivos, fáceis de verificar em review, e alguns corrompem dado:

```
| `decimal` sem `HasPrecision`/`HasColumnType` | 🔴 | Cai no default do provider (`decimal(18,2)` no SQL Server) e **trunca silenciosamente** valor monetário/percentual. EF Core loga `DecimalTypeDefaultWarning` | `HasPrecision(18, 2)` explícito, conforme o domínio |
| `string` sem `HasMaxLength` | 🟠 | `nvarchar(max)`: não indexável, não entra em chave, armazenamento off-row | `HasMaxLength(n)`, e `IsUnicode(false)` quando o domínio é ASCII |
| Value converter em tipo mutável (lista/objeto em JSON) sem `ValueComparer` | 🔴 | O change tracker compara por referência: alteração **nunca** é detectada e `SaveChanges` não grava nada. Perda de dado silenciosa | `HasConversion<...>(comparer)` com `ValueComparer` que compare estrutura |
| Coluna de filtro/ordenação/FK sem índice | 🟠 | Scan. SQL Server **não** cria índice de FK automaticamente | `HasIndex(...)`, e índice composto na ordem do predicado |
| Unicidade verificada com "existe?" na aplicação | 🟠 | Corrida entre duas requisições | Índice único no banco, e tratar `DbUpdateException` de violação de unique traduzindo para 409 |
| `DeleteBehavior` default aceito sem análise | 🟠 | Cascade apagando mais do que se espera, ou `ClientCascade` exigindo carregar os filhos | Decidir por relação: `Cascade` dentro do agregado, `Restrict` entre agregados |
| Enum persistido como `int` e depois reordenado | 🔴 | Reordenar o enum reescreve o significado dos dados já gravados | Valores explícitos no enum, ou converter para string |
| `DateTime` sem `Kind`/UTC atravessando o mapeamento | 🟠 | Volta do banco como `Unspecified` e a conversão de fuso erra | `DateTimeOffset`, ou converter global para UTC |
```

### C9. 🟠 Queries que impedem uso de índice — ausentes no documento moderno

O legado tem `ToUpper()` para comparar (linha 169) e o moderno não tem equivalente:

```
| `Where(x => x.Nome.ToLower().Contains(termo.ToLower()))` | 🟠 | Função na coluna + `LIKE '%...%'`: scan garantido | Collation case-insensitive na coluna + `EF.Functions.Like(x.Nome, termo + "%")`; para busca no meio da string, coluna computada indexada ou full-text |
| `Where(x => x.Data.Year == 2025)` | 🟠 | Função na coluna: não sargable | Faixa: `x.Data >= inicio && x.Data < fim` |
| `Count() > 0` / `Count()` para saber se existe | 🟠 | Conta tudo | `AnyAsync()` |
| Filtro por coluna convertida com `HasConversion` para JSON/string | 🟠 | Comparação pode virar não sargable, ou não traduzir | Verificar o SQL gerado antes de assumir |
```

### C10. 🟡 Compiled queries, cache de plano e diagnóstico — ausentes

- `EF.CompileAsyncQuery` só compensa quando o overhead de compilação de query domina o tempo — caminho quente **medido**. Não compõe, não aceita mudança de forma.
- **`EnableSensitiveDataLogging()` / `EnableDetailedErrors()` ligados em produção**: os parâmetros (CPF, e-mail, token) vão para o log. É 🔴 de segurança e deveria estar também na tabela de segurança do documento moderno.
- Query construída dinamicamente com constante embutida na árvore de expressão gera uma entrada de cache por variação → *plan cache bloat* e recompilação. (EF Core 8+ mudou a tradução de `Contains` sobre coleção parametrizada — verificar o SQL antes de assumir o comportamento antigo.)
- **Ferramentas de diagnóstico que os documentos nunca citam**, e que são o jeito mais barato de sustentar um achado num review: `query.ToQueryString()` para ver o SQL sem rodar, `LogTo(Console.WriteLine, LogLevel.Information)` em dev, `TagWith("nome")` para localizar a query nas DMVs, e os EventCounters de `Microsoft.EntityFrameworkCore`. Como o padrão de resposta da skill promete "explicar o SQL gerado", vale dar a ferramenta.

### C11. 🟠 Faltas específicas do documento legado (`Acesso a dados`)

- **`TransactionScope`** não aparece, e é a maior armadilha transacional do net4x: sem `TransactionScopeAsyncFlowOption.Enabled` o escopo **não flui pelo `await`** (o `Complete()` roda fora do escopo → `TransactionAbortedException`, ou commit onde não devia); e abrir duas conexões dentro do mesmo escopo promove para **MSDTC** (falha se o coordenador não está configurado). 🔴 nos dois casos.
- **`MultipleActiveResultSets`**: executar comando na mesma conexão enquanto um `SqlDataReader` está aberto lança `There is already an open DataReader associated with this Command`. É o equivalente legado do "second operation" de **A10**.
- **`ExecuteScalar` devolvendo `null` versus `DBNull.Value`** — dois casos diferentes (nenhuma linha vs. valor nulo) e o código costuma tratar um só.
- **Limite de 2100 parâmetros** do SQL Server, que é o teto da correção "parâmetros gerados" da linha 108.

---

## (d) EF6 versus EF Core: onde os documentos confundem as versões

### D1. Lazy loading tem default **oposto** nas duas versões, e isso não está dito em lugar nenhum

| | EF6 | EF Core |
|---|---|---|
| Lazy loading | **Ligado por padrão** (`Configuration.LazyLoadingEnabled = true`), basta a navegação ser `virtual` e `ProxyCreationEnabled` estar ligado | **Desligado.** Só existe com `Microsoft.EntityFrameworkCore.Proxies` + `UseLazyLoadingProxies()`, ou `ILazyLoader` injetado |

Consequências para os documentos:

- `smells-legado.md:115` ("lazy loading dentro de `foreach` = 🔴 N+1") está **certo e é o caso comum** em EF6, porque ninguém precisou ligar nada.
- `dotnet-moderno.md:108` ("Lazy loading habilitado 🟠 → desabilitar") descreve algo que **alguém ligou de propósito**, e a severidade é branda: num serviço que serializa entidades, lazy loading dispara carga em cascata durante a serialização e é 🔴. Falta também dizer que **lazy loading é sincrônico**: dentro de código async ele bloqueia thread do pool, e lança se o contexto já foi descartado.
- `dotnet-moderno.md:96` (N+1 em `foreach`) só se sustenta com proxies ligados — ver **A1**.

**Sugestão:** uma nota de uma linha em cada documento: *"Lazy loading é padrão em EF6 e opt-in em EF Core. Antes de classificar um N+1, verifique qual das duas situações você tem."*

### D2. `Include`: a API é diferente, e `ThenInclude` não existe em EF6

`smells-legado.md:116` está correto (`Include("Cliente.Endereco")` → `Include(x => x.Cliente.Endereco)`), mas incompleto de um jeito que gera código que não compila:

- em EF6 a sobrecarga com lambda aceita **cadeia de referências** (`x => x.Cliente.Endereco`) e exige `using System.Data.Entity;` (é extension method);
- para atravessar **coleção**, EF6 usa `Select`: `Include(x => x.Itens.Select(i => i.Produto))`;
- **`ThenInclude` é exclusivo do EF Core.** Um revisor que pedir `ThenInclude` num projeto net4x está pedindo código que não compila;
- **`AsSplitQuery()` não existe em EF6.** A explosão cartesiana em EF6 se resolve com projeção, ou com queries separadas no mesmo contexto + `Load()`, deixando o relationship fixup montar o grafo.

### D3. SQL bruto: nomes de API distintos, e a correção do documento moderno não pode ser transportada

| Operação | EF6 | EF Core |
|---|---|---|
| Query tipada | `Database.SqlQuery<T>(sql, params)`, `DbSet<T>.SqlQuery(sql, params)` | `FromSql`/`FromSqlRaw`/`FromSqlInterpolated`, `Database.SqlQuery<T>` (EF Core 7+) |
| Comando | `Database.ExecuteSqlCommand(sql, params)` | `Database.ExecuteSql`/`ExecuteSqlRaw`/`ExecuteSqlInterpolated` |
| Parametrização segura | `@p0` posicional, ou `new SqlParameter("@x", v)`. **Não existe sobrecarga que parametrize interpolação** | `FromSql($"... {valor}")` parametriza a interpolação |

`smells-legado.md:121` está certo em exigir parâmetros, mas deve dizer **qual API**, porque a correção do documento moderno (`dotnet-moderno.md:102`: "`FromSql` com interpolação parametrizada") **não existe em EF6** — e em EF6 uma interpolação passada a `ExecuteSqlCommand` é concatenação pura, sem nenhuma rede de proteção.

### D4. `SaveChanges`: EF Core faz batching, EF6 não

`smells-legado.md:119` ("um commit no fim") corrige a atomicidade e o custo de transação, mas subestima o que sobra:

- **EF Core** agrupa vários INSERT/UPDATE/DELETE por round trip (`MaxBatchSize`, 42 por padrão no provider do SQL Server).
- **EF6 não tem batching**: um round trip por statement. "Um `SaveChanges` no fim" com 5.000 linhas continua sendo 5.000 idas ao banco, agora dentro de uma transação longa.
- Além disso, o `DetectChanges` do EF6 é chamado a cada `Add` e custa proporcional ao número de entidades rastreadas (comportamento quadrático em loop). As correções específicas de EF6 são `Configuration.AutoDetectChangesEnabled = false` (restaurando depois) e `AddRange` (que já suspende o `DetectChanges` internamente); acima de alguns milhares de linhas, `SqlBulkCopy`.

### D5. Validação automática: existe em EF6, foi **removida** no EF Core

`smells-legado.md:123` está correto sobre `DbEntityValidationException`, mas falta a metade que evita bug de migração:

- **EF6** valida DataAnnotations em `SaveChanges` (`ValidateOnSaveEnabled = true` por padrão) e lança `DbEntityValidationException`.
- **EF Core não valida nada ao salvar.** `DbEntityValidationException` não existe, e DataAnnotations em EF Core afetam **apenas o modelo/schema** (`[MaxLength]` vira tamanho de coluna), nunca são verificadas no `SaveChanges`.

É a fonte nº 1 de bug numa migração EF6→EF Core: a validação desaparece sem erro de compilação, e o dado inválido passa a chegar ao banco (ou estoura numa constraint com mensagem incompreensível). Em EF Core, validação é na borda (FluentValidation/DataAnnotations no request) **mais** constraint no banco.

### D6. `AsNoTracking` existe nos dois, mas os outros levers de leitura do EF6 faltam

`smells-legado.md:118` está correto. Falta o resto do arsenal EF6, que não tem equivalente de nome igual em EF Core: `Configuration.ProxyCreationEnabled = false`, `Configuration.AutoDetectChangesEnabled = false`, `Configuration.ValidateOnSaveEnabled = false`. E não existem em EF6: `AsNoTrackingWithIdentityResolution()` (EF Core 5+) nem `ChangeTracker.Clear()` (EF Core 5+ — em EF6 o equivalente é `ObjectContext.Detach`).

### D7. Migrations: ferramentas, tabela de histórico e baseline são diferentes

| | EF6 | EF Core |
|---|---|---|
| Tabela de histórico | `__MigrationHistory` (com hash do modelo) | `__EFMigrationsHistory` |
| Comandos | `Add-Migration` / `Update-Database` no Package Manager Console; `Migrations/Configuration.cs` | `dotnet ef migrations add` / `dotnet ef database update` |
| Aplicar em runtime | Initializer `MigrateDatabaseToLatestVersion` (roda no **primeiro acesso** — perigoso em produção e com múltiplas instâncias) | `Database.Migrate()` (mesmo risco de corrida) |
| Script para DBA | `Update-Database -Script` | `dotnet ef migrations script --idempotent` |
| Baseline de banco existente | `Add-Migration Inicial -IgnoreChanges` | Gerar a migration e esvaziar o `Up()` |
| Automatic migrations | `AutomaticMigrationsEnabled` (+ `AutomaticMigrationDataLossAllowed`) | Não existe |

`smells-legado.md:124` ("migrations desabilitadas com banco alterado à mão → considerar baseline") ganha muito citando o comando concreto de baseline do EF6 e avisando que o hash do modelo em `__MigrationHistory` faz o EF6 reclamar mesmo quando o schema está compatível.

### D8. Tabela de existência: o que **não** existe em EF6

Útil para o revisor não recomendar EF Core num projeto net4x. Nada disto existe em EF6:

`ExecuteUpdateAsync` / `ExecuteDeleteAsync` · `AsSplitQuery()` · `ThenInclude` · `AsNoTrackingWithIdentityResolution` · `ChangeTracker.Clear()` · filtros globais (`HasQueryFilter`) · owned types · value converters (`HasConversion`) · `FromSql`/`FromSqlRaw`/`FromSqlInterpolated` · `IDbContextFactory<T>` · `AddDbContextPool` · `EF.Functions` (em EF6: `DbFunctions`/`SqlFunctions`) · `ToQueryString()` · batching de `SaveChanges` · `EF.CompileQuery` (em EF6: `CompiledQuery.Compile`, e só sobre `ObjectContext`; EF5+ já faz auto-compile de LINQ to Entities).

**Existe em EF6 e o documento legado não menciona** — é a lacuna de pontos de extensão do legado:

- **Interception de comando:** `IDbCommandInterceptor` / `IDbConnectionInterceptor` via `DbInterception.Add(...)` (EF6+). É o caminho para log de SQL, medição de query lenta e auditoria de comando em legado.
- **`Database.Log = s => ...`** para ver o SQL gerado (equivalente prático do `ToQueryString`/`LogTo`).
- **Auditoria de entidade:** override de `SaveChanges` (lendo `ChangeTracker.Entries()`) ou o evento `ObjectContext.SavingChanges`.
- **Resiliência de conexão:** `SetExecutionStrategy`/`SqlAzureExecutionStrategy` — e ela tem **a mesma incompatibilidade com transações iniciadas pelo usuário** descrita em **C4**.
- **Concorrência otimista:** `[Timestamp]`, `DbUpdateConcurrencyException`, `Refresh(RefreshMode.StoreWins)` (ver **C1**).
- **Grafo desanexado:** `Entry(model).State = EntityState.Modified` na action `Edit` do MVC marca **todas** as colunas — o mesmo 🔴 de **C2**, e em legado é ainda mais comum porque o model vem direto do form.
- **`ObjectDisposedException` equivalente:** iterar um `IQueryable` depois do `using` do contexto dá `The ObjectContext instance has been disposed and can no longer be used for operations that require a connection.`

### D9. Onde os dois documentos estão corretamente alinhados

`DbContext` não é thread safe (`smells-legado.md:91` e `dotnet-moderno.md:106`), `DbContext` com vida de aplicação é 🔴 (`legado:120`), SQL concatenado é 🔴 nos dois, `ToList()` antes de `Where()` é 🔴 nos dois, `SaveChanges` em loop é 🔴 nos dois. Nada a corrigir aqui — só vale acrescentar, no legado, que a correção "um contexto por requisição" em net4x é o container (Unity/Ninject/Windsor) com lifetime por requisição, ou `HttpContext.Items`, e **nunca** `static`.

---

## Ordem sugerida de aplicação

1. **B1** (`ExecuteUpdate/Delete`) e **C1**/**C2** (concorrência e grafo desanexado) — são os três que evitam perda de dado.
2. **A7**, **D5**, **D1** — as confusões EF6/EF Core, que fazem o revisor pedir a coisa errada num net4x.
3. **A1**, **A2**, **B2**, **A4** — mecanismos mal descritos nas linhas mais citadas da tabela de EF Core.
4. **B5** (exemplo do `BackgroundService`) e **B6** (conflito entre as linhas 303 e 343 do catálogo) — contradições internas, que custam credibilidade.
5. **C3** a **C10** — as lacunas, por ordem de frequência no seu contexto.
6. **A3**, **A5**, **A8**, **A10**, **B3**, **B4**, **B7**, **B8**, **B9**, **A9** — precisão de texto.
